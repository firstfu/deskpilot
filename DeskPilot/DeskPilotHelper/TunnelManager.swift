//
//  TunnelManager.swift
//  DeskPilotHelper
//
//  以 root 啟停 WireGuard 通道（wireguard-go 的 utun）。位址、埠、狀態目錄全部寫死，
//  呼叫端唯一能影響的是「開或關」；金鑰由這裡產生，私鑰不離開 root 專屬目錄。
//

import CryptoKit
import Darwin
import Foundation
import Security
import os

final class TunnelManager {
    static let macAddress = "10.66.0.1"
    static let peerAddress = "10.66.0.2"
    static let listenPort = 51820
    private static let stateDir = "/var/db/deskpilot"
    private static let log = Logger(subsystem: HelperConstants.label, category: "tunnel")

    private let queue = DispatchQueue(label: "deskpilot.helper.tunnel")
    private var process: Process?
    private var interfaceName: String?

    struct Failure: Error { let message: String }

    // MARK: 對外（皆在內部序列佇列執行）

    func start() -> (Bool, String) {
        queue.sync {
            if process?.isRunning == true { return (true, "已在執行") }
            do {
                try startLocked()
                return (true, "已啟動 \(interfaceName ?? "")")
            } catch let f as Failure {
                Self.log.error("啟動失敗：\(f.message, privacy: .public)")
                stopLocked()
                return (false, f.message)
            } catch {
                stopLocked()
                return (false, error.localizedDescription)
            }
        }
    }

    func stop() -> (Bool, String) {
        queue.sync {
            stopLocked()
            return (true, "已停止")
        }
    }

    func setPeer(publicKeyBase64: String) -> (Bool, String) {
        queue.sync {
            guard let raw = Data(base64Encoded: publicKeyBase64), raw.count == 32 else { return (false, "公鑰格式不正確") }
            do {
                try ensureStateDir()
                try writePrivateFile(Self.stateDir + "/peer.pub", Data(publicKeyBase64.utf8))
                if let name = interfaceName, process?.isRunning == true { try applyPeer(interface: name, publicKey: raw) }
                return (true, "已設定")
            } catch let f as Failure { return (false, f.message) } catch { return (false, error.localizedDescription) }
        }
    }

    func removePeer() -> (Bool, String) {
        queue.sync {
            unlink(Self.stateDir + "/peer.pub")
            if let name = interfaceName, process?.isRunning == true {
                let sock = "/var/run/wireguard/\(name).sock"
                _ = try? uapi(socketPath: sock, request: "set=1\nreplace_peers=true\n\n")
            }
            return (true, "已移除")
        }
    }

    func status() -> (Bool, String, String) {
        queue.sync {
            let pub = (try? loadOrCreatePrivateKey().publicKey.rawRepresentation.base64EncodedString()) ?? ""
            return (process?.isRunning == true, interfaceName ?? "", pub)
        }
    }

    // MARK: 啟動流程

    private func startLocked() throws {
        try ensureStateDir()
        let key = try loadOrCreatePrivateKey()
        let binary = try installVerifiedBinary()

        let nameFile = Self.stateDir + "/tun.name"
        unlink(nameFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-f", "utun"]
        p.environment = ["WG_TUN_NAME_FILE": nameFile, "PATH": "/usr/bin:/bin"]
        p.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.process = nil; self?.interfaceName = nil }
        }
        do { try p.run() } catch { throw Failure(message: "無法啟動 wireguard-go：\(error.localizedDescription)") }
        process = p

