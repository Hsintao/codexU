import Foundation
import Security

enum KimiAPIKeyStoreSelfTest {
    static func run() -> Bool {
        let suite = "codexU.kimi-key-self-test.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return false }
        let store = KimiAPIKeyStore(service: suite)
        defer { try? store.write(""); defaults.removePersistentDomain(forName: suite) }
        do {
            defaults.set("  fixture-key-A  ", forKey: KimiAPIKeyStore.legacyDefaultsKey)
            let settings = AppSettings(defaults: defaults, kimiKeyStore: store)
            guard settings.kimiAPIKey == "fixture-key-A", settings.kimiAPIKeyError == nil,
                  defaults.object(forKey: KimiAPIKeyStore.legacyDefaultsKey) == nil,
                  try store.read() == "fixture-key-A" else {
                print("Kimi Keychain self-test failed: legacy keys must migrate out of preferences")
                return false
            }
            settings.setKimiAPIKey(" fixture-key-B ")
            guard settings.kimiAPIKey == "fixture-key-B", try store.read() == "fixture-key-B",
                  defaults.object(forKey: KimiAPIKeyStore.legacyDefaultsKey) == nil else {
                print("Kimi Keychain self-test failed: edits must persist only in Keychain")
                return false
            }
            // A stale plaintext preference must not override a securely saved key.
            defaults.set("fixture-stale-key", forKey: KimiAPIKeyStore.legacyDefaultsKey)
            let restored = AppSettings(defaults: defaults, kimiKeyStore: store)
            guard restored.kimiAPIKey == "fixture-key-B",
                  defaults.object(forKey: KimiAPIKeyStore.legacyDefaultsKey) == nil else { return false }
            restored.setKimiAPIKey("")
            guard restored.kimiAPIKey.isEmpty, try store.read() == nil else { return false }
            // A malformed secure item must surface an error and leave the
            // migration source intact, rather than choosing another account.
            defaults.set("fixture-retained-key", forKey: KimiAPIKeyStore.legacyDefaultsKey)
            let corruptItem: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: suite,
                kSecAttrAccount as String: "kimi-coding-plan",
                kSecValueData as String: Data([0xff])
            ]
            guard SecItemAdd(corruptItem as CFDictionary, nil) == errSecSuccess else { return false }
            let unreadable = AppSettings(defaults: defaults, kimiKeyStore: store)
            guard unreadable.kimiAPIKeyError != nil, unreadable.kimiAPIKey.isEmpty,
                  defaults.string(forKey: KimiAPIKeyStore.legacyDefaultsKey) == "fixture-retained-key" else {
                print("Kimi Keychain self-test failed: read failure must preserve the migration source and surface its error")
                return false
            }
            unreadable.setKimiAPIKey("fixture-repaired-key")
            guard unreadable.kimiAPIKeyError == nil, try store.read() == "fixture-repaired-key",
                  defaults.object(forKey: KimiAPIKeyStore.legacyDefaultsKey) == nil else { return false }
            print("Kimi Keychain self-test passed")
            return true
        } catch {
            print("Kimi Keychain self-test failed: \(error)")
            return false
        }
    }
}
