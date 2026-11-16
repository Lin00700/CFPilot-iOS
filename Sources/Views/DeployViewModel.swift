import Foundation
import Combine

/// 部署向导的状态机
final class DeployViewModel: ObservableObject {
    @Published var token: String = ""
    @Published var accountId: String = ""
    @Published var mode: DataPlaneMode = .pages
    @Published var dataHost: String = ""
    @Published var enableTrojan: Bool = true
    @Published var enableXhttp: Bool = true
    @Published var keepCredentials: Bool = true
    @Published var freshDeploy: Bool = false
    @Published var controlProject: String = ""
    @Published var dataProject: String = ""

    @Published var accounts: [CFAccount] = []
    @Published var isFetchingAccounts: Bool = false
    @Published var accountError: String?

    @Published var logs: [DeployLogEntry] = []
    @Published var isRunning: Bool = false
    @Published var finishedRecord: DeploymentRecord?
    @Published var failureText: String?
    @Published var prepared: Bool = false

    /// 从本机记录预填（只在第一次进入时做）
    func prepare(store: SettingsStore) {
        guard !prepared else { return }
        prepared = true
        if token.isEmpty { token = store.token }
        if accountId.isEmpty { accountId = store.rememberedAccountId }
        if let record = store.record {
            mode = record.mode
            dataHost = record.mode == .workers ? record.dataHost : ""
            enableTrojan = true
            enableXhttp = true
            controlProject = record.controlProject
            dataProject = record.dataProject
        }
    }

    /// 读取 Token 可见的账号，方便多账号用户选对目标
    func fetchAccounts() {
        let effectiveToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveToken.isEmpty, !isFetchingAccounts else { return }
        isFetchingAccounts = true
        accountError = nil
        Task { [weak self] in
            do {
                let list = try await CloudflareAPI(token: effectiveToken).listAccounts()
                await MainActor.run {
                    guard let self else { return }
                    self.accounts = list
                    self.isFetchingAccounts = false
                    if self.accountId.isEmpty, let first = list.first {
                        self.accountId = first.id
                    }
                    if list.isEmpty {
                        self.accountError = "这个 Token 看不到任何账号。"
                    }
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.isFetchingAccounts = false
                    self.accountError = error.localizedDescription
                }
            }
        }
    }

    var canStart: Bool {
        !isRunning && !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func start(store: SettingsStore) {
        guard !isRunning else { return }
        let effectiveToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !effectiveToken.isEmpty else {
            failureText = "请先填写 Cloudflare API Token。"
            return
        }

        logs.removeAll()
        failureText = nil
        finishedRecord = nil
        isRunning = true

        if effectiveToken != store.token {
            store.saveToken(effectiveToken)
        }

        let reusedKv = freshDeploy ? "" : (store.record?.kvNamespaceId ?? store.rememberedKvNamespaceId)
        let request = DeployRequest(
            token: effectiveToken,
            accountId: accountId.trimmingCharacters(in: .whitespacesAndNewlines),
            dataPlaneMode: mode,
            dataHost: dataHost.trimmingCharacters(in: .whitespacesAndNewlines),
            enableTrojan: enableTrojan,
            enableXhttp: enableXhttp,
            keepCredentials: keepCredentials,
            controlProject: controlProject.trimmingCharacters(in: .whitespacesAndNewlines),
            dataProject: dataProject.trimmingCharacters(in: .whitespacesAndNewlines),
            kvNamespaceId: reusedKv,
            knownManifest: nil
        )

        let service = DeployService(token: effectiveToken) { [weak self] entry in
            guard let self else { return }
            self.logs.append(entry)
        }

        Task { [weak self] in
            do {
                let record = try await service.run(request)
                await MainActor.run {
                    guard let self else { return }
                    self.finishedRecord = record
                    self.isRunning = false
                    store.save(record: record)
                }
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    guard let self else { return }
                    self.failureText = message
                    self.isRunning = false
                    self.logs.append(DeployLogEntry(level: .failure, title: "部署中止", detail: message))
                }
            }
        }
    }
}