        let name = try waitFor(timeout: 5) { Self.readInterfaceName(nameFile) }
        interfaceName = name
        try configureDevice(interface: name, privateKey: key)
        if let b64 = FileManager.default.contents(atPath: Self.stateDir + "/peer.pub").flatMap({ String(data: $0, encoding: .utf8) }),
           let raw = Data(base64Encoded: b64), raw.count == 32 {
            try applyPeer(interface: name, publicKey: raw)
        }
        try run("/sbin/ifconfig", [name, "inet", Self.macAddress, Self.peerAddress, "netmask", "255.255.255.255", "mtu", "1420", "up"])
        Self.log.notice("通道已啟動：\(name, privacy: .public)")
    }

    private func stopLocked() {
        if let p = process, p.isRunning {
            p.terminate()
            p.waitUntilExit()
        }
        process = nil
        interfaceName = nil
    }

    // MARK: 金鑰與二進位檔

    private func ensureStateDir() throws {
        var st = stat()
        if lstat(Self.stateDir, &st) != 0 {
            guard mkdir(Self.stateDir, 0o700) == 0 else { throw Failure(message: "無法建立狀態目錄") }
        } else if (st.st_mode & S_IFMT) != S_IFDIR || st.st_uid != 0 {
            throw Failure(message: "狀態目錄屬性不正確，拒絕使用")
        }
        chmod(Self.stateDir, 0o700)
    }

    private func loadOrCreatePrivateKey() throws -> Curve25519.KeyAgreement.PrivateKey {
        try ensureStateDir()
        let path = Self.stateDir + "/mac.key"
        if let data = FileManager.default.contents(atPath: path), data.count == 32 {
            return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        // O_EXCL + 0600：建立當下權限就正確，不會有「先建後改權限」的空窗。
        try writePrivateFile(path, key.rawRepresentation)
        return key
    }

    private func writePrivateFile(_ path: String, _ data: Data) throws {
        unlink(path)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw Failure(message: "無法寫入檔案") }
        defer { close(fd) }
        guard data.withUnsafeBytes({ write(fd, $0.baseAddress, data.count) }) == data.count else {
            throw Failure(message: "寫入檔案失敗")
        }
    }

    /// 驗簽 → 複製到 root 專屬目錄 → 對副本再驗一次。之後只執行副本，避免驗完被使用者換掉。
    private func installVerifiedBinary() throws -> String {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { throw Failure(message: "找不到 helper 路徑") }
        let source = exe.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/wireguard-go").path
        guard FileManager.default.fileExists(atPath: source) else {
            throw Failure(message: "App 內沒有 wireguard-go，請先執行 scripts/build-wireguard-go.sh 再重新 build")
        }
        try verifySignature(path: source)

        let binDir = Self.stateDir + "/bin"
        mkdir(binDir, 0o700)
        let dest = binDir + "/wireguard-go"
        unlink(dest)
        do { try FileManager.default.copyItem(atPath: source, toPath: dest) } catch {
            throw Failure(message: "複製 wireguard-go 失敗")
        }
        chmod(dest, 0o700)
        try verifySignature(path: dest)
        return dest
    }

    private func verifySignature(path: String) throws {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(HelperConstants.wireguardRequirement as CFString, [], &req) == errSecSuccess, let req
        else { throw Failure(message: "無法檢查 wireguard-go 簽章") }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), req)
        guard status == errSecSuccess else { throw Failure(message: "wireguard-go 簽章不符（\(status)），拒絕執行") }
    }

    // MARK: 設定

    private static func readInterfaceName(_ path: String) -> String? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.range(of: "^utun[0-9]+$", options: .regularExpression) != nil ? name : nil
    }

    private func waitFor<T>(timeout: TimeInterval, _ probe: () -> T?) throws -> T {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let v = probe() { return v }
            if process?.isRunning != true { throw Failure(message: "wireguard-go 提早結束") }
            usleep(100_000)
        }
        throw Failure(message: "等待 wireguard-go 就緒逾時")
    }

    /// 經 wireguard-go 的 UAPI socket 套用設定：只設私鑰與監聽埠，不放任何 peer（手機配對時才加）。
    private func configureDevice(interface: String, privateKey: Curve25519.KeyAgreement.PrivateKey) throws {
        let sock = "/var/run/wireguard/\(interface).sock"
        _ = try waitFor(timeout: 3) { FileManager.default.fileExists(atPath: sock) ? true : nil }
        let hex = privateKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
        let reply = try uapi(socketPath: sock, request: "set=1\nprivate_key=\(hex)\nlisten_port=\(Self.listenPort)\n\n")
        guard reply.contains("errno=0") else { throw Failure(message: "套用通道設定失敗") }
    }

    /// 只允許一個 peer，且只放行手機的通道位址（/32）；不接受呼叫端指定任何位址。
    private func applyPeer(interface: String, publicKey: Data) throws {
        let hex = publicKey.map { String(format: "%02x", $0) }.joined()
        let req = "set=1\nreplace_peers=true\npublic_key=\(hex)\nreplace_allowed_ips=true\nallowed_ip=\(Self.peerAddress)/32\n\n"
        let reply = try uapi(socketPath: "/var/run/wireguard/\(interface).sock", request: req)
        guard reply.contains("errno=0") else { throw Failure(message: "套用手機 peer 失敗") }
    }

    private func uapi(socketPath: String, request: String) throws -> String {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "無法建立 socket") }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw Failure(message: "socket 路徑過長") }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes.map { UInt8(bitPattern: $0) }) }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { throw Failure(message: "無法連到 wireguard-go 控制 socket") }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        let data = Array(request.utf8)
        guard write(fd, data, data.count) == data.count else { throw Failure(message: "寫入控制 socket 失敗") }
        var out = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &out, out.count)
        return n > 0 ? String(decoding: out[0..<n], as: UTF8.self) : ""
    }

    /// 只用絕對路徑、固定參數執行系統工具；介面名稱已在前面驗證過格式。
    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw Failure(message: "無法執行 \(tool)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure(message: "\(tool) 失敗（\(p.terminationStatus)）") }
    }
}
