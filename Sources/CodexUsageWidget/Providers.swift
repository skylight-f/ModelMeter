import Foundation


struct ModelTokenPrice {
    let model: String
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let outputPerMillion: Double
    let currency: Currency

    enum Currency: String, CaseIterable, Codable {
        case usd = "$"
        case cny = "¥"
    }

    var asDict: [String: Any] {
        [
            "model": model,
            "inputPerMillion": inputPerMillion,
            "cachedInputPerMillion": cachedInputPerMillion,
            "outputPerMillion": outputPerMillion,
            "currency": currency.rawValue
        ]
    }

    static func fromDict(_ dict: [String: Any]) -> ModelTokenPrice? {
        guard let model = dict["model"] as? String,
              let input = dict["inputPerMillion"] as? Double,
              let cached = dict["cachedInputPerMillion"] as? Double,
              let output = dict["outputPerMillion"] as? Double,
              let cur = dict["currency"] as? String,
              let currency = Currency(rawValue: cur)
        else { return nil }
        return ModelTokenPrice(model: model, inputPerMillion: input, cachedInputPerMillion: cached, outputPerMillion: output, currency: currency)
    }
}
