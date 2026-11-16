import Foundation

/// 把优选结果同步进已部署实例的面板。
///
/// 与内核面板的「扫描回填」语义一致：
///   - L1 `LOCAL_PREFERRED_IPS` ← 本次真连接优选的结果（订阅的主要来源）
///   - L2 `CONFIG.add`          ← 面板「手动优选 IP」输入框，回填时清空，
///     否则订阅里会同时出现新旧两批 IP，用户会以为回填没生效。
enum PanelSync {
    enum SyncError: LocalizedError {
        case noConfig
        case empty

        var errorDescription: String? {
            switch self {
            case .noConfig: return "读不到该实例的 KV 配置（CONFIG），请确认 Token 仍有 KV 读权限。"
            case .empty: return "没有可写入的条目。"
            }
        }
    }

    static func pushPreferredIPs(
        lines: [String],
        record: DeploymentRecord,
        token: String
    ) async throws -> Int {
        let cleaned = lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { throw SyncError.empty }

        let api = CloudflareAPI(token: token)
        let value = cleaned.joined(separator: "\n")
        try await api.setKVValue(
            accountId: record.accountId,
            namespaceId: record.kvNamespaceId,
            key: CloudflareAPI.localIpsKey,
            value: value
        )

        // 清空旧的手动优选 IP，避免与新结果重复叠加
        if let raw = try await api.getKVValue(
            accountId: record.accountId,
            namespaceId: record.kvNamespaceId,
            key: CloudflareAPI.configKey
        ), !raw.isEmpty, let data = raw.data(using: .utf8) {
            let object = try? JSONSerialization.jsonObject(with: data, options: [])
            if var config = object as? [String: Any] {
                config["add"] = ""
                if let encoded = try? JSONSerialization.data(withJSONObject: config, options: []),
                   let text = String(data: encoded, encoding: .utf8) {
                    try await api.setKVValue(
                        accountId: record.accountId,
                        namespaceId: record.kvNamespaceId,
                        key: CloudflareAPI.configKey,
                        value: text
                    )
                }
            }
        }

        return cleaned.count
    }

    /// 读取面板当前保存的本地优选池（用于展示，不参与探测）
    static func fetchPreferredIPs(record: DeploymentRecord, token: String) async -> String {
        let api = CloudflareAPI(token: token)
        let raw = try? await api.getKVValue(
            accountId: record.accountId,
            namespaceId: record.kvNamespaceId,
            key: CloudflareAPI.localIpsKey
        )
        return raw ?? ""
    }
}
