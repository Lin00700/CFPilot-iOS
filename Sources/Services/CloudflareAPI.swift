import Foundation

/// Cloudflare API 错误（HTTP 状态 + 平台错误码）
struct CFAPIError: LocalizedError {
    let status: Int
    let code: Int?
    let message: String

    var errorDescription: String? {
        var parts: [String] = []
        if status > 0 { parts.append("HTTP \(status)") }
        if let code { parts.append("code \(code)") }
        parts.append(message)
        return parts.joined(separator: " · ")
    }

    /// 平台风控拒绝（Pages 二次部署的 8000119）
    var isBlocked: Bool {
        code == 8000119 || message.localizedCaseInsensitiveContains("has been blocked")
    }

    var isNotFound: Bool {
        status == 404 || code == 10007
    }
}

/// JSON 取值助手：Cloudflare 的响应结构随接口而异，用 Any 解析比层层 Codable 更稳。
enum JSONHelper {
    static func dictionary(_ value: Any?) -> [String: Any] {
        (value as? [String: Any]) ?? [:]
    }

    static func array(_ value: Any?) -> [Any] {
        (value as? [Any]) ?? []
    }

    static func dictionaryArray(_ value: Any?) -> [[String: Any]] {
        array(value).compactMap { $0 as? [String: Any] }
    }

    static func string(_ value: Any?) -> String {
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return ""
    }

    static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    static func bool(_ value: Any?) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return false
    }
}

/// multipart/form-data 组装器（Pages 部署接口需要嵌套 multipart，必须手写）
struct MultipartBuilder {
    let boundary: String
    private var body = Data()

    init(boundary: String = "CFPilotBoundary" + Randomizer.alnum(16)) {
        self.boundary = boundary
    }

    mutating func addField(name: String, value: String) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        body.append("\(value)\r\n")
    }

    mutating func addFile(name: String, filename: String, mimeType: String, content: Data) {
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        body.append("Content-Type: \(mimeType)\r\n\r\n")
        body.append(content)
        body.append("\r\n")
    }

    mutating func addText(name: String, content: String) {
        addFile(name: name, filename: name, mimeType: "text/plain", content: Data(content.utf8))
    }

    func finished() -> Data {
        var out = body
        out.append("--\(boundary)--\r\n")
        return out
    }

    var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}

/// Cloudflare REST API 客户端（只用 API Token，Bearer 鉴权）
final class CloudflareAPI {
    static let apiBase = "https://api.cloudflare.com/client/v4"

    /// 部署清单键（与官方 CLI 完全一致）
    static let manifestKey = "CFP_DEPLOY_MANIFEST"
    /// 内核配置键
    static let configKey = "CONFIG"
    /// 本地优选 IP 池键
    static let localIpsKey = "LOCAL_PREFERRED_IPS"
    /// Worker 的 compatibility_date（与官方 CLI 保持一致的可复现值）
    static let workersCompatibilityDate = "2026-10-01"

    private let token: String
    private let session: URLSession

