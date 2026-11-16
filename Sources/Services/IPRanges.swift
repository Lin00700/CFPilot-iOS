import Foundation

/// Cloudflare 网段与候选 IP 采样
enum IPRanges {
    /// 内置 IPv4 网段（Cloudflare 官方公布的主要段，与官方 CLI 的 BUILTIN_IPV4_CIDRS 一致）
    static let builtinV4: [String] = [
        "173.245.48.0/20",
        "103.21.244.0/22",
        "103.22.200.0/22",
        "103.31.4.0/22",
        "141.101.64.0/18",
        "108.162.192.0/18",
        "190.93.240.0/20",
        "188.114.96.0/20",
        "197.234.240.0/22",
        "198.41.128.0/17",
        "162.158.0.0/15",
        "104.16.0.0/13",
        "104.24.0.0/14",
        "172.64.0.0/13",
        "131.0.72.0/22",
    ]

    /// 把用户输入按行拆成 IPv4 / CIDR 列表（忽略空行与 # 注释）
    static func parseLines(_ text: String) -> [String] {
        var out: [String] = []
        for rawLine in text.components(separatedBy: .newlines) {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") {
                line = String(line[line.startIndex..<hash])
            }
            let token = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if token.isEmpty { continue }
            if isValidIPv4(token) || parseCIDR(token) != nil {
                out.append(token)
            }
        }
        return out
    }

    static func isValidIPv4(_ text: String) -> Bool {
        parseIPv4(text) != nil
    }

    static func parseIPv4(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255 else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    static func string(from value: UInt32) -> String {
        let a = (value >> 24) & 0xFF
        let b = (value >> 16) & 0xFF
        let c = (value >> 8) & 0xFF
        let d = value & 0xFF
        return "\(a).\(b).\(c).\(d)"
    }

    static func parseCIDR(_ text: String) -> (base: UInt32, bits: Int)? {
        let pieces = text.split(separator: "/")
        guard let first = pieces.first, let ip = parseIPv4(String(first)) else { return nil }
        var bits = 32
        if pieces.count >= 2 {
            guard let parsed = Int(pieces[1]), parsed >= 8, parsed <= 32 else { return nil }
            bits = parsed
        }
        let hostBits = UInt32(32 - bits)
        let mask: UInt32 = hostBits == 0 ? 0xFFFF_FFFF : (0xFFFF_FFFF << hostBits)
        return (ip & mask, bits)
    }

    /// 从一个网段里随机取一个主机地址
    static func randomIP(inCIDR cidr: String) -> String? {
        guard let parsed = parseCIDR(cidr) else {
            if isValidIPv4(cidr) { return cidr }
            return nil
        }
        let hostBits = 32 - parsed.bits
        if hostBits <= 1 {
            return string(from: parsed.base)
        }
        let hostCount = (UInt32(1) << UInt32(hostBits)) - 1
        let offset = UInt32.random(in: 1..<max(2, hostCount))
        let value = parsed.base &+ offset
        return string(from: value)
    }

    /// 从一组网段中采样 count 个不重复 IP（每段轮流取，尽量分散）
    static func sample(from sources: [String], count: Int) -> [String] {
        let wanted = max(1, count)
        var seen = Set<String>()
        var out: [String] = []
        var pool = sources
        if pool.isEmpty { pool = builtinV4 }
        var guardCounter = 0
        while out.count < wanted && guardCounter < wanted * 60 {
            guardCounter += 1
            let cidr = pool[Int.random(in: 0..<pool.count)]
            guard let ip = randomIP(inCIDR: cidr) else { continue }
            if seen.insert(ip).inserted {
                out.append(ip)
            }
        }
        // 输入本身就是一串 IP 时，随机采样可能拿不满，补齐原文里的 IP
        if out.count < wanted {
            for source in sources where isValidIPv4(source) {
                if seen.insert(source).inserted { out.append(source) }
                if out.count >= wanted { break }
            }
        }
        return out
    }
}
