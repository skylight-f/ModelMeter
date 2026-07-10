import Cocoa
import SQLite3
import SwiftUI

private func agentDeskSupportDirectoryURL() -> URL {
    let fileManager = FileManager.default
    let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    return baseURL.appendingPathComponent("AgentDesk", isDirectory: true)
}

final class AgentDeskStorage {
    static let shared = AgentDeskStorage()

    private let fileManager = FileManager.default
    private let storageURL: URL
    private let legacyStorageURL: URL
    private var values: [String: Any]

    private init() {
        let baseURL = agentDeskSupportDirectoryURL().deletingLastPathComponent()
        storageURL = baseURL
            .appendingPathComponent("AgentDesk", isDirectory: true)
            .appendingPathComponent("preferences.plist", isDirectory: false)
        legacyStorageURL = baseURL
            .appendingPathComponent("ModelMeter", isDirectory: true)
            .appendingPathComponent("preferences.plist", isDirectory: false)

        if let existing = NSDictionary(contentsOf: storageURL) as? [String: Any] {
            values = existing
        } else {
            values = [:]
        }

        loadLegacyValues()
    }

    var preferencesPath: String {
        storageURL.path
    }

    var supportDirectoryURL: URL {
        storageURL.deletingLastPathComponent()
    }

    func string(forKey key: String) -> String? {
        values[key] as? String
    }

    func double(forKey key: String) -> Double {
        if let value = values[key] as? Double { return value }
        if let value = values[key] as? NSNumber { return value.doubleValue }
        return 0
    }

    func bool(forKey key: String) -> Bool {
        if let value = values[key] as? Bool { return value }
        if let value = values[key] as? NSNumber { return value.boolValue }
        return false
    }

    func data(forKey key: String) -> Data? {
        values[key] as? Data
    }

    func array(forKey key: String) -> [Any]? {
        values[key] as? [Any]
    }

    func dictionary(forKey key: String) -> [String: Any]? {
        values[key] as? [String: Any]
    }

    private func loadLegacyValues() {
        let defaults = UserDefaults.standard
        let keyMappings: [(new: String, legacy: String)] = [
            ("AgentDesk.interfaceLanguage", "ModelMeter.interfaceLanguage"),
            ("AgentDesk.interfaceThemeMode", "ModelMeter.interfaceThemeMode"),
            ("AgentDesk.refreshInterval", "ModelMeter.refreshInterval"),
            ("AgentDesk.displayCurrency", "ModelMeter.displayCurrency"),
            ("AgentDesk.exchangeRate", "ModelMeter.exchangeRate"),
            ("AgentDesk.customModelPrices", "ModelMeter.customModelPrices"),
            ("AgentDesk.selectedProviderId", "ModelMeter.selectedProviderId"),
            ("AgentDesk.usageProvider", "ModelMeter.usageProvider"),
            ("AgentDesk.windowFrame.settings", "ModelMeter.windowFrame.settings")
        ]

        let legacyValues = NSDictionary(contentsOf: legacyStorageURL) as? [String: Any] ?? [:]

        for mapping in keyMappings {
            if values[mapping.new] != nil {
                continue
            }
            if let value = defaults.object(forKey: mapping.new) {
                values[mapping.new] = value
                continue
            }
            if let value = legacyValues[mapping.legacy] {
                values[mapping.new] = value
                continue
            }
            if let value = defaults.object(forKey: mapping.legacy) {
                values[mapping.new] = value
            }
        }
    }
}

private let customPricesKey = "AgentDesk.customModelPrices"
private let exchangeRateKey = "AgentDesk.exchangeRate"
private let displayCurrencyKey = "AgentDesk.displayCurrency"

final class AgentDeskDatabase {
    static let shared = AgentDeskDatabase()

    private static let migratedAppSettingsFlagKey = "AgentDesk.sqliteMigrated.appSettings"
    private let fileManager = FileManager.default
    private let databaseURL: URL

    private init() {
        databaseURL = agentDeskSupportDirectoryURL()
            .appendingPathComponent("agentdesk.db", isDirectory: false)
        prepareDatabase()
        migrateLegacyAppSettingsIfNeeded()
        migrateLegacyModelPricesIfNeeded()
    }

    var path: String {
        databaseURL.path
    }

