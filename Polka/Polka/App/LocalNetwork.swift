import Foundation

/// Tells addresses on this Mac or the local network from ones on the public internet.
///
/// Link previews only contact public addresses (`LinkPreviewFetcher.mayLookUp`). A web
/// page decides what its drags carry, and App Transport Security lets plain http through
/// to IP addresses and local names, so without this a page could make Polka send a
/// request to a router, printer or local server the moment its link is dropped, and
/// some of those act on any request they get.
///
/// It goes by the address alone. A public name that the internet resolves to a local
/// address gets no further than it would without this: plain http to a name is blocked
/// by App Transport Security, and https needs a certificate the local device doesn't have.
enum LocalNetwork {
    /// Name endings that only mean something on a local network: Bonjour's `.local`,
    /// the ones home routers hand out, and the ones set aside for private use.
    private static let localNameEndings = ["localhost", "local", "localdomain", "lan", "home", "home.arpa", "internal"]

    /// True for an address on this Mac or the local network, and for one without a host.
    static func contains(_ url: URL) -> Bool {
        guard var host = url.host?.lowercased(), !host.isEmpty else { return true }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        // "example.com." is the same name as "example.com".
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if let address = ipv4(host) {
            return isLocal(address)
        }
        if let address = ipv6(host) {
            return isLocal(address)
        }
        // A name with no dot, like "nas" or "router", is looked up on the local network.
        guard host.contains(".") else { return true }
        return localNameEndings.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    // MARK: - IPv4

    /// An IPv4 address in any form the system accepts, which includes the old short
    /// ones: "127.1", and "2130706433" or "0x7f000001", which are both 127.0.0.1.
    private static func ipv4(_ host: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(host, &address) != 0 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// Ranges that never lead to the public internet: (first address, prefix length).
    private static let localIPv4Ranges: [(base: UInt32, bits: UInt32)] = [
        (0x0000_0000, 8),   // 0.0.0.0/8, "this network"
        (0x0A00_0000, 8),   // 10.0.0.0/8, private
        (0x6440_0000, 10),  // 100.64.0.0/10, carrier-grade NAT, and Tailscale
        (0x7F00_0000, 8),   // 127.0.0.0/8, this Mac
        (0xA9FE_0000, 16),  // 169.254.0.0/16, link-local
        (0xAC10_0000, 12),  // 172.16.0.0/12, private
        (0xC000_0000, 24),  // 192.0.0.0/24, protocol use
        (0xC0A8_0000, 16),  // 192.168.0.0/16, private
        (0xC612_0000, 15),  // 198.18.0.0/15, network testing
        (0xE000_0000, 3),   // 224.0.0.0 and up: multicast, reserved, broadcast
    ]

    private static func isLocal(_ address: UInt32) -> Bool {
        localIPv4Ranges.contains { range in
            address >> (32 - range.bits) == range.base >> (32 - range.bits)
        }
    }

    // MARK: - IPv6

    private static func ipv6(_ host: String) -> [UInt8]? {
        // A zone, as in "fe80::1%en0", only exists on a local network.
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var address = in6_addr()
        guard inet_pton(AF_INET6, bare, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }

    private static func isLocal(_ address: [UInt8]) -> Bool {
        // ::, ::1 and IPv4 written inside IPv6 (::a.b.c.d and ::ffff:a.b.c.d) are judged
        // by their IPv4 part.
        let embedsIPv4 = address[0..<10].allSatisfy { $0 == 0 }
            && (address[10..<12].allSatisfy { $0 == 0 } || address[10..<12].allSatisfy { $0 == 0xFF })
        if embedsIPv4 {
            return isLocal(address[12..<16].reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
        }
        return address[0] & 0xFE == 0xFC        // fc00::/7, unique local
            || (address[0] == 0xFE && address[1] & 0x80 == 0x80)  // fe80::/10 link-local, fec0::/10 site-local
            || address[0] == 0xFF               // ff00::/8, multicast
    }
}
