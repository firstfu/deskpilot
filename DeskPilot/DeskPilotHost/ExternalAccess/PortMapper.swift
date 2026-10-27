//
//  PortMapper.swift
//  DeskPilotHost
//
//  向路由器登記 UDP 埠轉發（外網 WireGuard 的入口）。先試 NAT-PMP（一個 UDP 封包就好），
//  不支援再退回 UPnP-IGD（SSDP 找路由器 → SOAP AddPortMapping）。
//  只做登記與查詢，不碰任何設定檔；定期重新呼叫 map 就是續約。
//

import Darwin
import Foundation

struct PortMapping: Equatable {
    enum Method: String { case natPMP = "NAT-PMP", upnp = "UPnP" }
    let method: Method
    /// 路由器自己認為的外部（WAN）位址；與公網位址不同代表前面還有一層 NAT。
    let routerExternalIP: String
    let port: UInt16
}

enum PortMapperError: Error, LocalizedError {
    case noGateway
    case unsupported
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .noGateway: "找不到預設閘道"
        case .unsupported: "路由器不支援 NAT-PMP 或 UPnP，請手動轉發埠"
        case .rejected(let why): "路由器拒絕開埠：\(why)"
        }
    }
}

enum PortMapper {
    static func map(port: UInt16) async throws -> PortMapping {
        if let gateway = defaultGateway(), let m = try? await NATPMP.map(gateway: gateway, port: port) {
            return m
        }
        return try await UPnP.map(port: port)
    }

    static func unmap(port: UInt16) async {
        if let gateway = defaultGateway() { _ = try? await NATPMP.unmap(gateway: gateway, port: port) }
        await UPnP.unmap(port: port)
    }

    /// 預設閘道 IPv4。用 `route` 而不是自己解析路由表，輸出格式穩定。
    static func defaultGateway() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/route")
        p.arguments = ["-n", "get", "default"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { return t.dropFirst("gateway:".count).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    /// 從本機連到 host 時會用的來源位址（UPnP 要告訴路由器轉到哪台）。
    fileprivate static func localAddress(toward host: String) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(9).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard ok == 0 else { return nil }
        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard got == 0 else { return nil }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &local.sin_addr, &buf, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buf)
    }
}

// MARK: - NAT-PMP（RFC 6886）

private enum NATPMP {
    private static let lifetime: UInt32 = 3600

    static func map(gateway: String, port: UInt16) async throws -> PortMapping {
        try await Task.detached {
            // 先問外部位址（opcode 0），再要求 UDP 對映（opcode 1）。
            let ext = try exchange(gateway: gateway, request: [0, 0], expectedOpcode: 128)
            guard ext.count >= 12 else { throw PortMapperError.unsupported }
            let ip = "\(ext[8]).\(ext[9]).\(ext[10]).\(ext[11])"
            try request(gateway: gateway, port: port, lifetime: lifetime)
            return PortMapping(method: .natPMP, routerExternalIP: ip, port: port)
        }.value
    }

    static func unmap(gateway: String, port: UInt16) async throws {
        try await Task.detached { try request(gateway: gateway, port: port, lifetime: 0) }.value
    }

    private static func request(gateway: String, port: UInt16, lifetime: UInt32) throws {
        var pkt: [UInt8] = [0, 1, 0, 0]
        pkt += [UInt8(port >> 8), UInt8(port & 0xFF), UInt8(port >> 8), UInt8(port & 0xFF)]
        pkt += [UInt8(lifetime >> 24), UInt8((lifetime >> 16) & 0xFF), UInt8((lifetime >> 8) & 0xFF), UInt8(lifetime & 0xFF)]
        let reply = try exchange(gateway: gateway, request: pkt, expectedOpcode: 129)
        guard reply.count >= 16 else { throw PortMapperError.unsupported }
        let result = UInt16(reply[2]) << 8 | UInt16(reply[3])
        if result != 0 { throw PortMapperError.rejected("NAT-PMP 結果碼 \(result)") }
    }

    /// 送一個 UDP 封包到閘道 5351 並等回覆（RFC 建議重送 250ms 起倍增，這裡簡化成 3 次）。
    private static func exchange(gateway: String, request: [UInt8], expectedOpcode: UInt8) throws -> [UInt8] {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw PortMapperError.unsupported }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(5351).bigEndian
        guard inet_pton(AF_INET, gateway, &addr.sin_addr) == 1 else { throw PortMapperError.noGateway }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        for _ in 0..<3 {
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            let sent = request.withUnsafeBytes { raw in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            guard sent == request.count else { continue }
            var buf = [UInt8](repeating: 0, count: 64)
            let n = recv(fd, &buf, buf.count, 0)
            if n >= 8, buf[0] == 0, buf[1] == expectedOpcode { return Array(buf[0..<n]) }
            tv.tv_usec *= 2
        }
        throw PortMapperError.unsupported
    }
}