    func loadModelPrices() -> [String: ModelTokenPrice] {
        guard let db = openDatabase() else { return [:] }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT model, input_per_million, cached_input_per_million, output_per_million, currency
        FROM model_prices
        ORDER BY model COLLATE NOCASE ASC
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [String: ModelTokenPrice] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let modelCString = sqlite3_column_text(statement, 0),
                let currencyCString = sqlite3_column_text(statement, 4)
            else { continue }

            let model = String(cString: modelCString)
            let currencyRaw = String(cString: currencyCString)
            guard let currency = ModelTokenPrice.Currency(rawValue: currencyRaw) else { continue }

            let price = ModelTokenPrice(
                model: model,
                inputPerMillion: sqlite3_column_double(statement, 1),
                cachedInputPerMillion: sqlite3_column_double(statement, 2),
                outputPerMillion: sqlite3_column_double(statement, 3),
                currency: currency
            )
            result[model.lowercased()] = price
        }
        return result
    }

    func saveModelPrices(_ prices: [String: ModelTokenPrice]) {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        _ = execute(sql: "BEGIN IMMEDIATE TRANSACTION", db: db)
        _ = execute(sql: "DELETE FROM model_prices", db: db)

        let insertSQL = """
        INSERT INTO model_prices (model, input_per_million, cached_input_per_million, output_per_million, currency)
        VALUES (?, ?, ?, ?, ?)
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertSQL, -1, &statement, nil) == SQLITE_OK else {
            _ = execute(sql: "ROLLBACK", db: db)
            return
        }
        defer { sqlite3_finalize(statement) }

        for price in prices.values.sorted(by: { $0.model.localizedCaseInsensitiveCompare($1.model) == .orderedAscending }) {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)

            sqlite3_bind_text(statement, 1, price.model, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, price.inputPerMillion)
            sqlite3_bind_double(statement, 3, price.cachedInputPerMillion)
            sqlite3_bind_double(statement, 4, price.outputPerMillion)
            sqlite3_bind_text(statement, 5, price.currency.rawValue, -1, SQLITE_TRANSIENT)

            guard sqlite3_step(statement) == SQLITE_DONE else {
                _ = execute(sql: "ROLLBACK", db: db)
                return
            }
        }

        _ = execute(sql: "COMMIT", db: db)
    }

    func loadUsageSnapshot(provider: UsageProvider) -> UsageSnapshot? {
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT payload
        FROM usage_snapshots
        WHERE provider = ?
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, provider.rawValue, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }

        let bytes = sqlite3_column_blob(statement, 0)
        let length = Int(sqlite3_column_bytes(statement, 0))
        guard let bytes, length > 0 else { return nil }

        let data = Data(bytes: bytes, count: length)
        return try? JSONDecoder().decode(UsageSnapshot.self, from: data)
    }

    func saveUsageSnapshot(_ snapshot: UsageSnapshot) {
        guard snapshot.hasPersistableContent else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO usage_snapshots (provider, updated_at, payload)
        VALUES (?, ?, ?)
        ON CONFLICT(provider) DO UPDATE SET
            updated_at = excluded.updated_at,
            payload = excluded.payload
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, snapshot.provider.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(statement, 2, snapshot.refreshedAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes { rawBuffer in
            sqlite3_bind_blob(statement, 3, rawBuffer.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
        _ = sqlite3_step(statement)
    }

    func string(forKey key: String) -> String? {
        guard let db = openDatabase() else { return nil }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT string_value
        FROM app_settings
        WHERE key = ? AND value_type = 'string'
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let valueCString = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: valueCString)
    }

    func double(forKey key: String) -> Double {
        guard let db = openDatabase() else { return 0 }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT real_value
        FROM app_settings
        WHERE key = ? AND value_type = 'double'
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_double(statement, 0)
    }

    func bool(forKey key: String) -> Bool {
        guard let db = openDatabase() else { return false }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT integer_value
        FROM app_settings
        WHERE key = ? AND value_type = 'bool'
        LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else { return false }
        return sqlite3_column_int(statement, 0) != 0
    }

    func set(_ value: String?, forKey key: String) {
        guard let value else {
            removeValue(forKey: key)
            return
        }
        upsertSetting(key: key, type: "string") { statement in
            sqlite3_bind_text(statement, 3, value, -1, SQLITE_TRANSIENT)
        }
    }

    func set(_ value: Double, forKey key: String) {
        upsertSetting(key: key, type: "double") { statement in
            sqlite3_bind_double(statement, 4, value)
        }
    }

    func set(_ value: Bool, forKey key: String) {
        upsertSetting(key: key, type: "bool") { statement in
            sqlite3_bind_int(statement, 5, value ? 1 : 0)
        }
    }

    private func prepareDatabase() {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let createSQL = """
        CREATE TABLE IF NOT EXISTS model_prices (
            model TEXT PRIMARY KEY,
            input_per_million REAL NOT NULL,
            cached_input_per_million REAL NOT NULL,
            output_per_million REAL NOT NULL,
            currency TEXT NOT NULL,
            updated_at REAL NOT NULL DEFAULT (strftime('%s','now'))
        )
        """
        _ = execute(sql: createSQL, db: db)
        _ = execute(sql: """
        CREATE TABLE IF NOT EXISTS usage_snapshots (
            provider TEXT PRIMARY KEY,
            updated_at REAL NOT NULL,
            payload BLOB NOT NULL
        )
        """, db: db)
        _ = execute(sql: """
        CREATE TABLE IF NOT EXISTS app_settings (
            key TEXT PRIMARY KEY,
            value_type TEXT NOT NULL,
            string_value TEXT,
            real_value REAL,
            integer_value INTEGER,
            updated_at REAL NOT NULL DEFAULT (strftime('%s','now'))
        )
        """, db: db)
    }

    private func migrateLegacyAppSettingsIfNeeded() {
        guard !bool(forKey: Self.migratedAppSettingsFlagKey) else { return }

        let keyMappings: [(new: String, legacy: String, type: LegacySettingType)] = [
            ("AgentDesk.interfaceLanguage", "ModelMeter.interfaceLanguage", .string),
            ("AgentDesk.interfaceThemeMode", "ModelMeter.interfaceThemeMode", .string),
            ("AgentDesk.refreshInterval", "ModelMeter.refreshInterval", .double),
            ("AgentDesk.displayCurrency", "ModelMeter.displayCurrency", .string),
            ("AgentDesk.exchangeRate", "ModelMeter.exchangeRate", .double),
            ("AgentDesk.selectedProviderId", "ModelMeter.selectedProviderId", .string),
            ("AgentDesk.usageProvider", "ModelMeter.usageProvider", .string),
            ("AgentDesk.windowFrame.settings", "ModelMeter.windowFrame.settings", .string)
        ]

        for mapping in keyMappings {
            switch mapping.type {
            case .string:
                guard string(forKey: mapping.new) == nil else { continue }
                if let value = AgentDeskStorage.shared.string(forKey: mapping.new)
                    ?? AgentDeskStorage.shared.string(forKey: mapping.legacy) {
                    set(value, forKey: mapping.new)
                }
            case .double:
                let currentValue = double(forKey: mapping.new)
                guard currentValue == 0 else { continue }
                let newValue = AgentDeskStorage.shared.double(forKey: mapping.new)
                if newValue > 0 {
                    set(newValue, forKey: mapping.new)
                    continue
                }
                let legacyValue = AgentDeskStorage.shared.double(forKey: mapping.legacy)
                if legacyValue > 0 {
                    set(legacyValue, forKey: mapping.new)
                }
            case .bool:
                if bool(forKey: mapping.new) { continue }
                let newValue = AgentDeskStorage.shared.bool(forKey: mapping.new)
                if newValue {
                    set(true, forKey: mapping.new)
                    continue
                }
                if AgentDeskStorage.shared.bool(forKey: mapping.legacy) {
                    set(true, forKey: mapping.new)
                }
            }
        }

        set(true, forKey: Self.migratedAppSettingsFlagKey)
    }

    private func migrateLegacyModelPricesIfNeeded() {
        guard loadModelPrices().isEmpty else { return }
        guard let legacy = AgentDeskStorage.shared.array(forKey: customPricesKey) as? [[String: Any]], !legacy.isEmpty else { return }

        var migrated: [String: ModelTokenPrice] = [:]
        for dict in legacy {
            guard let price = ModelTokenPrice.fromDict(dict) else { continue }
            migrated[price.model.lowercased()] = price
        }
        guard !migrated.isEmpty else { return }
        saveModelPrices(migrated)
    }

    private func openDatabase() -> OpaquePointer? {
        try? fileManager.createDirectory(at: agentDeskSupportDirectoryURL(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    @discardableResult
    private func execute(sql: String, db: OpaquePointer) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func removeValue(forKey key: String) {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = "DELETE FROM app_settings WHERE key = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        _ = sqlite3_step(statement)
    }

    private func upsertSetting(key: String, type: String, bindValue: (OpaquePointer?) -> Void) {
        guard let db = openDatabase() else { return }
        defer { sqlite3_close(db) }

        let sql = """
        INSERT INTO app_settings (key, value_type, string_value, real_value, integer_value, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET
            value_type = excluded.value_type,
            string_value = excluded.string_value,
            real_value = excluded.real_value,
            integer_value = excluded.integer_value,
            updated_at = excluded.updated_at
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, type, -1, SQLITE_TRANSIENT)
        sqlite3_bind_null(statement, 3)
        sqlite3_bind_null(statement, 4)
        sqlite3_bind_null(statement, 5)
        bindValue(statement)
        sqlite3_bind_double(statement, 6, Date().timeIntervalSince1970)
        _ = sqlite3_step(statement)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
private enum LegacySettingType {
    case string
    case double
    case bool
}

func loadExchangeRate() -> Double {
    let rate = AgentDeskDatabase.shared.double(forKey: exchangeRateKey)
    return rate > 0 ? rate : 7.25
}

func saveExchangeRate(_ rate: Double) {
    AgentDeskDatabase.shared.set(rate, forKey: exchangeRateKey)
}

func loadDisplayCurrency() -> ModelTokenPrice.Currency {
    guard let raw = AgentDeskDatabase.shared.string(forKey: displayCurrencyKey),
          let cur = ModelTokenPrice.Currency(rawValue: raw) else { return .cny }
    return cur
}

func saveDisplayCurrency(_ currency: ModelTokenPrice.Currency) {
    AgentDeskDatabase.shared.set(currency.rawValue, forKey: displayCurrencyKey)
}

func convertToDisplayCurrency(_ amount: Double, from source: ModelTokenPrice.Currency) -> Double {
    let target = loadDisplayCurrency()
    if source == target { return amount }
    let rate = loadExchangeRate()
    if source == .cny && target == .usd { return amount / rate }
    if source == .usd && target == .cny { return amount * rate }
    return amount
}

func loadCustomModelPrices() -> [String: ModelTokenPrice] {
    AgentDeskDatabase.shared.loadModelPrices()
}

func saveCustomModelPrices(_ prices: [String: ModelTokenPrice]) {
    AgentDeskDatabase.shared.saveModelPrices(prices)
}

func modelTokenPrice(for model: String?) -> ModelTokenPrice {
    let normalized = (model ?? "").lowercased()

    // Check custom prices first
    let custom = loadCustomModelPrices()
    if let matched = custom[normalized] {
        return matched
    }
    for (key, price) in custom {
        if normalized.contains(key) {
            return price
        }
    }

    // GPT-5.5 系列 (USD)
    if normalized.contains("gpt-5.5-pro") {
        return ModelTokenPrice(model: "gpt-5.5-pro", inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, currency: .usd)
    }
    if normalized.contains("gpt-5.5") || normalized == "chat-latest" {
        return ModelTokenPrice(model: "gpt-5.5", inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, currency: .usd)
    }

    // GPT-5.4 系列 (USD)
    if normalized.contains("gpt-5.4-mini") {
        return ModelTokenPrice(model: "gpt-5.4-mini", inputPerMillion: 0.75, cachedInputPerMillion: 0.075, outputPerMillion: 4.5, currency: .usd)
    }
    if normalized.contains("gpt-5.4-nano") {
        return ModelTokenPrice(model: "gpt-5.4-nano", inputPerMillion: 0.2, cachedInputPerMillion: 0.02, outputPerMillion: 1.25, currency: .usd)
    }
    if normalized.contains("gpt-5.4-pro") {
        return ModelTokenPrice(model: "gpt-5.4-pro", inputPerMillion: 30, cachedInputPerMillion: 30, outputPerMillion: 180, currency: .usd)
    }
    if normalized.contains("gpt-5.4") {
        return ModelTokenPrice(model: "gpt-5.4", inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15, currency: .usd)
    }

    // Codex 模型 (USD)
    if normalized.contains("gpt-5.3-codex") || normalized.contains("gpt-5.2-codex") || normalized.contains("gpt-5.3-chat") {
        return ModelTokenPrice(model: "gpt-5.3-codex", inputPerMillion: 1.75, cachedInputPerMillion: 0.175, outputPerMillion: 14, currency: .usd)
    }

    // ChatGPT (USD)
    if normalized.contains("chatgpt") || normalized.contains("chat-latest") {
        return ModelTokenPrice(model: "chat-latest", inputPerMillion: 5, cachedInputPerMillion: 0.5, outputPerMillion: 30, currency: .usd)
    }

    // GitHub Copilot 模型 (USD)
    if normalized.contains("github-copilot") || normalized.contains("copilot") {
        return ModelTokenPrice(model: "copilot", inputPerMillion: 2.5, cachedInputPerMillion: 0.25, outputPerMillion: 15, currency: .usd)
    }

    // MimoCode 模型 (CNY)
    if normalized.contains("mimo-auto") || normalized.contains("mimo-v2.5") || normalized.contains("mimo") {
        return ModelTokenPrice(model: "mimo", inputPerMillion: 2, cachedInputPerMillion: 0.5, outputPerMillion: 8, currency: .cny)
    }

    // DeepSeek (CNY)
    if normalized.contains("deepseek-v4-pro") || normalized.contains("deepseek-v4") || normalized.contains("ds-v4") {
        return ModelTokenPrice(model: "deepseek-v4-pro", inputPerMillion: 4, cachedInputPerMillion: 1, outputPerMillion: 16, currency: .cny)
    }
    if normalized.contains("deepseek") || normalized.contains("ds-") {
        return ModelTokenPrice(model: "deepseek", inputPerMillion: 1, cachedInputPerMillion: 0.2, outputPerMillion: 4, currency: .cny)
    }

    // Qwen (CNY)
    if normalized.contains("qwen3.7-max") || normalized.contains("qwen-max") {
        return ModelTokenPrice(model: "qwen-max", inputPerMillion: 4, cachedInputPerMillion: 1, outputPerMillion: 16, currency: .cny)
    }
    if normalized.contains("qwen3.7-plus") || normalized.contains("qwen-plus") {
        return ModelTokenPrice(model: "qwen-plus", inputPerMillion: 0.8, cachedInputPerMillion: 0.2, outputPerMillion: 4, currency: .cny)
    }
    if normalized.contains("qwen") {
        return ModelTokenPrice(model: "qwen", inputPerMillion: 0.8, cachedInputPerMillion: 0.2, outputPerMillion: 4, currency: .cny)
    }

    // GLM (CNY)
    if normalized.contains("glm-5.2") || normalized.contains("glm-5.1") || normalized.contains("glm-5") {
        return ModelTokenPrice(model: "glm-5", inputPerMillion: 2, cachedInputPerMillion: 0.5, outputPerMillion: 8, currency: .cny)
    }
    if normalized.contains("glm") {
        return ModelTokenPrice(model: "glm", inputPerMillion: 0.5, cachedInputPerMillion: 0.15, outputPerMillion: 2, currency: .cny)
    }

    // Kimi (CNY)
    if normalized.contains("kimi") {
        return ModelTokenPrice(model: "kimi", inputPerMillion: 2, cachedInputPerMillion: 0.5, outputPerMillion: 8, currency: .cny)
    }

    // MiniMax (CNY)
    if normalized.contains("minimax") {
        return ModelTokenPrice(model: "minimax", inputPerMillion: 1, cachedInputPerMillion: 0.2, outputPerMillion: 4, currency: .cny)
    }

    // 默认
    return ModelTokenPrice(model: "unknown", inputPerMillion: 0, cachedInputPerMillion: 0, outputPerMillion: 0, currency: .usd)
}

func estimatedCostUSD(tokens: TokenBreakdown, price: ModelTokenPrice) -> Double {
    let uncachedInputCost = Double(tokens.uncachedInputTokens) / 1_000_000 * price.inputPerMillion
    let cachedInputCost = Double(tokens.billableCachedInputTokens) / 1_000_000 * price.cachedInputPerMillion
    let outputCost = Double(max(tokens.outputTokens, 0)) / 1_000_000 * price.outputPerMillion
    return uncachedInputCost + cachedInputCost + outputCost
}

func normalizedTitle(_ title: String?, fallback: String?) -> String {
    let raw = [title, fallback]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty } ?? "Untitled"

    let singleLine = raw
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

    if singleLine.count <= 48 { return singleLine }
    return String(singleLine.prefix(45)) + "..."
}

