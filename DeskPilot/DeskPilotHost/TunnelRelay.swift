//
//  TunnelRelay.swift
//  DeskPilotHost
//
//  把 WireGuard 通道（utun 介面）上的連線轉給本機的 NWListener。
//  為什麼需要：Homebrew 版 wireguard-go 建的 utun 介面不會登記到系統網路設定，Network.framework 完全看不到它，
//  NWListener 不會在上面收連線（手機從外面連進來表現是「連線中斷」）。一般 BSD socket 則照常可用，
//  所以在通道位址上開一個 BSD 監聽，收到後原封不動轉到 127.0.0.1。加密與驗證仍由 DeskPilot 協定本身負責，這裡只搬 bytes。
//

import Darwin
import Foundation
import os

final class TunnelRelay: @unchecked Sendable {
    private let port: UInt16
    private let queue = DispatchQueue(label: "deskpilot.relay", qos: .userInteractive)
    /// 已在監聽的通道位址 → 監聽 socket 的事件來源。
    private var listeners: [String: DispatchSourceRead] = [:]
    private var scanTimer: DispatchSourceTimer?

    init(port: UInt16) { self.port = port }

    /// 開始定期掃描 utun 介面：WireGuard 可能比主機晚啟動，也可能中途重啟換位址。
    func start() {
        guard scanTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .seconds(10))
        t.setEventHandler { [weak self] in self?.rescan() }
        t.resume()
        scanTimer = t
    }

    private func rescan() {
        let current = Set(Self.tunnelAddresses())
        for (addr, src) in listeners where !current.contains(addr) {
            src.cancel()
            listeners[addr] = nil
        }
        for addr in current where listeners[addr] == nil {
            if let src = listen(on: addr) {
                listeners[addr] = src
                HostController.log.notice("通道轉接：監聽 \(addr, privacy: .public):\(self.port, privacy: .public)")
            }
        }
    }

    /// utun 介面上的 IPv4 位址（WireGuard 通道用私有 IPv4）。
    private static func tunnelAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var p = head
        while let ifa = p {
            defer { p = ifa.pointee.ifa_next }
            guard String(cString: ifa.pointee.ifa_name).hasPrefix("utun"),
                  let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                _ = inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
            }
            out.append(String(cString: buf))
        }
        return out
    }

    private static func address(_ ip: String, _ port: UInt16) -> sockaddr_in {
        var sin = sockaddr_in()
        sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sin.sin_family = sa_family_t(AF_INET)
        sin.sin_port = port.bigEndian
        inet_pton(AF_INET, ip, &sin.sin_addr)
        return sin
    }

    private func listen(on ip: String) -> DispatchSourceRead? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        // NWListener 已綁在萬用位址的同一個埠；綁「特定位址」需要 SO_REUSEADDR，核心會優先把這個位址的連線交給我們
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var sin = Self.address(ip, port)
        let bound = withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            HostController.log.error("通道轉接：無法監聽 \(ip, privacy: .public)，errno \(errno, privacy: .public)")
            close(fd)
            return nil
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            // accept 出來的 socket 會繼承監聽 socket 的 O_NONBLOCK；轉送迴圈用阻塞讀寫，
            // 不清掉的話第一次讀不到資料就回 EAGAIN，會被當成對方關閉而把兩邊都切斷
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            self?.relay(client)
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        return src
    }

    /// 接一條到本機 NWListener 的連線，兩邊互相轉送直到任一端關閉。
    private func relay(_ client: Int32) {
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var sin = Self.address("127.0.0.1", port)
        let ok = upstream >= 0 && withUnsafePointer(to: &sin) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard ok else {
            close(client)
            if upstream >= 0 { close(upstream) }
            return
        }
        // 輸入事件只有幾 bytes，關掉 Nagle，否則每次轉接都多等 40 ms
        var on: Int32 = 1
        for fd in [client, upstream] {
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        let closed = OSAllocatedUnfairLock(initialState: false)
        let shutdownBoth = {
            guard !closed.withLock({ let c = $0; $0 = true; return c }) else { return }
            close(client)
            close(upstream)
        }
        // 兩個方向各一條執行緒：迴圈會阻塞在 read，放同一個序列佇列的話第二個方向永遠輪不到
        for (from, to) in [(client, upstream), (upstream, client)] {
            let t = Thread {
                var buf = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let n = read(from, &buf, buf.count)
                    guard n > 0 else { break }
                    var sent = 0
                    while sent < n {
                        let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + sent, n - sent) }
                        guard w > 0 else { shutdownBoth(); return }
                        sent += w
                    }
                }
                shutdownBoth()
            }
            t.qualityOfService = .userInteractive
            t.start()
        }
    }
}
