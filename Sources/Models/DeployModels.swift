import Foundation

/// 数据面部署形态
enum DataPlaneMode: String, Codable, CaseIterable, Identifiable {
    case pages
    case workers

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pages: return "Pages（推荐）"
        case .workers: return "Workers"
        }
    }

    var detail: String {
        switch self {
        case .pages:
            return "数据面同样部署成一个 Pages 项目，*.pages.dev 直连可访问，无需自己绑域名。"
        case .workers:
            return "数据面部署成 Worker，走 *.workers.dev；自定义域名需要你到 Cloudflare 控制台自己绑。"
        }
    }
}

/// Cloudflare 账号（用结构体而不是元组：ForEach 的 id keypath 不能指向元组成员）
struct CFAccount: Identifiable, Hashable {
    let id: String
    let name: String
}

/// 一次部署生成的凭据（与内核 KV 的 CONFIG 字段一致）
struct DeployCredentials: Codable, Equatable {
    var panelPath: String
    var panelPassword: String
    var uuid: String
    var trojanPassword: String
    var wsPath: String

    static func random() -> DeployCredentials {
        DeployCredentials(
            panelPath: "/p-" + Randomizer.alnum(8),
            panelPassword: "cfp-" + Randomizer.alnum(14),
            uuid: Randomizer.uuid(),
            trojanPassword: "cfp-" + Randomizer.alnum(14),
            wsPath: "/" + Randomizer.alnum(10)
        )
    }
}

/// 写在 KV 的 `CFP_DEPLOY_MANIFEST` 键，格式与官方 CLI 的 DeployManifest 兼容。
struct DeployManifest: Codable, Equatable {
    var v: Int = 1
    var kvNamespaceId: String?
    var controlProject: String
    var dataProject: String
    var controlSubdomain: String
    var dataSubdomain: String
    var dataCustomDomain: String?
    var dataPlaneMode: String?
    var build: String
    var kernelVersion: String?
    var at: String
    var credentials: DeployCredentials

    enum CodingKeys: String, CodingKey {
        case v
        case kvNamespaceId
        case controlProject
        case dataProject
        case controlSubdomain
        case dataSubdomain
        case dataCustomDomain
        case dataPlaneMode
        case build
        case kernelVersion
        case at
        case credentials
    }
}

/// 本机记住的一次成功部署
struct DeploymentRecord: Codable, Equatable {
    var accountId: String
    var accountName: String
    var kvNamespaceId: String
    var controlProject: String
    var dataProject: String
    var controlSubdomain: String
    var dataSubdomain: String
    var panelPath: String
    var panelPassword: String
    var uuid: String
    var trojanPassword: String
    var wsPath: String
    var dataPlaneMode: String
    var dataHost: String
    var build: String
    var deployedAt: Date

    var panelURLString: String {
        "https://\(controlSubdomain)\(panelPath)"
    }

    var panelURL: URL? {
        URL(string: panelURLString)
    }

    /// 订阅与优选器默认使用的节点域名
    var nodeHost: String {
        let host = dataHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return host.isEmpty ? dataSubdomain : host
    }

    var mode: DataPlaneMode {
        DataPlaneMode(rawValue: dataPlaneMode) ?? .pages
    }
}

/// 部署向导的输入
struct DeployRequest {
    var token: String
    var accountId: String = ""
    var dataPlaneMode: DataPlaneMode = .pages
    var dataHost: String = ""
    var enableTrojan: Bool = true
    var enableXhttp: Bool = true
    /// 更新部署时沿用旧凭据（UUID / WS 路径 / 面板密码）
    var keepCredentials: Bool = true
    /// 可留空：留空则随机生成
    var controlProject: String = ""
    var dataProject: String = ""
    /// 已有 KV 命名空间（更新时沿用）；留空则新建
    var kvNamespaceId: String = ""
    /// 已知的清单（更新部署时由调用方带入，避免重复读 KV）
    var knownManifest: DeployManifest? = nil
}

/// 部署日志的一条
struct DeployLogEntry: Identifiable, Equatable {
    enum Level: String {
        case info, success, warning, failure
    }

    let id = UUID()
    var level: Level
    var title: String
    var detail: String = ""
    var time: Date = Date()
}

/// 优选器的一次探测结果
struct ProbeResult: Identifiable, Equatable {
    let id = UUID()
    var ip: String
    /// 纯 TCP 建连耗时（ms）
    var tcpMs: Int
    /// TCP + TLS 握手完成耗时（ms），-1 表示握手失败
    var tlsMs: Int
    /// 握手后 HTTP 响应的状态码（0 = 没测到）
    var httpStatus: Int
    /// Cloudflare 机房代码（cf-ray 尾巴，例如 HKG / LAX）
    var colo: String
    var ok: Bool
    var note: String

    /// 排序用的真实延迟：优先 TLS，其次 TCP
    var sortKey: Int {
        if tlsMs > 0 { return tlsMs }
        if tcpMs > 0 { return tcpMs }
        return Int.max
    }

    var latencyText: String {
        if tlsMs > 0 { return "\(tlsMs) ms" }
        if tcpMs > 0 { return "TCP \(tcpMs) ms" }
        return "—"
    }

    var tcpText: String {
        tcpMs > 0 ? "\(tcpMs)" : "—"
    }

    var statusText: String {
        httpStatus > 0 ? "\(httpStatus)" : "—"
    }

    /// 导入优选池时用的一行
    var poolLine: String {
        colo.isEmpty ? ip : "\(ip)#\(colo)"
    }
}

/// 随机值生成
enum Randomizer {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    static func alnum(_ length: Int) -> String {
        var out = ""
        for _ in 0..<max(1, length) {
            out.append(alphabet[Int.random(in: 0..<alphabet.count)])
        }
        return out
    }

    /// Pages 项目名 / Worker 脚本名：小写字母开头，8~10 位，不含项目特征字符
    static func projectName() -> String {
        let length = Int.random(in: 8...10)
        let first = Array("abcdefghijklmnopqrstuvwxyz")
        var out = String(first[Int.random(in: 0..<first.count)])
        out += alnum(length - 1)
        return out
    }

    static func uuid() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let a = hex.prefix(8)
        let b = hex.dropFirst(8).prefix(4)
        let c = hex.dropFirst(12).prefix(4)
        let d = hex.dropFirst(16).prefix(4)
        let e = hex.dropFirst(20).prefix(12)
        return "\(a)-\(b)-\(c)-\(d)-\(e)"
    }
}