func normalizedModelName(_ model: String?, fallback: String) -> String {
    let raw = (model ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let candidate = raw.isEmpty ? fallback : raw
    if candidate.count <= 28 { return candidate }
    return String(candidate.prefix(25)) + "..."
}

private let modelUsageKeySeparator = "||provider||"

func modelUsageBucketKey(model: String, provider: String?) -> String {
    let trimmedProvider = (provider ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedProvider.isEmpty else { return model }
    return "\(model)\(modelUsageKeySeparator)\(trimmedProvider)"
}

func modelUsageModelName(from key: String) -> String {
    key.components(separatedBy: modelUsageKeySeparator).first ?? key
}

func modelUsageProviderName(from key: String) -> String? {
    let parts = key.components(separatedBy: modelUsageKeySeparator)
    guard parts.count > 1, !parts[1].isEmpty else { return nil }
    return parts[1]
}

func modelUsageDisplayLabel(from key: String) -> String {
    let model = modelUsageModelName(from: key)
    guard let provider = modelUsageProviderName(from: key) else { return model }
    return "\(model) · \(provider)"
}

func sortedModelUsageItems(
    _ usageByModel: [String: PricedTokenUsage],
    providers: [String: String] = [:],
    throughput: [String: Double] = [:]
) -> [ModelUsageItem] {
    usageByModel.map { key, value in
        let model = modelUsageModelName(from: key)
        let provider = providers[key] ?? modelUsageProviderName(from: key) ?? modelProvider(from: model)
        let price = modelTokenPrice(for: model)
        let tps = throughput[key] ?? 0
        return ModelUsageItem(
            model: model,
            provider: provider,
            tokens: value.tokens.visibleTotalTokens,
            uncachedInputTokens: value.tokens.uncachedInputTokens,
            cachedInputTokens: value.tokens.billableCachedInputTokens,
            outputTokens: value.tokens.outputTokens,
            estimatedCostUSD: value.estimatedCostUSD,
            inputPricePerMillion: price.inputPerMillion,
            cachedInputPricePerMillion: price.cachedInputPerMillion,
            outputPricePerMillion: price.outputPerMillion,
            currency: price.currency,
            avgTokensPerSecond: tps
        )
    }
    .sorted { lhs, rhs in
        if lhs.tokens == rhs.tokens {
            return lhs.model.localizedCaseInsensitiveCompare(rhs.model) == .orderedAscending
        }
        return lhs.tokens > rhs.tokens
    }
}

func shortWorkspaceName(_ path: String) -> String {
    guard !path.isEmpty else { return "" }
    let url = URL(fileURLWithPath: path)
    let name = url.lastPathComponent
    if !name.isEmpty { return name }
    return path
}

func relativeTimeText(_ date: Date, language: WidgetLanguage) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return language.text("刚刚", "just now") }
    let minutes = seconds / 60
    if minutes < 60 { return language.text("\(minutes) 分钟前", "\(minutes)m ago") }
    let hours = minutes / 60
    if hours < 24 { return language.text("\(hours) 小时前", "\(hours)h ago") }
    return language.text("\(hours / 24) 天前", "\(hours / 24)d ago")
}

