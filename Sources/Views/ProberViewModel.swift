import Foundation
import Combine

/// 优选页的状态机
final class ProberViewModel: ObservableObject {
    @Published var host: String = ""
    @Published var port: String = "443"
    @Published var useBuiltinRanges: Bool = true
    @Published var candidateCount: Int = 80
    @Published var customText: String = ""

    @Published var results: [ProbeResult] = []
    @Published var isRunning: Bool = false
    @Published var progressText: String = ""
    @Published var lastError: String?
    @Published var syncMessage: String?
    @Published var isSyncing: Bool = false
    @Published var onlyReachable: Bool = true
    @Published var prepared: Bool = false

    func prepare(store: SettingsStore) {
        guard !prepared else { return }
        prepared = true
        if host.isEmpty { host = store.effectiveProberHost }
        useBuiltinRanges = store.proberUsesBuiltinRanges
        candidateCount = store.proberCandidates
        if customText.isEmpty {
            customText = IPRanges.builtinV4.joined(separator: "\n")
        }
    }

    var visibleResults: [ProbeResult] {
        onlyReachable ? results.filter { $0.ok } : results
    }

    var reachableCount: Int {
        results.filter { $0.ok }.count
    }

    var canStart: Bool {
        !isRunning && !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start(store: SettingsStore) {
        guard !isRunning else { return }
        let sni = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sni.isEmpty else {
            lastError = "请先填写要探测的域名（TLS SNI 用它做握手校验，只有真正能服务这个域名的 IP 会被保留）。"
            return
        }
        let portValue = UInt16(port.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 443
        guard portValue > 0 else {
            lastError = "端口不合法。"
            return
        }

        lastError = nil
        syncMessage = nil
        results = []
        isRunning = true
        store.updateProberOptions(builtin: useBuiltinRanges, candidates: candidateCount)

        let sources: [String]
        if useBuiltinRanges {
            sources = IPRanges.builtinV4
        } else {
            sources = IPRanges.parseLines(customText)
        }
        guard !sources.isEmpty else {
            lastError = "候选来源为空：请打开内置网段，或在自定义列表里填 IP / CIDR。"
            isRunning = false
            return
        }

        let candidates = IPRanges.sample(from: sources, count: candidateCount)
        guard !candidates.isEmpty else {
            lastError = "没能生成候选 IP，请检查网段格式。"
            isRunning = false
            return
        }

        progressText = "0 / \(candidates.count)"
        let options = TrueProber.Options(
            host: sni,
            port: portValue,
            path: "/",
            timeout: 6,
            concurrency: 10
        )

        Task { [weak self] in
            let probed = await TrueProber.probe(ips: candidates, options: options) { done, total in
                self?.progressText = "\(done) / \(total)"
            }
            await MainActor.run {
                guard let self else { return }
                self.results = probed
                self.isRunning = false
                if probed.filter({ $0.ok }).isEmpty {
                    self.lastError = "全部候选都没有完成 TLS 握手。常见原因：域名填错、域名还没绑定到数据面，或当前网络到 Cloudflare 的边缘全被拦。"
                }
            }
        }
    }

    /// 把优选结果写进面板的本地优选池（KV 的 LOCAL_PREFERRED_IPS）
    func pushToPanel(store: SettingsStore) {
        guard !isSyncing else { return }
        guard let record = store.record else {
            syncMessage = "还没有部署记录：先完成一次部署，优选结果才有地方写。"
            return
        }
        guard !store.token.isEmpty else {
            syncMessage = "钥匙串里没有 API Token，请到「设置」重新保存。"
            return
        }
        let lines = visibleResults.filter { $0.ok }.map { $0.poolLine }
        guard !lines.isEmpty else {
            syncMessage = "没有可用结果可写。"
            return
        }

        isSyncing = true
        syncMessage = nil
        Task { [weak self] in
            do {
                let count = try await PanelSync.pushPreferredIPs(
                    lines: lines,
                    record: record,
                    token: store.token
                )
                await MainActor.run {
                    guard let self else { return }
                    self.isSyncing = false
                    self.syncMessage = "已写入 \(count) 条到面板优选池（KV: LOCAL_PREFERRED_IPS），并清空了旧的手动优选 IP。到面板刷新即可看到。"
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isSyncing = false
                    self.syncMessage = "写入失败：\(error.localizedDescription)"
                }
            }
        }
    }
}