    init(token: String) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 240
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = ["User-Agent": "CFPilot-iOS/1.0"]
        session = URLSession(configuration: config)
    }

    // MARK: - 底层请求

    private func send(
        method: String,
        path: String,
        json: Any? = nil,
        body: Data? = nil,
        contentType: String? = nil
    ) async throws -> Any? {
        guard let url = URL(string: CloudflareAPI.apiBase + path) else {
            throw CFAPIError(status: 0, code: nil, message: "接口地址无效：\(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: json, options: [])
        } else if let body {
            request.httpBody = body
            if let contentType {
                request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            }
        }

        let (data, response) = try await session.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""

        guard !data.isEmpty else {
            if status >= 400 {
                throw CFAPIError(status: status, code: nil, message: "服务端未返回内容")
            }
            return nil
        }

        guard let parsed = try? JSONSerialization.jsonObject(with: data, options: []) else {
            if status >= 400 {
                throw CFAPIError(status: status, code: nil, message: text.prefix(200).description)
            }
            return nil
        }

        let envelope = JSONHelper.dictionary(parsed)
        let success = JSONHelper.bool(envelope["success"])

        if status >= 400 || (envelope["success"] != nil && !success) {
            let errors = JSONHelper.dictionaryArray(envelope["errors"])
            let first = errors.first ?? [:]
            let message = errors.isEmpty
                ? "\(text.prefix(200))"
                : JSONHelper.string(first["message"])
            let code = JSONHelper.int(first["code"])
            throw CFAPIError(status: status, code: code == 0 ? nil : code, message: message)
        }

        return envelope["result"]
    }

    // MARK: - 账号

    func verifyToken() async -> String? {
        let result = try? await send(method: "GET", path: "/user/tokens/verify")
        return JSONHelper.string(JSONHelper.dictionary(result)["status"])
    }

    func listAccounts() async throws -> [CFAccount] {
        let result = try await send(method: "GET", path: "/accounts?per_page=50")
        var accounts: [CFAccount] = []
        for item in JSONHelper.dictionaryArray(result) {
            let id = JSONHelper.string(item["id"])
            if id.isEmpty { continue }
            accounts.append(CFAccount(id: id, name: JSONHelper.string(item["name"])))
        }
        return accounts
    }

    // MARK: - KV

    func listKVNamespaces(accountId: String) async throws -> [(id: String, title: String)] {
        let result = try await send(
            method: "GET",
            path: "/accounts/\(accountId)/storage/kv/namespaces?per_page=100"
        )
        return JSONHelper.dictionaryArray(result).compactMap { item in
            let id = JSONHelper.string(item["id"])
            guard !id.isEmpty else { return nil }
            return (id, JSONHelper.string(item["title"]))
        }
    }

    func createKVNamespace(accountId: String, title: String) async throws -> (id: String, title: String) {
        let result = try await send(
            method: "POST",
            path: "/accounts/\(accountId)/storage/kv/namespaces",
            json: ["title": title]
        )
        let item = JSONHelper.dictionary(result)
        return (JSONHelper.string(item["id"]), JSONHelper.string(item["title"]))
    }

    /// 读 KV 值：只有 404（键不存在）返回 nil，其它错误一律抛出。
    /// 这一区分是「读不到 ≠ 不存在」的硬约束。
    func getKVValue(accountId: String, namespaceId: String, key: String) async throws -> String? {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(string: CloudflareAPI.apiBase
            + "/accounts/\(accountId)/storage/kv/namespaces/\(namespaceId)/values/\(encodedKey)") else {
            throw CFAPIError(status: 0, code: nil, message: "KV 地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }
        guard status < 400 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CFAPIError(status: status, code: nil, message: "读取 KV 失败：\(text.prefix(200))")
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func setKVValue(accountId: String, namespaceId: String, key: String, value: String) async throws {
        let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(string: CloudflareAPI.apiBase
            + "/accounts/\(accountId)/storage/kv/namespaces/\(namespaceId)/values/\(encodedKey)") else {
            throw CFAPIError(status: 0, code: nil, message: "KV 地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(value.utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status < 400 else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw CFAPIError(status: status, code: nil, message: "写入 KV 失败：\(text.prefix(200))")
        }
    }

    // MARK: - Pages

    func listPagesProjects(accountId: String) async throws -> [[String: Any]] {
        let result = try await send(method: "GET", path: "/accounts/\(accountId)/pages/projects")
        return JSONHelper.dictionaryArray(result)
    }

    func createPagesProject(accountId: String, name: String, productionBranch: String = "main") async throws -> [String: Any] {
        let result = try await send(
            method: "POST",
            path: "/accounts/\(accountId)/pages/projects",
            json: ["name": name, "production_branch": productionBranch]
        )
        return JSONHelper.dictionary(result)
    }

    func getPagesProject(accountId: String, name: String) async throws -> [String: Any] {
        let result = try await send(method: "GET", path: "/accounts/\(accountId)/pages/projects/\(name)")
        return JSONHelper.dictionary(result)
    }

    func updatePagesDeploymentConfig(
        accountId: String,
        name: String,
        kvNamespaceId: String,
        envVars: [String: String]
    ) async throws {
        var env: [String: Any] = [:]
        for (key, value) in envVars {
            env[key] = ["value": value]
        }
        var namespaces: [String: Any] = [:]
        namespaces["KV"] = ["namespace_id": kvNamespaceId]
        namespaces["K"] = ["namespace_id": kvNamespaceId]

        var production: [String: Any] = [:]
        production["kv_namespaces"] = namespaces
        production["env_vars"] = env

        var configs: [String: Any] = [:]
        configs["production"] = production

        var payload: [String: Any] = [:]
        payload["deployment_configs"] = configs

        _ = try await send(method: "PATCH", path: "/accounts/\(accountId)/pages/projects/\(name)", json: payload)
    }

    /// 上传 `_worker.js` 并触发 Pages 部署。
    /// 外层 multipart 里再嵌一层 multipart（`_worker.bundle`），这是 Pages 接口的硬要求。
    func deployPagesWorker(accountId: String, name: String, code: String, branch: String = "main") async throws -> [String: Any] {
        var inner = MultipartBuilder()
        var metadataObject: [String: Any] = [:]
        metadataObject["main_module"] = "_worker.js"
        metadataObject["bindings"] = [String: Any]()
        let metadata = try JSONSerialization.data(withJSONObject: metadataObject, options: [])
        inner.addFile(name: "metadata", filename: "metadata.json", mimeType: "application/json", content: metadata)
        inner.addFile(
            name: "_worker.js",
            filename: "_worker.js",
            mimeType: "application/javascript+module",
            content: Data(code.utf8)
        )
        let innerBody = inner.finished()

        var outer = MultipartBuilder()
        outer.addField(name: "branch", value: branch)
        outer.addField(name: "manifest", value: "{}")
        outer.addFile(
            name: "_worker.bundle",
            filename: "_worker.bundle",
            mimeType: "multipart/form-data; boundary=\(inner.boundary)",
            content: innerBody
        )

        let result = try await send(
            method: "POST",
            path: "/accounts/\(accountId)/pages/projects/\(name)/deployments",
            body: outer.finished(),
            contentType: outer.contentType
        )
        return JSONHelper.dictionary(result)
    }

    func listPagesDeployments(accountId: String, name: String) async throws -> [[String: Any]] {
        let result = try await send(
            method: "GET",
            path: "/accounts/\(accountId)/pages/projects/\(name)/deployments?per_page=10"
        )
        return JSONHelper.dictionaryArray(result)
    }

    func listPagesDomains(accountId: String, name: String) async throws -> [String] {
        let result = try await send(
            method: "GET",
            path: "/accounts/\(accountId)/pages/projects/\(name)/domains"
        )
        return JSONHelper.dictionaryArray(result).map { JSONHelper.string($0["name"]) }.filter { !$0.isEmpty }
    }

    func deletePagesProject(accountId: String, name: String) async throws {
        _ = try await send(method: "DELETE", path: "/accounts/\(accountId)/pages/projects/\(name)")
    }

    // MARK: - Workers

    func uploadWorkerScript(
        accountId: String,
        name: String,
        code: String,
        bindings: [[String: Any]]
    ) async throws {
        var metadata: [String: Any] = [:]
        metadata["main_module"] = "worker.js"
        metadata["compatibility_date"] = CloudflareAPI.workersCompatibilityDate
        metadata["bindings"] = bindings
        var form = MultipartBuilder()
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [])
        form.addFile(name: "metadata", filename: "metadata.json", mimeType: "application/json", content: metadataData)
        form.addFile(
            name: "worker.js",
            filename: "worker.js",
            mimeType: "application/javascript+module",
            content: Data(code.utf8)
        )
        _ = try await send(
            method: "PUT",
            path: "/accounts/\(accountId)/workers/scripts/\(name)",
            body: form.finished(),
            contentType: form.contentType
        )
    }

    func putScriptSubdomain(accountId: String, name: String, enabled: Bool, previewsEnabled: Bool) async throws {
        _ = try await send(
            method: "POST",
            path: "/accounts/\(accountId)/workers/scripts/\(name)/subdomain",
            json: ["enabled": enabled, "previews_enabled": previewsEnabled]
        )
    }

    func workersSubdomain(accountId: String) async throws -> String {
        let result = try await send(method: "GET", path: "/accounts/\(accountId)/workers/subdomain")
        return JSONHelper.string(JSONHelper.dictionary(result)["subdomain"])
    }

    func listWorkerDomains(accountId: String) async throws -> [[String: Any]] {
        let result = try await send(method: "GET", path: "/accounts/\(accountId)/workers/domains")
        return JSONHelper.dictionaryArray(result)
    }

    func deleteWorkerScript(accountId: String, name: String) async throws {
        _ = try await send(method: "DELETE", path: "/accounts/\(accountId)/workers/scripts/\(name)")
    }

    /// 部署完成后的连通性确认：请求控制面，拿到任意 HTTP 响应即视为上线
    func probeURL(_ urlString: String, timeout: TimeInterval = 15) async -> Int {
        guard let url = URL(string: urlString) else { return 0 }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("CFPilot-iOS/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            return 0
        }
    }
}