func intValue(_ value: Any?) -> Int? {
    if let int = value as? Int { return int }
    if let int64 = value as? Int64 { return Int(int64) }
    if let double = value as? Double { return Int(double) }
    if let string = value as? String { return Int(string) }
    return nil
}

func int64Value(_ value: Any?) -> Int64? {
    if let int = value as? Int { return Int64(int) }
    if let int64 = value as? Int64 { return int64 }
    if let double = value as? Double { return Int64(double) }
    if let string = value as? String { return Int64(string) }
    return nil
}

func doubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    if let int64 = value as? Int64 { return Double(int64) }
    if let string = value as? String { return Double(string) }
    return nil
}

func stringValue(_ value: Any?) -> String? {
    if let string = value as? String { return string }
    if let number = value as? NSNumber { return number.stringValue }
    return nil
}

func dateFromEpoch(_ value: Any?) -> Date? {
    guard var seconds = doubleValue(value), seconds > 0 else { return nil }
    if seconds > 10_000_000_000 {
        seconds /= 1000
    }
    return Date(timeIntervalSince1970: seconds)
}

func epochMilliseconds(_ value: Any?) -> Double? {
    guard let rawValue = doubleValue(value), rawValue > 0 else { return nil }
    if rawValue > 10_000_000_000 {
        return rawValue
    }
    return rawValue * 1000
}


