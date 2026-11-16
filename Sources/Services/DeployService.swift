import Foundation

/// 部署流程错误
enum DeployError: LocalizedError {
    case noAccount
    case invalidProjectName(String)
    case kvOwnership(String)
    case kvUnreadable(String)
    case platformBlocked(String)
    case deploymentFailed(String)
    case missingSubdomain(String)
    case emptyKernel(String)

    var errorDescription: String? {
        switch self {
        case .noAccount:
            return "这个 API Token 看不到任何 Cloudflare 账号。请确认 Token 属于正确的账号，并带有 Account / Account Settings / Read 权限。"
        case .invalidProjectName(let name):
            return "项目名 \(name) 不合法：只允许小写字母、数字与连字符，且以字母或数字开头。"
        case .kvOwnership(let detail):
            return detail
        case .kvUnreadable(let detail):
            return "无法确认 KV 归属：\(detail)\n读不到 ≠ 不存在。请检查 Token 的 KV 读取权限与网络后重试。"
        case .platformBlocked(let detail):
            return "Cloudflare 拒绝了这次部署：\(detail)\n官方 CLI 的原则是一次失败就停 —— 连续重试会累积账号的风控画像，可能导致账号被封。请等一段时间后手动重试。"
        case .deploymentFailed(let detail):
            return "部署未确认成功：\(detail)"
        case .missingSubdomain(let label):
            return "\(label)没有返回访问域名（subdomain），无法继续。请到 Cloudflare 控制台确认该项目的状态。"
        case .emptyKernel(let label):
            return "\(label)产物为空，已停止部署。"
        }
    }
}

/// 一键双面部署：控制面 Pages + 数据面（Pages 或 Workers），共用同一个 KV。
///
/// 流程与官方 CLI `deploy --pages-split` 对齐，硬性顺序不能改：
///   1. 校验 Token / 账号
///   2. 准备独立 KV（存在既有清单则沿用 → 更新模式）
///   3. KV 归属校验（写入任何键之前）
///   4. 建项目 → 配环境变量与 KV 绑定（必须在部署前，Pages 只对之后的部署生效）
///   5. 把凭据写进 KV 的 CONFIG 键
///   6. 先部署数据面，再同步控制面的 DATA_HOST，最后部署控制面
///   7. 写回部署清单，返回面板地址与密码
final class DeployService {
    private let api: CloudflareAPI
    private let progress: (DeployLogEntry) -> Void

    init(token: String, progress: @escaping (DeployLogEntry) -> Void) {
        self.api = CloudflareAPI(token: token)
        self.progress = progress
    }

    // MARK: - 日志

    private func emit(_ level: DeployLogEntry.Level, _ title: String, _ detail: String = "") async {
        let entry = DeployLogEntry(level: level, title: title, detail: detail)
        let callback = progress
        await MainActor.run {
            callback(entry)
        }
    }

    // MARK: - 主流程

    func run(_ request: DeployRequest) async throws -> DeploymentRecord {
        let token = request.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw DeployError.kvOwnership("请先填写 Cloudflare API Token。") }

        await emit(.info, "读取内核", "从 xmwengxing/CFPilot 拉取控制面与数据面产物（直连失败会自动走镜像）…")
        let kernel = try await KernelSource.load()
        await emit(
            .success,
            "内核就绪",
            "\(kernel.source) · 构建 \(kernel.build.isEmpty ? "未识别" : kernel.build) · 内核序号 \(kernel.version)"
        )
        guard !kernel.control.isEmpty else { throw DeployError.emptyKernel("控制面") }
        guard !kernel.data.isEmpty else { throw DeployError.emptyKernel("数据面") }

        // 1. 账号
        let accounts = try await api.listAccounts()
        guard !accounts.isEmpty else { throw DeployError.noAccount }
        let account: CFAccount
        if request.accountId.isEmpty {
            account = accounts[0]
        } else {
            account = accounts.first(where: { $0.id == request.accountId }) ?? accounts[0]
        }
        await emit(.success, "账号已确认", "\(account.name) · \(account.id)")

