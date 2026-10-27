//
//  ExternalAccessController.swift
//  DeskPilotHost
//
//  外網連線的狀態機：使用者開啟後，定期向路由器登記/續約 WireGuard 的 UDP 埠，
//  再判斷從外網能不能直連，並把結果（含公網 IP 變動）交給 UI。
//  這一層不需要特權；建立通道本身由特權 helper 負責（之後接上）。
//

import Foundation
import Observation
import os

@MainActor @Observable
final class ExternalAccessController {
    enum State: Equatable {
        case off
        case checking
        case ready(publicIP: String, method: PortMapping.Method?)
        /// 路由器不支援自動開埠，但公網位址可用，使用者需手動轉發。
        case needsManualForward(publicIP: String)
        case blockedByNAT(routerIP: String)
        case offline
        case failed(String)
    }

    static let listenPort: UInt16 = 51820
    private static let enabledKey = "externalAccessEnabled"
    private static let lastIPKey = "externalAccessLastPublicIP"
    private static let log = Logger(subsystem: "tw.firstfu.DeskPilotHost", category: "external")

    private(set) var state: State = .off
    /// 公網位址自上次成功後換過；手機若用 IP 直連就必須更新。
    private(set) var publicIPChanged = false

    /// 用 @Observable 儲存屬性（而不是直接讀 UserDefaults），選單的勾選才會即時更新。
    private(set) var isEnabled = UserDefaults.standard.bool(forKey: "externalAccessEnabled")

    enum DDNSStatus: Equatable {
        case notConfigured
        case updating
        case ok
        case failed(String)
    }

    private static let ddnsHostKey = "externalAccessDDNSHostname"
    /// 使用者在 Cloudflare 的主機名稱；有設定且最近一次更新成功時，QR code 改用它當 Endpoint。
    private(set) var ddnsHostname = UserDefaults.standard.string(forKey: "externalAccessDDNSHostname") ?? ""
    private(set) var ddnsStatus: DDNSStatus = .notConfigured

    /// 手機該連的位址：DDNS 可用時是主機名稱，否則是公網 IP。
    var endpointHost: String? {
        switch state {
        case .ready(let ip, _), .needsManualForward(let ip):
            return ddnsStatus == .ok && !ddnsHostname.isEmpty ? ddnsHostname : ip
        default: return nil
        }
    }

    private var loop: Task<Void, Never>?
    /// 特權 helper；就緒時，外網開關同時負責啟停 WireGuard 通道。
    var helper: HelperClient?

    func start() {
        guard isEnabled, loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.helper?.startTunnel()
                await self?.refresh()
                // 租約 1 小時，每 10 分鐘續約並重新檢查，IP 變動也能在這個粒度內發現。
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    func setEnabled(_ on: Bool) {
        isEnabled = on
        UserDefaults.standard.set(on, forKey: Self.enabledKey)
        if on {
            start()
        } else {
            loop?.cancel()
            loop = nil
            state = .off
            publicIPChanged = false
            Task {
                await PortMapper.unmap(port: Self.listenPort)
                await helper?.stopTunnel()
            }
        }
    }

    func acknowledgeIPChange() { publicIPChanged = false }

    /// 儲存 DDNS 設定；空的主機名稱代表停用並清掉 Token。回傳錯誤訊息，成功為 nil。
    func configureDDNS(hostname: String, token: String) async -> String? {
        let name = hostname.trimmingCharacters(in: .whitespaces).lowercased()
        if name.isEmpty {
            DDNSKeychain.deleteToken()
            UserDefaults.standard.removeObject(forKey: Self.ddnsHostKey)
            ddnsHostname = ""
            ddnsStatus = .notConfigured
            return nil
        }
        guard CloudflareDDNS.isValidHostname(name) else { return DDNSError.invalidHostname.localizedDescription }
        let tok = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // 留空代表沿用鑰匙圈裡已存的 Token
        guard let useToken = tok.isEmpty ? DDNSKeychain.loadToken() : tok else { return "請輸入 API Token" }
        guard let ip = await Reachability.fetchPublicIP() else { return "查不到公網 IP，請確認網路" }
        do {
            try await CloudflareDDNS.update(hostname: name, ip: ip, token: useToken)
        } catch {
            return error.localizedDescription
        }
        if !tok.isEmpty { DDNSKeychain.saveToken(tok) }
        UserDefaults.standard.set(name, forKey: Self.ddnsHostKey)
        ddnsHostname = name
        ddnsStatus = .ok
        publicIPChanged = false
        return nil
    }

    private func updateDDNS(ip: String) async {
        guard !ddnsHostname.isEmpty, let token = DDNSKeychain.loadToken() else { return }
        ddnsStatus = .updating
        do {
            try await CloudflareDDNS.update(hostname: ddnsHostname, ip: ip, token: token)
            ddnsStatus = .ok
        } catch {
            Self.log.error("DDNS 更新失敗：\(error.localizedDescription, privacy: .public)")
            ddnsStatus = .failed(error.localizedDescription)
        }
    }

    private func refresh() async {
        state = .checking
        var mapping: PortMapping?
        var mapError: Error?
        do { mapping = try await PortMapper.map(port: Self.listenPort) } catch { mapError = error }

        let result = await Reachability.evaluate(mapping: mapping)
        Self.log.notice("外網檢查：開埠=\(mapping?.method.rawValue ?? "失敗", privacy: .public) 結果=\(String(describing: result), privacy: .private)")
        switch result {
        case .offline:
            state = .offline
        case .behindNAT(let router, _):
            state = .blockedByNAT(routerIP: router)
        case .direct(let ip):
            await updateDDNS(ip: ip)
            noteIP(ip)
            if mapping == nil {
                Self.log.notice("自動開埠失敗：\(mapError?.localizedDescription ?? "未知", privacy: .public)")
                state = .needsManualForward(publicIP: ip)
            } else {
                state = .ready(publicIP: ip, method: mapping?.method)
            }
        }
    }

    private func noteIP(_ ip: String) {
        let defaults = UserDefaults.standard
        // DDNS 已把名稱指到新 IP，手機不必更新
        if let old = defaults.string(forKey: Self.lastIPKey), old != ip, ddnsStatus != .ok {
            publicIPChanged = true
            Self.log.notice("公網位址已變更")
        }
        defaults.set(ip, forKey: Self.lastIPKey)
    }
}