func formatTokens(_ value: Int64?) -> String {
    guard let value else { return "--" }
    let absValue = abs(Double(value))
    if absValue >= 1_000_000_000 {
        return String(format: "%.1fB", Double(value) / 1_000_000_000)
    }
    if absValue >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if absValue >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}

func formatUSD(_ value: Double?, currency: ModelTokenPrice.Currency? = nil) -> String {
    guard let value else { return "--" }
    let symbol = currency?.rawValue ?? loadDisplayCurrency().rawValue
    let absValue = abs(value)
    if absValue >= 1_000 {
        return String(format: "\(symbol)%.0f", value)
    }
    return String(format: "\(symbol)%.2f", value)
}

func formatCompactUSD(_ value: Double?, currency: ModelTokenPrice.Currency? = nil) -> String {
    guard let value else { return "--" }
    let symbol = currency?.rawValue ?? loadDisplayCurrency().rawValue
    let absValue = abs(value)
    if absValue >= 1_000_000 {
        return String(format: "\(symbol)%.1fM", value / 1_000_000)
    }
    if absValue >= 10_000 {
        return String(format: "\(symbol)%.1fK", value / 1_000)
    }
    if absValue >= 1_000 {
        return String(format: "\(symbol)%.0f", value)
    }
    return String(format: "\(symbol)%.0f", value)
}

