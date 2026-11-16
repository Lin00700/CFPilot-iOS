import Foundation

/// 部署用的两份内核产物
struct KernelBundle: Equatable {
    var control: String
    var data: String
    /// 内核序号（`cfpilot-kernel-VERSION` 的 seq）
    var version: String
    /// 构建指纹（产物里的 BUILD_VERSION，形如 a946dfa-1f2e3d4c）
    var build: String
    /// 来源说明，用于日志
    var source: String
}

/// 从 `xmwengxing/CFPilot` 拉内核产物。
///
/// 与官方 CLI 一致的取法：
///   1. Release 固定通道 `kernel-latest` 的固定名资产（控制面 / 数据面 / 版本清单）；
///   2. 直连不通时走下载镜像（ghfast.top 等），镜像前缀拼完整 GitHub URL；
///   3. Release 不可用时回落到仓库 `main` 分支上的同源产物（`packages/cli/assets/`）。
///
/// 不把内核打进 App 包：产物随上游发布更新，运行时拉取才能拿到最新内核，
/// 也让本仓库保持纯 Swift 源码、不掺入上游 AGPL 产物。
enum KernelSource {
    static let owner = "xmwengxing"
    static let repo = "CFPilot"
    static let channelTag = "kernel-latest"

    static let controlAsset = "cfpilot-kernel-control.js"
    static let dataAsset = "cfpilot-kernel-dataplane.js"
    static let versionAsset = "cfpilot-kernel-VERSION"

    /// 下载镜像前缀（与官方 CLI 的 MIRRORS 一致）
    static let mirrors = [
        "",
        "https://ghfast.top/",
        "https://ghproxy.net/",
        "https://gh-proxy.com/",
    ]

    enum KernelError: LocalizedError {
        case downloadFailed(String)
        case invalidContent(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let what):
                return "内核下载失败：\(what)。可检查网络后重试；本 App 会依次尝试 GitHub 直连与多个下载镜像。"
            case .invalidContent(let what):
                return "内核产物内容异常：\(what)"
            }
        }
    }

    private static var releaseURL: String {
        "https://github.com/\(owner)/\(repo)/releases/download/\(channelTag)"
    }

    private static var rawURL: String {
        "https://raw.githubusercontent.com/\(owner)/\(repo)/main/packages/cli/assets"
    }

    /// 依次尝试：Release 资产（直连 + 镜像）→ 仓库原始文件（直连 + 镜像）
    private static func candidates(releaseAsset: String, rawAsset: String) -> [String] {
        var urls: [String] = []
        let release = "\(releaseURL)/\(releaseAsset)"
        let raw = "\(rawURL)/\(rawAsset)"
        for mirror in mirrors {
            urls.append(mirror.isEmpty ? release : mirror + release)
        }
        for mirror in mirrors {
            urls.append(mirror.isEmpty ? raw : mirror + raw)
        }
        return urls
    }

    private static func fetch(_ urlString: String, timeout: TimeInterval = 30) async throws -> String {
        guard let url = URL(string: urlString) else {
            throw KernelError.downloadFailed("地址无效 \(urlString)")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("CFPilot-iOS/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, !data.isEmpty else {
            throw KernelError.downloadFailed("HTTP \(status) \(urlString)")
        }
        guard let text = String(data: data, encoding: .utf8), text.count > 500 else {
            throw KernelError.downloadFailed("内容过短 \(urlString)")
        }
        return text
    }

    private static func fetchFirst(_ urls: [String]) async -> (text: String, url: String)? {
        for url in urls {
            if let text = try? await fetch(url) {
                return (text, url)
            }
        }
        return nil
    }

    /// 解析 `cfpilot-kernel-VERSION`（JSON：{ "seq": 202611151707, "build": "..." }）
    private static func fetchVersionText() async -> String {
        let urls = candidates(releaseAsset: versionAsset, rawAsset: versionAsset)
        if let hit = await fetchFirst(urls) {
            return hit.text
        }
        return ""
    }

    private static func parseSeq(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else { return "" }
        if let seq = dict["seq"] as? Int { return "\(seq)" }
        if let seq = dict["seq"] as? NSNumber { return seq.stringValue }
        return ""
    }

    /// 从产物里提取构建指纹（`var BUILD_VERSION = "a946dfa-1f2e3d4c"`）
    static func extractBuild(_ code: String) -> String {
        let pattern = "[\"']([0-9a-f]{7,10}-(?:[0-9a-f]{4,16}|[0-9]{12}))[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "" }
        let range = NSRange(code.startIndex..<code.endIndex, in: code)
        guard let match = regex.firstMatch(in: code, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: code) else { return "" }
        return String(code[r])
    }

    /// 加载内核（控制面 + 数据面 + 版本）
    static func load() async throws -> KernelBundle {
        async let controlHit = fetchFirst(candidates(releaseAsset: controlAsset, rawAsset: "control.js"))
        async let dataHit = fetchFirst(candidates(releaseAsset: dataAsset, rawAsset: "dataplane.js"))
        async let versionText = fetchVersionText()

        let control = await controlHit
        let data = await dataHit
        let version = await versionText

        guard let control else { throw KernelError.downloadFailed(controlAsset) }
        guard let data else { throw KernelError.downloadFailed(dataAsset) }

        // 产物健全性检查：必须像一份打包后的 Worker 模块
        guard control.text.count > 2000, data.text.count > 2000 else {
            throw KernelError.invalidContent("产物长度不足")
        }

        let build = extractBuild(control.text)
        let sourceLabel: String = control.url.hasPrefix("https://raw.githubusercontent.com")
            ? "仓库 main 分支产物"
            : "Release \(channelTag)"
        let seq = parseSeq(version)
        return KernelBundle(
            control: control.text,
            data: data.text,
            version: seq.isEmpty ? "未知" : seq,
            build: build,
            source: sourceLabel
        )
    }
}
