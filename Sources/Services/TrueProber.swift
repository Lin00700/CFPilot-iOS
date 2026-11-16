import Foundation
import Network
import Security

/// 保证续体只被恢复一次
final class OnceContinuation<T> {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<T, Never>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func finish(_ value: T) {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(returning: value)
    }
}

/// 真连接优选器：真的做 TCP 建连 + TLS 握手（SNI 用你自己的域名），
/// 握手成功再发一次 HTTP 请求看状态码与 cf-ray 机房。
///
/// 官方 CLI 的结论在这里同样成立：**TLS 握手耗时的区分度远大于 TCP**，
/// 只按 TCP 排序会挑出「TCP 快、TLS 慢」的 IP，导入客户端就是一片 -1。
/// 因此本 App 两条都测，排序用 TLS。
enum TrueProber {
    struct Options {
        /// TLS SNI / HTTP Host：必须是你自己部署的数据面域名
        var host: String
        var port: UInt16 = 443
        var path: String = "/"
        var timeout: TimeInterval = 6
        var concurrency: Int = 10
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        let now = DispatchTime.now().uptimeNanoseconds
        let then = start.uptimeNanoseconds
        guard now >= then else { return -1 }
        return Int((now - then) / 1_000_000)
    }

    // MARK: - TCP 建连

    private static func tcpConnect(ip: String, port: UInt16, timeout: TimeInterval) async -> Int {
        await withCheckedContinuation { (continuation: CheckedContinuation<Int, Never>) in
            let once = OnceContinuation(continuation)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                once.finish(-1)
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: parameters)
            let queue = DispatchQueue(label: "cfpilot.probe.tcp")
            let start = DispatchTime.now()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    let ms = elapsedMs(since: start)
                    connection.cancel()
                    once.finish(ms)
                case .failed, .waiting:
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    once.finish(-1)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.stateUpdateHandler = nil
                connection.cancel()
                once.finish(-1)
            }
        }
    }

    // MARK: - TLS 握手

    private struct Handshake {
        var connection: NWConnection?
        var ms: Int
        var error: String?
    }

    private static func tlsHandshake(ip: String, port: UInt16, sni: String, timeout: TimeInterval) async -> Handshake {
        await withCheckedContinuation { (continuation: CheckedContinuation<Handshake, Never>) in
            let once = OnceContinuation(continuation)
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                once.finish(Handshake(connection: nil, ms: -1, error: "端口无效"))
                return
            }
            let tlsOptions = NWProtocolTLS.Options()
            let securityOptions = tlsOptions.securityProtocolOptions
            if !sni.isEmpty {
                sec_protocol_options_set_tls_server_name(securityOptions, sni)
            }
            sec_protocol_options_add_tls_application_protocol(securityOptions, "http/1.1")

            let parameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
            parameters.allowLocalEndpointReuse = true
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: nwPort, using: parameters)
            let queue = DispatchQueue(label: "cfpilot.probe.tls")
            let start = DispatchTime.now()

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.stateUpdateHandler = nil
                    let ms = elapsedMs(since: start)
                    once.finish(Handshake(connection: connection, ms: ms, error: nil))
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    once.finish(Handshake(connection: nil, ms: -1, error: "握手失败：\(error)"))
                case .waiting(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    once.finish(Handshake(connection: nil, ms: -1, error: "等待网络：\(error)"))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                connection.stateUpdateHandler = nil
                connection.cancel()
                once.finish(Handshake(connection: nil, ms: -1, error: "握手超时"))
            }
        }
    }

    // MARK: - HTTP 头

    private static func httpHead(
        connection: NWConnection,
        host: String,
        path: String,
        timeout: TimeInterval
    ) async -> (status: Int, colo: String) {
        await withCheckedContinuation { (continuation: CheckedContinuation<(Int, String), Never>) in
            let once = OnceContinuation(continuation)
            let request = "GET \(path) HTTP/1.1\r\n"
                + "Host: \(host)\r\n"
                + "User-Agent: CFPilot-iOS/1.0\r\n"
                + "Accept: */*\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
            readHead(connection, buffer: Data(), once: once)

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                once.finish((0, ""))
            }
        }
    }

    private static func readHead(
        _ connection: NWConnection,
        buffer: Data,
        once: OnceContinuation<(Int, String)>
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            var accumulated = buffer
            if let data, !data.isEmpty {
                accumulated.append(data)
            }
            let text = String(decoding: accumulated, as: UTF8.self)
            if text.contains("\r\n\r\n") {
                once.finish(parseHead(text))
                return
            }
            if accumulated.count > 16384 || isComplete || error != nil {
                once.finish(parseHead(text))
                return
            }
            readHead(connection, buffer: accumulated, once: once)
        }
    }

    private static func parseHead(_ text: String) -> (status: Int, colo: String) {
        var status = 0
        var colo = ""
        let lines = text.components(separatedBy: "\r\n")
        if let first = lines.first {
            let parts = first.split(separator: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                status = code
            }
        }
        for line in lines.dropFirst() {
            if line.lowercased().hasPrefix("cf-ray:") {
                let value = line.replacingOccurrences(of: "cf-ray:", with: "")
                    .replacingOccurrences(of: "CF-Ray:", with: "")
                    .trimmingCharacters(in: .whitespaces)
                if let dash = value.lastIndex(of: "-") {
                    let suffix = value[value.index(after: dash)...]
                    colo = String(suffix).uppercased()
                }
            }
        }
        return (status, colo)
    }

    // MARK: - 单个目标

    static func probeOne(ip: String, options: Options) async -> ProbeResult {
        async let tcpTask = tcpConnect(ip: ip, port: options.port, timeout: options.timeout)
        let handshake = await tlsHandshake(
            ip: ip,
            port: options.port,
            sni: options.host,
            timeout: options.timeout
        )
        let tcpMs = await tcpTask

        guard let connection = handshake.connection else {
            return ProbeResult(
                ip: ip,
                tcpMs: tcpMs,
                tlsMs: -1,
                httpStatus: 0,
                colo: "",
                ok: false,
                note: handshake.error ?? "TLS 握手失败"
            )
        }

        var status = 0
        var colo = ""
        if !options.host.isEmpty {
            let response = await httpHead(
                connection: connection,
                host: options.host,
                path: options.path,
                timeout: options.timeout
            )
            status = response.status
            colo = response.colo
        }
        connection.cancel()

        return ProbeResult(
            ip: ip,
            tcpMs: tcpMs,
            tlsMs: handshake.ms,
            httpStatus: status,
            colo: colo,
            ok: true,
            note: ""
        )
    }

    // MARK: - 批量（带并发上限）

    static func probe(
        ips: [String],
        options: Options,
        onProgress: @escaping (Int, Int) -> Void
    ) async -> [ProbeResult] {
        let total = ips.count
        guard total > 0 else { return [] }
        var results: [ProbeResult] = []
        var index = 0
        let limit = max(1, min(options.concurrency, total))

        await withTaskGroup(of: ProbeResult.self) { group in
            while index < limit {
                let ip = ips[index]
                group.addTask { await TrueProber.probeOne(ip: ip, options: options) }
                index += 1
            }
            while let result = await group.next() {
                results.append(result)
                let done = results.count
                await MainActor.run { onProgress(done, total) }
                if index < total {
                    let ip = ips[index]
                    group.addTask { await TrueProber.probeOne(ip: ip, options: options) }
                    index += 1
                }
            }
        }

        return results.sorted { $0.sortKey < $1.sortKey }
    }
}