func formatUSDPerMillion(_ value: Double, currency: ModelTokenPrice.Currency = .usd) -> String {
    let symbol = currency.rawValue
    return String(format: "\(symbol)%.2f/M", value)
}

func speedColor(_ tokensPerSecond: Double) -> Color {
    if tokensPerSecond >= 80 { return WidgetPalette.statusSuccess }
    if tokensPerSecond >= 40 { return WidgetPalette.statusInfo }
    if tokensPerSecond >= 20 { return WidgetPalette.statusWarning }
    return WidgetPalette.statusDanger
}

func currencyColor(_ currency: ModelTokenPrice.Currency) -> Color {
    switch currency {
    case .cny: return WidgetPalette.statusDanger
    case .usd: return WidgetPalette.statusSuccess
    }
}

func formatUsagePercent(_ value: Double) -> String {
    if value > 0, value < 1 {
        return "<1%"
    }
    return "\(Int(value.rounded()))%"
}

func localizedDayLabel(_ label: String, language: WidgetLanguage) -> String {
    if label == "今天" {
        return language.text("今天", "Today")
    }
    return label
}

func localizedTaskDetail(_ detail: String, language: WidgetLanguage) -> String {
    guard !language.isChinese else { return detail }
    return detail
        .replacingOccurrences(of: "每天", with: "Daily")
        .replacingOccurrences(of: "每周", with: "Weekly")
        .replacingOccurrences(of: "每小时", with: "Hourly")
}

