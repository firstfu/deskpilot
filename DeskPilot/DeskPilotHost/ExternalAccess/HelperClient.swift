//
//  HelperClient.swift
//  DeskPilotHost
//
//  管理特權 helper 的安裝與連線：用 SMAppService 註冊 LaunchDaemon（使用者要在系統設定「登入項目」核准一次），
//  再透過 XPC 呼叫。連線時綁定 helper 的程式碼簽章要求，避免連到被冒名的服務。
//

import Foundation
import Observation
import os
import ServiceManagement

@MainActor @Observable
final class HelperClient {
    enum Status: Equatable {
        case notRegistered
        case requiresApproval
        case ready(version: Int)
        case failed(String)
    }

    private(set) var status: Status = .notRegistered
    private let service = SMAppService.daemon(plistName: HelperConstants.plistName)

    func refresh() async {
        switch service.status {
        case .notRegistered, .notFound: status = .notRegistered
        case .requiresApproval: status = .requiresApproval
        case .enabled:
            do { status = .ready(version: try await fetchVersion()) } catch { status = .failed(error.localizedDescription) }
        @unknown default: status = .failed("未知狀態")
        }
    }

    /// 註冊 daemon。第一次會變成「需要核准」，由使用者到系統設定開啟。
    func install() async {
        do {
            try service.register()
        } catch {
            // 已註冊再註冊會丟錯，狀態以 service.status 為準，不當成失敗。
            if service.status == .notRegistered || service.status == .notFound {
                status = .failed(error.localizedDescription)
                return
            }
        }
        await refresh()
    }

    func uninstall() async {
        try? await service.unregister()
        await refresh()
    }

    /// App 搬了位置後，launchd 記的還是舊路徑：先取消註冊再註冊，讓它指向目前這份 App。
    func reinstall() async {
        try? await service.unregister()
        await install()
    }

    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// 通道狀態（執行中、utun 名稱、Mac 公鑰 base64）。
    func tunnelStatus() async -> (running: Bool, interface: String, publicKey: String)? {
        try? await call { proxy, done in proxy.tunnelStatus { done(($0, $1, $2)) } }
    }

    /// 啟動外網通道；元件未就緒時什麼都不做。
    @discardableResult
    func startTunnel() async -> Bool {
        guard case .ready = status else { return false }
        let r = try? await call { proxy, done in proxy.startTunnel { done(($0, $1)) } }
        if let r, !r.0 { HostController.log.error("啟動通道失敗：\(r.1, privacy: .public)") }
        return r?.0 ?? false
    }

    func setPeer(publicKey: String) async -> Bool {
        guard case .ready = status else { return false }
        let r = try? await call { proxy, done in proxy.setPeer(publicKey: publicKey) { done(($0, $1)) } }
        return r?.0 ?? false
    }

    func stopTunnel() async {
        guard case .ready = status else { return }
        _ = try? await call { proxy, done in proxy.stopTunnel { done(($0, $1)) } }
    }

    private func fetchVersion() async throws -> Int {
        try await call { proxy, done in proxy.version { done($0) } }
    }

    /// 每次呼叫開一條連線、綁定 helper 的簽章要求，用完就關。
    private func call<T>(_ body: @escaping (DeskPilotHelperProtocol, @escaping (T) -> Void) -> Void) async throws -> T {
        let connection = NSXPCConnection(machServiceName: HelperConstants.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: DeskPilotHelperProtocol.self)
        connection.setCodeSigningRequirement(HelperConstants.helperRequirement)
        connection.resume()
        defer { connection.invalidate() }
        return try await withCheckedThrowingContinuation { cont in
            let proxy = connection.remoteObjectProxyWithErrorHandler { cont.resume(throwing: $0) }
            guard let typed = proxy as? DeskPilotHelperProtocol else {
                cont.resume(throwing: CocoaError(.xpcConnectionInterrupted))
                return
            }
            body(typed) { cont.resume(returning: $0) }
        }
    }
}
