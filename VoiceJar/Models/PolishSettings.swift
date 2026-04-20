import Foundation
import Security

/// 润色引擎配置 — 持久化到 UserDefaults + Keychain
/// keyPrefix 区分不同用途（润色 vs 翻译）
@Observable
class PolishSettings {
    private let keyPrefix: String

    var engine: PolishEngine = .none {
        didSet { save() }
    }
    var model: String = "" {
        didSet { save() }
    }
    var baseURL: String = "" {
        didSet { save() }
    }
    var apiKey: String = "" {
        didSet { saveAPIKey() }
    }

    init(keyPrefix: String = "polish") {
        self.keyPrefix = keyPrefix
        load()
    }

    /// 生成线程安全的快照用于 async 调用
    var snapshot: PolishSettingsSnapshot {
        PolishSettingsSnapshot(
            engine: engine,
            model: model.isEmpty ? engine.defaultModel : model,
            baseURL: baseURL,
            apiKey: apiKey
        )
    }

    /// 切换引擎时重置为默认值
    func switchEngine(to newEngine: PolishEngine) {
        engine = newEngine
        model = newEngine.defaultModel
        baseURL = ""
    }

    // MARK: - 持久化

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(engine.rawValue, forKey: "\(keyPrefix)_engine")
        defaults.set(model, forKey: "\(keyPrefix)_model")
        defaults.set(baseURL, forKey: "\(keyPrefix)_baseURL")
    }

    private func load() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "\(keyPrefix)_engine"),
           let eng = PolishEngine(rawValue: raw) {
            engine = eng
        }
        model = defaults.string(forKey: "\(keyPrefix)_model") ?? ""
        baseURL = defaults.string(forKey: "\(keyPrefix)_baseURL") ?? ""
        apiKey = loadAPIKeyFromKeychain() ?? ""
    }

    // MARK: - Keychain

    private static let keychainService = "com.clearsky.VoiceJar"
    private var keychainAccount: String { "\(keyPrefix)_apiKey" }

    private func saveAPIKey() {
        guard !apiKey.isEmpty else {
            deleteAPIKeyFromKeychain()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)

        var newItem = query
        guard let data = apiKey.data(using: .utf8) else { return }
        newItem[kSecValueData as String] = data
        newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(newItem as CFDictionary, nil)
    }

    private func loadAPIKeyFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deleteAPIKeyFromKeychain() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// 线程安全的设置快照
struct PolishSettingsSnapshot: Sendable {
    let engine: PolishEngine
    let model: String
    let baseURL: String
    let apiKey: String
}