func localizedReaderMessage(_ message: String, language: WidgetLanguage) -> String {
    guard !language.isChinese else { return message }
    if message == "正在读取 AgentDesk 数据" { return "Reading AgentDesk data" }
    if message == "正在读取 Codex 数据" { return "Reading Codex data" }
    if message == "正在读取 MimoCode 数据" { return "Reading MimoCode data" }
    if message.contains("未找到 codex") { return "Codex executable not found" }
    if message.contains("app-server 启动失败") { return "Failed to start app-server" }
    if message.contains("app-server 响应超时") { return "app-server response timed out" }
    if message.contains("未找到 Codex state_5.sqlite") { return "Codex state_5.sqlite not found" }
    if message.contains("未找到 MimoCode mimocode.db") { return "MimoCode mimocode.db not found" }
    if message.contains("未找到 MimoCode token") { return "MimoCode token events not found" }
    if message.contains("未找到 sqlite3") { return "sqlite3 not found" }
    if message.contains("SQLite 查询失败") { return "SQLite query failed" }
    if message.contains("未找到 Codex session 日志") { return "Codex session logs not found" }
    if message.contains("未找到 Codex token_count 事件") { return "Codex token_count events not found" }
    if message.contains("app-server") { return message.replacingOccurrences(of: "未知错误", with: "Unknown error") }
    return message
}

func timeOnly(_ date: Date, language: WidgetLanguage = .zh) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: language.isChinese ? "zh_CN" : "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func resetDateTime(_ date: Date, language: WidgetLanguage = .zh) -> String {
    if Calendar.current.isDateInToday(date) {
        return timeOnly(date, language: language)
    }

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: language.isChinese ? "zh_CN" : "en_US_POSIX")
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

func isoString(_ date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = ISO8601DateFormatter()
    return formatter.string(from: date)
}

func jsonValue<T>(_ value: T?) -> Any {
    value.map { $0 as Any } ?? NSNull()
}

func jsonObject(_ usage: PricedTokenUsage) -> [String: Any] {
    [
        "estimatedCostUSD": usage.estimatedCostUSD,
        "tokens": [
            "inputTokens": usage.tokens.inputTokens,
            "cachedInputTokens": usage.tokens.billableCachedInputTokens,
            "uncachedInputTokens": usage.tokens.uncachedInputTokens,
            "outputTokens": usage.tokens.outputTokens,
            "reasoningOutputTokens": usage.tokens.reasoningOutputTokens,
            "totalTokens": usage.tokens.visibleTotalTokens
        ] as [String: Any]
    ]
}


func fourCharCode(_ value: String) -> OSType {
    value.utf8.reduce(0) { result, byte in
        (result << 8) + OSType(byte)
    }
}

func debugLog(_ message: String) {
    guard ProcessInfo.processInfo.environment["CODEX_USAGE_WIDGET_DEBUG"] == "1" else { return }

    let formatter = ISO8601DateFormatter()
    let line = "\(formatter.string(from: Date())) \(message)\n"
    let url = URL(fileURLWithPath: "/tmp/agentdesk.log")

    guard let data = line.data(using: .utf8) else { return }

    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: url, options: .atomic)
    }
}

func firstExecutablePath(_ paths: [String]) -> String? {
    paths.first { FileManager.default.isExecutableFile(atPath: $0) }
}


// MARK: - JSON Dump