        if let status = await api.verifyToken() {
            await emit(.info, "Token 状态", status)
        } else {
            await emit(.info, "Token 状态", "读不到元信息（account-owned Token 常见），不影响部署")
        }

        // 2. KV：沿用既有实例，或新建一个独立的命名空间
        var manifest: DeployManifest? = request.knownManifest
        var namespaceId = request.kvNamespaceId.trimmingCharacters(in: .whitespacesAndNewlines)
        var updateMode = false

        if !namespaceId.isEmpty {
            let namespaces = try await api.listKVNamespaces(accountId: account.id)
            if !namespaces.contains(where: { $0.id == namespaceId }) {
                await emit(.warning, "既有 KV 不存在", "跳转到新建 KV 的流程")
                namespaceId = ""
                manifest = nil
            }
        }

        if !namespaceId.isEmpty {
            do {
                let existing = try await readManifest(accountId: account.id, namespaceId: namespaceId)
                if let existing {
                    manifest = existing
                    updateMode = true
                    await emit(
                        .info,
                        "检测到已有部署",
                        "控制面 \(existing.controlProject) / 数据面 \(existing.dataProject) · \(existing.at)"
                    )
                    await emit(
                        .warning,
                        "更新部署注意",
                        "Cloudflare 对含代理内容的 Pages 数据面二次部署可能返回 8000119（项目被风控标记）。若这次被拒绝，App 会立即停止、不重试 —— 等一段时间再试，或勾选「全新部署（新建 KV）」换一套项目名。"
                    )
                } else {
                    await emit(.info, "KV 已指定", "该命名空间没有部署清单，按首次部署处理")
                }
            } catch {
                throw DeployError.kvUnreadable(error.localizedDescription)
            }
        } else {
            namespaceId = try await createCleanNamespace(accountId: account.id)
        }

        // 3. 项目名与凭据
        var controlName = updateMode ? (manifest?.controlProject ?? "") : request.controlProject
        var dataName = updateMode ? (manifest?.dataProject ?? "") : request.dataProject
        controlName = controlName.trimmingCharacters(in: .whitespacesAndNewlines)
        dataName = dataName.trimmingCharacters(in: .whitespacesAndNewlines)

        if controlName.isEmpty {
            controlName = Randomizer.projectName()
        }
        if dataName.isEmpty {
            dataName = Randomizer.projectName()
        }
        try validateProjectName(controlName)
        try validateProjectName(dataName)
        await emit(.info, "项目名", "控制面 \(controlName) · 数据面 \(dataName)")

        // 4. 归属校验（写入任何键之前）
        let ownership = try await inspectOwnership(accountId: account.id, namespaceId: namespaceId, controlProject: controlName)
        if !ownership.blocking {
            await emit(.success, "KV 归属校验通过", ownership.detail)
        } else {
            throw DeployError.kvOwnership(ownership.detail)
        }

        // 5. 凭据：更新模式沿用旧值，首次部署生成随机值
        let credentials: DeployCredentials
        if updateMode, let existing = manifest, request.keepCredentials {
            credentials = existing.credentials
            await emit(.info, "沿用旧凭据", "UUID / WS 路径 / 面板密码不变，客户端订阅地址无需修改")
        } else {
            credentials = DeployCredentials.random()
            await emit(.info, "生成新凭据", "面板路径 \(credentials.panelPath)")
        }

        let mode = request.dataPlaneMode
        if updateMode, let previousMode = manifest?.dataPlaneMode, previousMode != mode.rawValue {
            await emit(.warning, "数据面形态变更", "\(previousMode) → \(mode.rawValue)；旧数据面不会被自动删除，请部署后到控制台清理。")
        }

