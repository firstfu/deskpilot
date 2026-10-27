//
//  CloudflareDDNS.swift
//  DeskPilotHost
//
//  把使用者自己放在 Cloudflare 的網域名稱指向目前的公網 IP，手機的 QR code 就能記「名稱」而不是 IP，
//  IP 變動後不必重新配對。使用者提供主機名稱與 API Token（權限：Zone › DNS › Edit，只限該網域），
//  Token 只存在鑰匙圈。記錄固定為「僅 DNS」（不走 Cloudflare 代理），因為 WireGuard 是 UDP。
//

import Foundation
import Security

enum DDNSError: LocalizedError {
    case invalidHostname
    case zoneNotFound
    case api(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .invalidHostname: "主機名稱格式不正確（例如 mac.example.com）"
        case .zoneNotFound: "在這個 Token 能看到的網域裡找不到對應的區域，請確認名稱與 Token 權限"
        case .api(let msg): "Cloudflare：\(msg)"
        case .network(let msg): "連不上 Cloudflare：\(msg)"
        }
    }
}

/// Token 的鑰匙圈存取。
enum DDNSKeychain {
    private static let service = "tw.firstfu.DeskPilotHost.cloudflare"
    private static let account = "api-token"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func loadToken() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    static func deleteToken() { SecItemDelete(query as CFDictionary) }
}

enum CloudflareDDNS {
    private static let base = "https://api.cloudflare.com/client/v4"

    static func isValidHostname(_ name: String) -> Bool {
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3, name.count <= 253 else { return false }
        return labels.allSatisfy { l in
            (1...63).contains(l.count) && !l.hasPrefix("-") && !l.hasSuffix("-")
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    /// 把 hostname 的 A 記錄設成 ip；不存在就建立。
    static func update(hostname: String, ip: String, token: String) async throws {
        guard isValidHostname(hostname) else { throw DDNSError.invalidHostname }
        let zoneID = try await findZone(for: hostname, token: token)
        let body: [String: Any] = ["type": "A", "name": hostname, "content": ip, "ttl": 60, "proxied": false]

        let existing: [Record] = try await call("GET", "/zones/\(zoneID)/dns_records?type=A&name=\(hostname)", token: token)
        if let record = existing.first {
            if record.content == ip && record.proxied == false { return }
            let _: Record = try await call("PUT", "/zones/\(zoneID)/dns_records/\(record.id)", token: token, body: body)
        } else {
            let _: Record = try await call("POST", "/zones/\(zoneID)/dns_records", token: token, body: body)
        }
    }

    /// 由長到短試 hostname 的各層後綴（a.b.example.com → b.example.com → example.com），第一個 Token 看得到的就是區域。
    private static func findZone(for hostname: String, token: String) async throws -> String {
        let labels = hostname.split(separator: ".").map(String.init)
        for start in 1..<(labels.count - 1) {
            let name = labels[start...].joined(separator: ".")
            let zones: [Zone] = try await call("GET", "/zones?name=\(name)", token: token)
            if let zone = zones.first { return zone.id }
        }
        throw DDNSError.zoneNotFound
    }

    private struct Zone: Decodable { let id: String }
    private struct Record: Decodable { let id: String; let content: String; let proxied: Bool? }
    private struct Envelope<T: Decodable>: Decodable {
        struct Err: Decodable { let message: String }
        let success: Bool
        let errors: [Err]
        let result: T?
    }

    private static func call<T: Decodable>(_ method: String, _ path: String, token: String, body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: base + path) else { throw DDNSError.invalidHostname }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        do { (data, _) = try await URLSession.shared.data(for: req) } catch { throw DDNSError.network(error.localizedDescription) }
        guard let env = try? JSONDecoder().decode(Envelope<T>.self, from: data) else { throw DDNSError.api("回應格式無法解析") }
        guard env.success, let result = env.result else {
            throw DDNSError.api(env.errors.first?.message ?? "未知錯誤")
        }
        return result
    }
}
