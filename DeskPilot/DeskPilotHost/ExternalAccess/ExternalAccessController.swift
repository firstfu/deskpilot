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
        if let old = defaults.string(forKey: Self.lastIPKey), old != ip {
            publicIPChanged = true
            Self.log.notice("公網位址已變更")
        }
        defaults.set(ip, forKey: Self.lastIPKey)
    }
}