func dumpJSON(_ snapshot: UsageSnapshot) {
    var object: [String: Any] = [
        "provider": snapshot.provider.rawValue,
        "refreshedAt": isoString(snapshot.refreshedAt) ?? "",
        "messages": snapshot.messages
    ]

    if let account = snapshot.account {
        object["account"] = [
            "type": account.type,
            "planType": jsonValue(account.planType),
            "emailPresent": account.emailPresent
        ] as [String: Any]
    }

    if let primary = snapshot.primary {
        object["primary"] = [
            "usedPercent": primary.usedPercent,
            "remainingPercent": primary.remainingPercent,
            "windowDurationMins": jsonValue(primary.windowDurationMins),
            "resetsAt": jsonValue(isoString(primary.resetsAt))
        ] as [String: Any]
    }

    if let secondary = snapshot.secondary {
        object["secondary"] = [
            "usedPercent": secondary.usedPercent,
            "remainingPercent": secondary.remainingPercent,
            "windowDurationMins": jsonValue(secondary.windowDurationMins),
            "resetsAt": jsonValue(isoString(secondary.resetsAt))
        ] as [String: Any]
    }

    if let credits = snapshot.credits {
        object["credits"] = [
            "hasCredits": credits.hasCredits,
            "unlimited": credits.unlimited,
            "balance": jsonValue(credits.balance),
            "resetCredits": jsonValue(credits.resetCredits)
        ] as [String: Any]
    }

    if let local = snapshot.local {
        var localObject: [String: Any] = [
            "todayTokens": local.todayTokens,
            "sevenDayTokens": local.sevenDayTokens,
            "lifetimeTokens": local.lifetimeTokens,
            "threadCount": local.threadCount,
            "lastUpdatedAt": jsonValue(isoString(local.lastUpdatedAt)),
            "dailyBuckets": local.dailyBuckets.map { bucket in
                [
                    "day": bucket.id,
                    "label": bucket.label,
                    "tokens": bucket.tokens
                ] as [String: Any]
            }
        ]

        if let detailed = local.detailedUsage {
            localObject["detailedUsage"] = [
                "today": jsonObject(detailed.today),
                "sevenDay": jsonObject(detailed.sevenDay),
                "month": jsonObject(detailed.month),
                "lifetime": jsonObject(detailed.lifetime),
                "parsedFileCount": detailed.parsedFileCount,
                "tokenEventCount": detailed.tokenEventCount
            ] as [String: Any]
        }

        localObject["todayModelUsage"] = local.todayModelUsage.map { item in
            [
                "model": item.model, "provider": item.provider,
                "tokens": item.tokens, "uncachedInputTokens": item.uncachedInputTokens,
                "cachedInputTokens": item.cachedInputTokens, "outputTokens": item.outputTokens,
                "estimatedCostUSD": item.estimatedCostUSD,
                "inputPricePerMillion": item.inputPricePerMillion,
                "cachedInputPricePerMillion": item.cachedInputPricePerMillion,
                "outputPricePerMillion": item.outputPricePerMillion,
                "currency": item.currency.rawValue,
                "avgTokensPerSecond": item.avgTokensPerSecond
            ] as [String: Any]
        }
        localObject["sevenDayModelUsage"] = local.sevenDayModelUsage.map { item in
            [
                "model": item.model, "provider": item.provider,
                "tokens": item.tokens, "uncachedInputTokens": item.uncachedInputTokens,
                "cachedInputTokens": item.cachedInputTokens, "outputTokens": item.outputTokens,
                "estimatedCostUSD": item.estimatedCostUSD,
                "inputPricePerMillion": item.inputPricePerMillion,
                "cachedInputPricePerMillion": item.cachedInputPricePerMillion,
                "outputPricePerMillion": item.outputPricePerMillion,
                "currency": item.currency.rawValue,
                "avgTokensPerSecond": item.avgTokensPerSecond
            ] as [String: Any]
        }
        localObject["lifetimeModelUsage"] = local.lifetimeModelUsage.map { item in
            [
                "model": item.model, "provider": item.provider,
                "tokens": item.tokens, "uncachedInputTokens": item.uncachedInputTokens,
                "cachedInputTokens": item.cachedInputTokens, "outputTokens": item.outputTokens,
                "estimatedCostUSD": item.estimatedCostUSD,
                "inputPricePerMillion": item.inputPricePerMillion,
                "cachedInputPricePerMillion": item.cachedInputPricePerMillion,
                "outputPricePerMillion": item.outputPricePerMillion,
                "currency": item.currency.rawValue,
                "avgTokensPerSecond": item.avgTokensPerSecond
            ] as [String: Any]
        }

        object["local"] = localObject
    }

    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}