// MARK: - UPnP-IGD

private enum UPnP {
    private struct Control {
        let url: URL
        let serviceType: String
    }

    static func map(port: UInt16) async throws -> PortMapping {
        guard let control = await discover() else { throw PortMapperError.unsupported }
        guard let host = control.url.host, let local = PortMapper.localAddress(toward: host) else { throw PortMapperError.noGateway }

        // 部分路由器不接受有限租約，先試 1 小時，被拒再試永久（0）。
        do {
            try await addMapping(control, port: port, local: local, lease: 3600)
        } catch {
            try await addMapping(control, port: port, local: local, lease: 0)
        }
        let ip = (try? await externalIP(control)) ?? ""
        return PortMapping(method: .upnp, routerExternalIP: ip, port: port)
    }

    static func unmap(port: UInt16) async {
        guard let control = await discover() else { return }
        let body = """
        <u:DeletePortMapping xmlns:u="\(control.serviceType)"><NewRemoteHost></NewRemoteHost>\
        <NewExternalPort>\(port)</NewExternalPort><NewProtocol>UDP</NewProtocol></u:DeletePortMapping>
        """
        _ = try? await soap(control, action: "DeletePortMapping", body: body)
    }

    private static func addMapping(_ c: Control, port: UInt16, local: String, lease: Int) async throws {
        let body = """
        <u:AddPortMapping xmlns:u="\(c.serviceType)"><NewRemoteHost></NewRemoteHost>\
        <NewExternalPort>\(port)</NewExternalPort><NewProtocol>UDP</NewProtocol>\
        <NewInternalPort>\(port)</NewInternalPort><NewInternalClient>\(local)</NewInternalClient>\
        <NewEnabled>1</NewEnabled><NewPortMappingDescription>DeskPilot</NewPortMappingDescription>\
        <NewLeaseDuration>\(lease)</NewLeaseDuration></u:AddPortMapping>
        """
        _ = try await soap(c, action: "AddPortMapping", body: body)
    }

    private static func externalIP(_ c: Control) async throws -> String {
        let body = "<u:GetExternalIPAddress xmlns:u=\"\(c.serviceType)\"></u:GetExternalIPAddress>"
        let xml = try await soap(c, action: "GetExternalIPAddress", body: body)
        return tag("NewExternalIPAddress", in: xml) ?? ""
    }

    private static func soap(_ c: Control, action: String, body: String) async throws -> String {
        var req = URLRequest(url: c.url, timeoutInterval: 5)
        req.httpMethod = "POST"
        req.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        req.setValue("\"\(c.serviceType)#\(action)\"", forHTTPHeaderField: "SOAPAction")
        req.httpBody = Data("""
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """.utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let text = String(decoding: data, as: UTF8.self)
        if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
            throw PortMapperError.rejected(tag("errorDescription", in: text) ?? "HTTP \(http.statusCode)")
        }
        return text
    }

    // 找路由器：SSDP 搜尋 → 抓裝置描述 → 找 WAN 連線服務的控制網址。

    private static func discover() async -> Control? {
        guard let location = await Task.detached(operation: { ssdpSearch() }).value,
              let (data, _) = try? await URLSession.shared.data(from: location) else { return nil }
        let xml = String(decoding: data, as: UTF8.self)
        let types = ["WANIPConnection:2", "WANIPConnection:1", "WANPPPConnection:1"]
        for service in xml.components(separatedBy: "<service>").dropFirst() {
            guard let type = tag("serviceType", in: service),
                  types.contains(where: { type.hasSuffix($0) }),
                  let path = tag("controlURL", in: service),
                  let url = URL(string: path, relativeTo: location)?.absoluteURL else { continue }
            return Control(url: url, serviceType: type)
        }
        return nil
    }

    private static func ssdpSearch() -> URL? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = UInt16(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &dest.sin_addr)
        let msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        let bytes = Array(msg.utf8)
        let sent = bytes.withUnsafeBytes { raw in
            withUnsafePointer(to: &dest) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == bytes.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        let reply = String(decoding: buf[0..<n], as: UTF8.self)
        for line in reply.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
            return URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func tag(_ name: String, in xml: String) -> String? {
        guard let open = xml.range(of: "<\(name)>"), let close = xml.range(of: "</\(name)>", range: open.upperBound..<xml.endIndex) else { return nil }
        return String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
