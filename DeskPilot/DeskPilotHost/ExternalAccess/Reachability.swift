//
//  Reachability.swift
//  DeskPilotHost
//
//  判斷這台 Mac 從外網能不能被直連：比對「路由器自己認為的 WAN 位址」與「外部服務看到的公網位址」。
//  兩者不同（或 WAN 位址落在私有／CGNAT 網段）代表前面還有一層 NAT，WireGuard 直連不可能通。
//

import Foundation

enum Reachability: Equatable {
    /// 直連可行，publicIP 是手機該連的位址。
    case direct(publicIP: String)
    /// 路由器的 WAN 位址是私有或 CGNAT（100.64.0.0/10），營運商或上層路由器還有一層 NAT。
    case behindNAT(routerIP: String, publicIP: String?)
    /// 查不到公網位址（沒網路或服務不通）。
    case offline

    static func evaluate(mapping: PortMapping?) async -> Reachability {
        guard let publicIP = await fetchPublicIP() else { return .offline }
        // 沒有對映結果（路由器不支援）時無法比對，樂觀當作可直連；實際通不通由手機端驗證。
        guard let router = mapping?.routerExternalIP, !router.isEmpty else { return .direct(publicIP: publicIP) }
        if router != publicIP || isPrivateOrCGNAT(router) { return .behindNAT(routerIP: router, publicIP: publicIP) }
        return .direct(publicIP: publicIP)
    }

    /// 向外部服務查公網 IPv4。多個備援，任一個回得出合法位址即可。
    static func fetchPublicIP() async -> String? {
        for urlString in ["https://api.ipify.org", "https://ipv4.icanhazip.com"] {
            guard let url = URL(string: urlString) else { continue }
            var req = URLRequest(url: url, timeoutInterval: 5)
            req.cachePolicy = .reloadIgnoringLocalCacheData
            guard let (data, _) = try? await URLSession.shared.data(for: req) else { continue }
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if parseIPv4(text) != nil { return text }
        }
        return nil
    }

    static func isPrivateOrCGNAT(_ ip: String) -> Bool {
        guard let o = parseIPv4(ip) else { return false }
        switch (o[0], o[1]) {
        case (10, _), (192, 168), (127, _), (169, 254): return true
        case (172, 16...31): return true
        case (100, 64...127): return true
        default: return false
        }
    }

    private static func parseIPv4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".").compactMap { Int($0) }
        return parts.count == 4 && parts.allSatisfy({ (0...255).contains($0) }) ? parts : nil
    }
}