        // 6. 建项目
        _ = try await ensurePagesProject(
            accountId: account.id,
            name: controlName,
            label: "控制面"
        )
        var dataPagesSubdomain = ""
        if mode == .pages {
            dataPagesSubdomain = try await ensurePagesProject(
                accountId: account.id,
                name: dataName,
                label: "数据面"
            )
        }

        // 7. 数据面节点域名（Workers 形态需要先定下来，控制面的 DATA_HOST 要用）
        var nodeHost = ""
        if mode == .pages {
            nodeHost = dataPagesSubdomain
        } else {
            let typed = request.dataHost.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typed.isEmpty {
                nodeHost = typed
            } else {
                let sub = (try? await api.workersSubdomain(accountId: account.id)) ?? ""
                nodeHost = sub.isEmpty ? "\(dataName).workers.dev" : "\(dataName).\(sub).workers.dev"
            }
        }

        // 8. 配置环境变量与 KV 绑定（必须在部署之前）
        try await api.updatePagesDeploymentConfig(
            accountId: account.id,
            name: controlName,
            kvNamespaceId: namespaceId,
            envVars: [
                "PANEL_PATH": credentials.panelPath,
                "PANEL_PASSWORD": credentials.panelPassword,
                "DATA_HOST": nodeHost,
            ]
        )
        await emit(.success, "控制面已配置", "PANEL_PATH / PANEL_PASSWORD / DATA_HOST = \(nodeHost)")

        if mode == .pages {
            try await api.updatePagesDeploymentConfig(
                accountId: account.id,
                name: dataName,
                kvNamespaceId: namespaceId,
                envVars: [
                    "UUID": credentials.uuid,
                    "TROJAN_PASSWORD": credentials.trojanPassword,
                    "WS_PATH": credentials.wsPath,
                    "PATH": credentials.wsPath,
                    "ENABLE_TROJAN": request.enableTrojan ? "true" : "false",
                    "ENABLE_XHTTP": request.enableXhttp ? "true" : "false",
                    "RESOLVE_PREFERRED": "true",
                ]
            )
            await emit(.success, "数据面已配置", "UUID / WS 路径 / Trojan 密码 / 协议开关已注入")
        }

        // 9. 凭据写进 KV 的 CONFIG（内核的优先级是 KV > 环境变量 > 默认值）
        let wroteConfig = await writeEffectiveConfig(
            accountId: account.id,
            namespaceId: namespaceId,
            credentials: credentials,
            enableTrojan: request.enableTrojan,
            enableXhttp: request.enableXhttp
        )
        if wroteConfig {
            await emit(.success, "凭据已写入 KV", "CONFIG 键已更新（uuid / wsPath / trojanPassword）")
        } else {
            await emit(.warning, "跳过写入 KV 配置", "读取既有 CONFIG 失败，为避免覆盖你在面板里改过的设置，本次不写；内核会回退到环境变量。")
        }

