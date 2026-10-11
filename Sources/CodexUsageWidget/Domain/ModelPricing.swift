import Foundation

struct ModelTokenPrice: Decodable {
    let model: String
    let aliases: [String]
    let inputPerMillion: Double
    let cachedInputPerMillion: Double
    let cacheWriteInputPerMillion: Double
    let outputPerMillion: Double
    let tierMultipliers: [String: Double]
    let longContextThreshold: Int64?
    let longContextInputMultiplier: Double?
    let longContextOutputMultiplier: Double?
    let fastSupportsLongContext: Bool
    var usesReferencePricing: Bool

    func matches(_ value: String) -> Bool {
        ([model] + aliases).contains { name in
            if value == name { return true }
            guard value.hasPrefix(name + "-") else { return false }
            let suffix = String(value.dropFirst(name.count + 1))
            if name.hasPrefix("claude-") {
                return !suffix.isEmpty && suffix.utf8.allSatisfy { (48...57).contains($0) || $0 == 45 || $0 == 46 }
            }
            // Only dated snapshots inherit a catalog price; a new variant is unknown.
            return suffix.count == 10 && suffix.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil
        }
    }

    func isReference(serviceTier: String?) -> Bool {
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "default"
        return usesReferencePricing || tierMultipliers[tier.isEmpty ? "default" : tier] == nil
    }

    func estimate(input: Int64, cached: Int64, write: Int64, output: Int64, serviceTier: String?) -> Double {
        let input = max(0, input)
        let cached = min(input, max(0, cached))
        let write = min(input - cached, max(0, write))
        let long = longContextThreshold.map { input > $0 } ?? false
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "default"
        let fast = tier == "priority" || tier == "fast"
        let multiplier = long && fast && !fastSupportsLongContext ? 1 : (tierMultipliers[tier] ?? 1)
        let inputMultiplier = multiplier * (long ? longContextInputMultiplier ?? 1 : 1)
        let outputMultiplier = multiplier * (long ? longContextOutputMultiplier ?? 1 : 1)
        return (Double(input - cached - write) * inputPerMillion
            + Double(cached) * cachedInputPerMillion
            + Double(write) * cacheWriteInputPerMillion) / 1_000_000 * inputMultiplier
            + Double(max(0, output)) / 1_000_000 * outputPerMillion * outputMultiplier
    }
}

struct ModelPricingCatalog: Decodable {
    let schemaVersion: Int
    let referenceModel: String
    let models: [ModelTokenPrice]

    static let data: Data = {
        guard let url = Bundle.main.url(forResource: "model-pricing", withExtension: "json"),
              let bytes = try? Data(contentsOf: url) else {
            preconditionFailure("Missing packaged model-pricing.json")
        }
        return bytes
    }()
    static let shared: ModelPricingCatalog = {
        guard let catalog = try? JSONDecoder().decode(ModelPricingCatalog.self, from: data),
              catalog.schemaVersion == 1, catalog.models.contains(where: { $0.model == catalog.referenceModel }) else {
            preconditionFailure("Invalid packaged model-pricing.json")
        }
        return catalog
    }()

    func price(for model: String?) -> ModelTokenPrice {
        let name = (model ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let price = models.first(where: { $0.matches(name) }) { return price }
        var price = models.first { $0.model == referenceModel }!
        price.usesReferencePricing = true
        return price
    }
}

enum SharedModelPricingSelfTest {
    private struct Vector: Decodable {
        let name: String
        let model: String
        let input: Int64
        let cached: Int64
        let write: Int64
        let output: Int64
        let tier: String?
        let expected: Double
        let reference: Bool
    }

    static func run() -> Bool {
        guard let url = Bundle.main.url(forResource: "model-pricing-vectors", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let vectors = try? JSONDecoder().decode([Vector].self, from: data) else { return false }
        for v in vectors {
            let price = ModelPricingCatalog.shared.price(for: v.model)
            let cost = price.estimate(input: v.input, cached: v.cached, write: v.write, output: v.output, serviceTier: v.tier)
            guard abs(cost - v.expected) < 1e-10, price.isReference(serviceTier: v.tier) == v.reference else {
                print("shared pricing vector failed: \(v.name): \(cost)")
                return false
            }
        }
        print("shared pricing vectors passed: \(vectors.count)")
        return true
    }
}
