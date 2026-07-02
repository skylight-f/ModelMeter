import Cocoa
import SwiftUI

func modelTokenPrice(for model: String?) -> ModelTokenPrice {
    let normalized = (model ?? "").lowercased()

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

func parseSimpleTOML(_ text: String) -> [String: String] {
    var fields: [String: String] = [:]

    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else {
            continue
        }

        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value.removeFirst()
            value.removeLast()
        }

        fields[key] = value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    return fields
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

func sortedModelUsageItems(_ usageByModel: [String: PricedTokenUsage], providers: [String: String] = [:]) -> [ModelUsageItem] {
    usageByModel.map { key, value in
        let provider = providers[key] ?? modelProvider(from: key)
        let price = modelTokenPrice(for: key)
        return ModelUsageItem(
            model: key,
            provider: provider,
            tokens: value.tokens.visibleTotalTokens,
            uncachedInputTokens: value.tokens.uncachedInputTokens,
            cachedInputTokens: value.tokens.billableCachedInputTokens,
            outputTokens: value.tokens.outputTokens,
            estimatedCostUSD: value.estimatedCostUSD,
            inputPricePerMillion: price.inputPerMillion,
            cachedInputPricePerMillion: price.cachedInputPerMillion,
            outputPricePerMillion: price.outputPerMillion,
            currency: price.currency
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

func scheduleSummary(_ rrule: String?) -> String {
    guard let rrule, !rrule.isEmpty else { return "" }

    var timeText = ""
    if let range = rrule.range(of: #"T(\d{2})(\d{2})(\d{2})"#, options: .regularExpression) {
        let match = String(rrule[range])
        let start = match.index(after: match.startIndex)
        let hourEnd = match.index(start, offsetBy: 2)
        let minuteEnd = match.index(hourEnd, offsetBy: 2)
        timeText = "\(match[start..<hourEnd]):\(match[hourEnd..<minuteEnd])"
    }

    if rrule.contains("FREQ=DAILY") {
        return timeText.isEmpty ? "每天" : "每天 \(timeText)"
    }
    if rrule.contains("FREQ=WEEKLY") {
        return timeText.isEmpty ? "每周" : "每周 \(timeText)"
    }
    if rrule.contains("FREQ=HOURLY") {
        return "每小时"
    }
    return timeText
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


func formatTokens(_ value: Int64?) -> String {
    guard let value else { return "--" }
    let absValue = abs(Double(value))
    if absValue >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if absValue >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}

func formatUSD(_ value: Double?) -> String {
    guard let value else { return "--" }
    let absValue = abs(value)
    if absValue >= 1_000 {
        return String(format: "$%.0f", value)
    }
    return String(format: "$%.2f", value)
}

func formatCompactUSD(_ value: Double?) -> String {
    guard let value else { return "--" }
    let absValue = abs(value)
    if absValue >= 1_000_000 {
        return String(format: "$%.1fM", value / 1_000_000)
    }
    if absValue >= 10_000 {
        return String(format: "$%.1fK", value / 1_000)
    }
    if absValue >= 1_000 {
        return String(format: "$%.0f", value)
    }
    return String(format: "$%.0f", value)
}

func formatUSDPerMillion(_ value: Double) -> String {
    String(format: "$%.2f/M", value)
}

func formatUsagePercent(_ value: Double) -> String {
    if value > 0, value < 1 {
        return "<1%"
    }
    return "\(Int(value.rounded()))%"
}

func taskAccentColor(_ kind: TaskColumnKind) -> Color {
    switch kind {
    case .active:
        return WidgetPalette.statusWarning
    case .pending:
        return WidgetPalette.statusNeutral
    case .scheduled:
        return WidgetPalette.brandSecondary
    case .done:
        return WidgetPalette.statusSuccess
    }
}

func taskColumnFill(_ kind: TaskColumnKind) -> Color {
    taskAccentColor(kind).opacity(0.065)
}

func taskColumnIcon(_ kind: TaskColumnKind) -> String {
    switch kind {
    case .active:
        return "record.circle"
    case .pending:
        return "circle"
    case .scheduled:
        return "clock"
    case .done:
        return "checkmark.circle.fill"
    }
}

func localizedTaskColumnTitle(_ kind: TaskColumnKind, language: WidgetLanguage) -> String {
    switch kind {
    case .active:
        return language.text("进行中", "Active")
    case .pending:
        return language.text("待处理", "Pending")
    case .scheduled:
        return language.text("定时", "Scheduled")
    case .done:
        return language.text("完成", "Done")
    }
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
    if message == "正在读取 ModelMeter 数据" { return "Reading ModelMeter data" }
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
    if message.contains("任务看板未找到 SQLite 数据源") { return "Task board SQLite data source not found" }
    if message.contains("app-server") { return message.replacingOccurrences(of: "未知错误", with: "Unknown error") }
    return message
}

func taskAvatarText(_ item: TaskItem) -> String {
    if item.code.hasPrefix("AUTO") { return "B" }
    let source = item.detail.split(separator: "·").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let first = source.first {
        return String(first).uppercased()
    }
    return "C"
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
    let url = URL(fileURLWithPath: "/tmp/codexu.log")

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
                "currency": item.currency.rawValue
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
                "currency": item.currency.rawValue
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
                "currency": item.currency.rawValue
            ] as [String: Any]
        }

        object["local"] = localObject
    }

    if let taskBoard = snapshot.taskBoard {
        object["taskBoard"] = [
            "refreshedAt": isoString(taskBoard.refreshedAt) ?? "",
            "totalCount": taskBoard.totalCount,
            "columns": taskBoard.columns.map { column in
                [
                    "id": column.id.rawValue,
                    "title": column.title,
                    "count": column.count,
                    "items": column.items.map { item in
                        [
                            "id": item.id, "code": item.code, "title": item.title,
                            "detail": item.detail, "chip": item.chip,
                            "updatedAt": jsonValue(isoString(item.updatedAt)),
                            "tokens": jsonValue(item.tokens)
                        ] as [String: Any]
                    }
                ] as [String: Any]
            }
        ] as [String: Any]
    }

    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}