        // 10. 部署数据面（先数据面，控制面的 DATA_HOST 才有意义）
        var finalDataSubdomain = ""
        if mode == .pages {
            try await deployPages(accountId: account.id, name: dataName, code: kernel.data, label: "数据面")
            finalDataSubdomain = try await subdomainOf(accountId: account.id, name: dataName, label: "数据面")
            if finalDataSubdomain != nodeHost {
                nodeHost = finalDataSubdomain
            }
        } else {
            finalDataSubdomain = try await deployWorkerDataPlane(
                accountId: account.id,
                name: dataName,
                code: kernel.data,
                namespaceId: namespaceId,
                credentials: credentials,
                enableTrojan: request.enableTrojan,
                enableXhttp: request.enableXhttp,
                customHost: request.dataHost.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            nodeHost = finalDataSubdomain
        }

        // 11. 数据面域名可能因换名而变化：控制面的 DATA_HOST 必须指向真实域名，
        //     否则订阅里的节点全部指向不存在的地址。环境变量随时可改，无需重新部署。
        try await api.updatePagesDeploymentConfig(
            accountId: account.id,
            name: controlName,
            kvNamespaceId: namespaceId,
            envVars: [
                "PANEL_PATH": credentials.panelPath,
                "PANEL_PASSWORD": credentials.panelPassword,
                "DATA_HOST": nodeHost,
            ]
        )
        await emit(.success, "控制面 DATA_HOST 已同步", nodeHost)

        // 12. 部署控制面
        try await deployPages(accountId: account.id, name: controlName, code: kernel.control, label: "控制面")
        let finalControlSubdomain = try await subdomainOf(accountId: account.id, name: controlName, label: "控制面")

        // 13. 写回部署清单
        let manifestDate = ISO8601DateFormatter().string(from: Date())
        let newManifest = DeployManifest(
            v: 1,
            kvNamespaceId: namespaceId,
            controlProject: controlName,
            dataProject: dataName,
            controlSubdomain: finalControlSubdomain,
            dataSubdomain: finalDataSubdomain,
            dataCustomDomain: mode == .workers ? request.dataHost.trimmingCharacters(in: .whitespacesAndNewlines) : (manifest?.dataCustomDomain ?? ""),
            dataPlaneMode: mode.rawValue,
            build: kernel.build,
            kernelVersion: kernel.version,
            at: manifestDate,
            credentials: credentials
        )
        if let data = try? JSONEncoder().encode(newManifest),
           let json = String(data: data, encoding: .utf8) {
            do {
                try await api.setKVValue(
                    accountId: account.id,
                    namespaceId: namespaceId,
                    key: CloudflareAPI.manifestKey,
                    value: json
                )
                await emit(.success, "部署清单已记录", "下次更新会自动识别同源项目")
            } catch {
                await emit(.warning, "部署清单写入失败", "不影响本次部署，只影响下次更新的识别：\(error.localizedDescription)")
            }
        }

        // 14. 面板连通性确认（拿到任意 HTTP 响应即视为上线）
        let panelURL = "https://\(finalControlSubdomain)\(credentials.panelPath)"
        let status = await api.probeURL(panelURL)
        if status > 0 {
            await emit(.success, "面板已响应", "\(panelURL) · HTTP \(status)")
        } else {
            await emit(.warning, "面板暂未响应", "新部署的 *.pages.dev 域名通常需要几十秒生效，可稍后在「面板」页重新载入。")
        }

        if mode == .workers, !request.dataHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await emit(
                .warning,
                "数据面域名需要你手动绑定",
                "到 Cloudflare 控制台 → Workers 和 Pages → \(dataName) → 「域」标签页添加 \(request.dataHost)。没绑定之前该域名的流量到不了 Worker。"
            )
        }

