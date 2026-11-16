import Foundation
import Combine

/// 本机设置与部署记录（记录本身加密落在钥匙串，元信息放 UserDefaults）
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    @Published var token: String
    @Published var record: DeploymentRecord?
    /// 记住上次使用的账号与 KV，更新部署时直接沿用
    @Published var rememberedAccountId: String
    @Published var rememberedKvNamespaceId: String
    /// 优选器默认的探测域名（留空时自动用部署记录里的节点域名）
    @Published var proberHost: String
    @Published var proberUsesBuiltinRanges: Bool
    @Published var proberCandidates: Int

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let accountId = "cfpilot.accountId"
        static let kvNamespaceId = "cfpilot.kvNamespaceId"
        static let proberHost = "cfpilot.proberHost"
        static let proberBuiltin = "cfpilot.proberBuiltin"
        static let proberCandidates = "cfpilot.proberCandidates"
    }

    private init() {
        token = KeychainStore.read(SecretKey.apiToken) ?? ""
        rememberedAccountId = defaults.string(forKey: Keys.accountId) ?? ""
        rememberedKvNamespaceId = defaults.string(forKey: Keys.kvNamespaceId) ?? ""
        proberHost = defaults.string(forKey: Keys.proberHost) ?? ""
        proberUsesBuiltinRanges = defaults.object(forKey: Keys.proberBuiltin) as? Bool ?? true
        let savedCount = defaults.integer(forKey: Keys.proberCandidates)
        proberCandidates = savedCount > 0 ? savedCount : 80
        record = SettingsStore.loadRecord()
    }

    // MARK: - Token

    func saveToken(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        token = trimmed
        if trimmed.isEmpty {
            KeychainStore.delete(SecretKey.apiToken)
        } else {
            KeychainStore.save(trimmed, for: SecretKey.apiToken)
        }
    }

    func maskedToken() -> String {
        guard token.count > 10 else { return token.isEmpty ? "未填写" : "••••" }
        return "\(token.prefix(4))••••••\(token.suffix(4))"
    }

    // MARK: - 部署记录

    func save(record newRecord: DeploymentRecord) {
        record = newRecord
        rememberedAccountId = newRecord.accountId
        rememberedKvNamespaceId = newRecord.kvNamespaceId
        defaults.set(newRecord.accountId, forKey: Keys.accountId)
        defaults.set(newRecord.kvNamespaceId, forKey: Keys.kvNamespaceId)
        if proberHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            proberHost = newRecord.nodeHost
            defaults.set(proberHost, forKey: Keys.proberHost)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(newRecord),
           let json = String(data: data, encoding: .utf8) {
            KeychainStore.save(json, for: SecretKey.deployment)
        }
        KeychainStore.save(newRecord.panelPassword, for: SecretKey.panelPassword)
    }

    func forgetDeployment() {
        record = nil
        KeychainStore.delete(SecretKey.deployment)
        KeychainStore.delete(SecretKey.panelPassword)
    }

    func updateProberHost(_ value: String) {
        proberHost = value
        defaults.set(value, forKey: Keys.proberHost)
    }

    func updateProberOptions(builtin: Bool, candidates: Int) {
        proberUsesBuiltinRanges = builtin
        proberCandidates = candidates
        defaults.set(builtin, forKey: Keys.proberBuiltin)
        defaults.set(candidates, forKey: Keys.proberCandidates)
    }

    /// 优选器默认探测域名
    var effectiveProberHost: String {
        let typed = proberHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return typed }
        return record?.nodeHost ?? ""
    }

    private static func loadRecord() -> DeploymentRecord? {
        guard let json = KeychainStore.read(SecretKey.deployment),
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DeploymentRecord.self, from: data)
    }
}
