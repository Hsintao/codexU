import Foundation
import LocalAuthentication
import Security

struct KimiAPIKeyStore {
    static let legacyDefaultsKey = "codexU.kimiAPIKey"
    let service: String

    init(service: String = "com.guomeiqing.codexu.kimi-api-key") {
        self.service = service
    }

    struct Failure: Error {
        let status: OSStatus
        var message: String { "Kimi Keychain 读取或保存失败（\(status)）" }
    }

    private var query: [String: Any] {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "kimi-coding-plan",
         kSecAttrSynchronizable as String: false,
         kSecUseAuthenticationContext as String: authentication]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw Failure(status: errSecDecode)
        }
        return value
    }

    func write(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
            return
        }
        let attributes = [kSecValueData as String: Data(trimmed.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = Data(trimmed.utf8)
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    // Remove the previous plaintext preference only after secure storage has
    // succeeded. Failure is surfaced to the caller rather than losing the key.
    func loadMigrating(defaults: UserDefaults) throws -> String? {
        if let saved = try read() {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
            return saved
        }
        guard let legacy = defaults.string(forKey: Self.legacyDefaultsKey) else { return nil }
        try write(legacy)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