        return DeploymentRecord(
            accountId: account.id,
            accountName: account.name,
            kvNamespaceId: namespaceId,
            controlProject: controlName,
            dataProject: dataName,
            controlSubdomain: finalControlSubdomain,
            dataSubdomain: finalDataSubdomain,
            panelPath: credentials.panelPath,
            panelPassword: credentials.panelPassword,
            uuid: credentials.uuid,
            trojanPassword: credentials.trojanPassword,
            wsPath: credentials.wsPath,
            dataPlaneMode: mode.rawValue,
            dataHost: nodeHost,
            build: kernel.build,
            deployedAt: Date()
        )
    }

    // MARK: - KV

    private func readManifest(accountId: String, namespaceId: String) async throws -> DeployManifest? {
        let raw = try await api.getKVValue(
            accountId: accountId,
            namespaceId: namespaceId,
            key: CloudflareAPI.manifestKey
        )
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return nil }
        guard let manifest = try? JSONDecoder().decode(DeployManifest.self, from: data) else {
            // 清单存在却读不懂 = 无法确认归属 → 不可放行（不能当成「没有清单」）
            throw DeployError.kvUnreadable("部署清单 \(CloudflareAPI.manifestKey) 不是合法 JSON")
        }
        guard manifest.v == 1 else {
            throw DeployError.kvUnreadable("部署清单版本未知（v = \(manifest.v)），本 App 只认识 v1")
        }
        return manifest
    }

    struct Ownership {
        var blocking: Bool
        var detail: String
    }

    /// 「读不到 = 无法确认 = 不可放行」：任何读取失败都按阻断处理。
    private func inspectOwnership(accountId: String, namespaceId: String, controlProject: String) async throws -> Ownership {
        let manifest: DeployManifest?
        do {
            manifest = try await readManifest(accountId: accountId, namespaceId: namespaceId)
        } catch {
            throw DeployError.kvUnreadable(error.localizedDescription)
        }

        if let manifest {
            if manifest.controlProject == controlProject {
                return Ownership(
                    blocking: false,
                    detail: "已由 CFPilot 部署（控制面 \(manifest.controlProject) / 数据面 \(manifest.dataProject)），本次按原地更新处理"
                )
            }
            return Ownership(
                blocking: true,
                detail: "该 KV 已被另一个 CFPilot 实例占用（控制面 \(manifest.controlProject) / 数据面 \(manifest.dataProject)，部署于 \(manifest.at)）。\n一个 KV 只能承载一个实例 —— 请为本次部署新建独立 KV（App 里清空「沿用 KV」即可）。"
            )
        }

        let legacy: String?
        do {
            legacy = try await api.getKVValue(accountId: accountId, namespaceId: namespaceId, key: "config")
        } catch {
            throw DeployError.kvUnreadable(error.localizedDescription)
        }
        if legacy != nil {
            return Ownership(
                blocking: true,
                detail: "该 KV 含其他项目的 config 键，正被别的项目使用。CFPilot 的数据面是纯自研的，不与任何第三方共用命名空间 —— 请换一个干净的 KV。"
            )
        }

        let existing: String?
        do {
            existing = try await api.getKVValue(accountId: accountId, namespaceId: namespaceId, key: CloudflareAPI.configKey)
        } catch {
            throw DeployError.kvUnreadable(error.localizedDescription)
        }
        if existing != nil {
            return Ownership(
                blocking: true,
                detail: "该 KV 含 CFPilot 的 CONFIG 键但没有部署清单（残留配置，可能清单被删或手工写入）。继续部署会覆盖其中的既有配置 —— 如果你确认要覆盖，请到控制台删除该键或换一个 KV。"
            )
        }
        return Ownership(blocking: false, detail: "空命名空间，可以独占使用")
    }

    /// 新建一个空 KV；连续拿到「不干净」的命名空间时换名重建（最多 3 次）。
    private func createCleanNamespace(accountId: String) async throws -> String {
        for attempt in 1...3 {
            let title = "cfp-" + Randomizer.alnum(6)
            let namespace = try await api.createKVNamespace(accountId: accountId, title: title)
            guard !namespace.id.isEmpty else {
                throw DeployError.kvOwnership("创建 KV 命名空间失败：接口没有返回 id。")
            }
            await emit(.info, "已创建 KV 命名空间", "\(namespace.title) · \(namespace.id)")
            let ownership = try await inspectOwnership(
                accountId: accountId,
                namespaceId: namespace.id,
                controlProject: "pending-" + Randomizer.alnum(6)
            )
            if !ownership.blocking {
                return namespace.id
            }
            await emit(.warning, "命名空间不干净，换一个", ownership.detail)
            if attempt == 3 {
                throw DeployError.kvOwnership(ownership.detail)
            }
        }
        throw DeployError.kvOwnership("无法创建干净的 KV 命名空间，请稍后重试。")
    }

    /// 把凭据写进 KV 的 CONFIG（先读旧值，保留用户手动配置的字段）
    private func writeEffectiveConfig(
        accountId: String,
        namespaceId: String,
        credentials: DeployCredentials,
        enableTrojan: Bool,
        enableXhttp: Bool
    ) async -> Bool {
        var existing: [String: Any] = [:]
        do {
            if let raw = try await api.getKVValue(
                accountId: accountId,
                namespaceId: namespaceId,
                key: CloudflareAPI.configKey
            ), !raw.isEmpty, let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: []),
               let dict = object as? [String: Any] {
                existing = dict
            }
        } catch {
            return false
        }

        existing["uuid"] = credentials.uuid
        existing["trojanPassword"] = credentials.trojanPassword
        existing["wsPath"] = credentials.wsPath
        existing["enableTrojan"] = enableTrojan
        existing["enableXhttp"] = enableXhttp

        guard let data = try? JSONSerialization.data(withJSONObject: existing, options: []),
              let text = String(data: data, encoding: .utf8) else { return false }
        do {
            try await api.setKVValue(
                accountId: accountId,
                namespaceId: namespaceId,
                key: CloudflareAPI.configKey,
                value: text
            )
            return true
        } catch {
            await emit(.warning, "KV 凭据写入失败", error.localizedDescription)
            return false
        }
    }

    // MARK: - 项目

    private func validateProjectName(_ name: String) throws {
        let pattern = "^[a-z0-9][a-z0-9-]{0,57}$"
        let ok = name.range(of: pattern, options: .regularExpression) != nil
        if !ok { throw DeployError.invalidProjectName(name) }
    }

    /// 建项目；已存在则复用（原地更新）
    private func ensurePagesProject(accountId: String, name: String, label: String) async throws -> String {
        do {
            let project = try await api.createPagesProject(accountId: accountId, name: name)
            let subdomain = JSONHelper.string(project["subdomain"])
            await emit(.success, "已创建\(label)项目", "\(name) · \(subdomain)")
            guard !subdomain.isEmpty else { throw DeployError.missingSubdomain(label) }
            return subdomain
        } catch let error as CFAPIError {
            if error.message.localizedCaseInsensitiveContains("already exists") {
                let project = try await api.getPagesProject(accountId: accountId, name: name)
                let subdomain = JSONHelper.string(project["subdomain"])
                await emit(.info, "\(label)项目已存在，复用它", "\(name) · \(subdomain)")
                guard !subdomain.isEmpty else { throw DeployError.missingSubdomain(label) }
                return subdomain
            }
            throw error
        }
    }

    private func subdomainOf(accountId: String, name: String, label: String) async throws -> String {
        do {
            let project = try await api.getPagesProject(accountId: accountId, name: name)
            let subdomain = JSONHelper.string(project["subdomain"])
            guard !subdomain.isEmpty else { throw DeployError.missingSubdomain(label) }
            return subdomain
        } catch let error as CFAPIError {
            throw DeployError.missingSubdomain("\(label)：\(error.localizedDescription)")
        }
    }

    // MARK: - 部署
    private func deployPages(accountId: String, name: String, code: String, label: String) async throws {
        guard !code.isEmpty else { throw DeployError.emptyKernel(label) }
        await emit(.info, "\(label)部署中", "上传 _worker.js → \(name)")
        do {
            let deployment = try await api.deployPagesWorker(accountId: accountId, name: name, code: code)
            let deploymentId = JSONHelper.string(deployment["id"])
            await emit(.info, "\(label)已触发部署", deploymentId.isEmpty ? name : "\(name) · \(deploymentId)")
        } catch let error as CFAPIError {
            if error.isBlocked {
                throw DeployError.platformBlocked(error.localizedDescription)
            }
            throw DeployError.deploymentFailed("\(label)：\(error.localizedDescription)")
        }

        let status = try await waitForPagesDeployment(accountId: accountId, name: name, label: label)
        await emit(.success, "\(label)部署完成", "\(name) · \(status)")
    }

    private func waitForPagesDeployment(
        accountId: String,
        name: String,
        label: String,
        timeout: TimeInterval = 210
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        var lastStatus = "未开始"
        while Date() < deadline {
            do {
                let list = try await api.listPagesDeployments(accountId: accountId, name: name)
                if let latest = list.first {
                    let stage = JSONHelper.dictionary(latest["latest_stage"])
                    let status = JSONHelper.string(stage["status"])
                    if !status.isEmpty { lastStatus = status }
                    if status == "success" { return status }
                    if status == "failure" || status == "canceled" {
                        throw DeployError.deploymentFailed("\(label)状态 \(status)")
                    }
                }
            } catch let error as DeployError {
                throw error
            } catch {
                await emit(.warning, "查询部署状态失败", error.localizedDescription)
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw DeployError.deploymentFailed("\(label)轮询超时（最后状态：\(lastStatus)）。可到 Cloudflare 控制台查看该项目这次的部署记录。")
    }

    /// Workers 数据面：上传脚本 → 按是否有自定义域名决定 workers.dev 链接开关
    private func deployWorkerDataPlane(
        accountId: String,
        name: String,
        code: String,
        namespaceId: String,
        credentials: DeployCredentials,
        enableTrojan: Bool,
        enableXhttp: Bool,
        customHost: String
    ) async throws -> String {
        guard !code.isEmpty else { throw DeployError.emptyKernel("数据面") }

        let bindings: [[String: Any]] = [
            ["type": "kv_namespace", "name": "KV", "namespace_id": namespaceId],
            ["type": "plain_text", "name": "UUID", "text": credentials.uuid],
            ["type": "plain_text", "name": "TROJAN_PASSWORD", "text": credentials.trojanPassword],
            ["type": "plain_text", "name": "WS_PATH", "text": credentials.wsPath],
            ["type": "plain_text", "name": "PATH", "text": credentials.wsPath],
            ["type": "plain_text", "name": "ENABLE_TROJAN", "text": enableTrojan ? "true" : "false"],
            ["type": "plain_text", "name": "ENABLE_XHTTP", "text": enableXhttp ? "true" : "false"],
            ["type": "plain_text", "name": "RESOLVE_PREFERRED", "text": "true"],
        ]

        await emit(.info, "数据面部署中", "上传 Workers 脚本 → \(name)")
        do {
            try await api.uploadWorkerScript(accountId: accountId, name: name, code: code, bindings: bindings)
            await emit(.success, "数据面脚本已上传", name)
        } catch let error as CFAPIError {
            if error.isBlocked { throw DeployError.platformBlocked(error.localizedDescription) }
            throw DeployError.deploymentFailed("数据面：\(error.localizedDescription)")
        }

        // 有自定义域名时把 workers.dev 的生产与预览链接都关掉，
        // 否则订阅节点会全部连不上（官方 CLI 的真机事故 2026-11-02）。
        let hasCustomHost = !customHost.isEmpty
        do {
            try await api.putScriptSubdomain(
                accountId: accountId,
                name: name,
                enabled: !hasCustomHost,
                previewsEnabled: false
            )
            let subdomainTitle = hasCustomHost ? "已关闭 workers.dev 链接" : "已开启 workers.dev 链接"
            let subdomainDetail = hasCustomHost
                ? "节点走自定义域名 " + customHost
                : "节点走 workers.dev"
            await emit(.success, subdomainTitle, subdomainDetail)
        } catch {
            let failureDetail = error.localizedDescription
            let hint = "请到控制台 → Workers → " + name
                + " → 设置 → 域和路由 手动处理，否则节点可能全部连不上。"
                + failureDetail
            await emit(.warning, "workers.dev 链接开关设置失败", hint)
        }

        if hasCustomHost { return customHost }

        let sub = (try? await api.workersSubdomain(accountId: accountId)) ?? ""
        if sub.isEmpty { return name + ".workers.dev" }
        return name + "." + sub + ".workers.dev"
    }
}
