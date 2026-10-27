//
//  DeskPilotHostApp.swift
//  DeskPilotHost
//
//  macOS 主機端入口：選單列 App（沒有 Dock 圖示），讓手機透過區網或通道控制這台電腦。
//  主視窗平常不開；缺權限、有配對請求時才自動跳出來。
//

import os
import ServiceManagement
import SwiftUI

@main
struct DeskPilotHostApp: App {
    @State private var controller = HostController()
    @State private var external = ExternalAccessController()
    @State private var helper = HelperClient()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller, external: external, helper: helper)
        } label: {
            MenuBarIcon(controller: controller, external: external, helper: helper)
        }

        Window("DeskPilot 主機", id: "main") {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("固定網域", id: "ddns") {
            DDNSSettingsView(external: external)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)

        Window("配對手機", id: "pair") {
            PairingView(helper: helper, external: external)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// 選單列圖示。它在 App 啟動時就會建立，所以順便負責啟動主機與「該不該把視窗叫出來」。
private struct MenuBarIcon: View {
    let controller: HostController
    let external: ExternalAccessController
    let helper: HelperClient
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .task {
                controller.start()
                await helper.refresh()
                external.helper = helper
                external.start()
                // 缺權限（通常是第一次使用）或指定要看視窗（量測用）時，啟動就打開主視窗
                if !controller.permissionsOK || ProcessInfo.processInfo.environment["DESKPILOT_SHOW_WINDOW"] != nil {
                    showWindow()
                }
            }
            .onChange(of: controller.pairRequest?.id) { _, id in
                // 手機要求配對：使用者必須看到確認碼，視窗不在就叫出來
                if id != nil { showWindow() }
            }
    }

    private var symbol: String {
        if !controller.permissionsOK { return "exclamationmark.triangle" }
        if case .connected = controller.status { return "display.and.arrow.down" }
        return "display"
    }

    private func showWindow() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

private struct MenuContent: View {
    let controller: HostController
    let external: ExternalAccessController
    let helper: HelperClient
    @Environment(\.openWindow) private var openWindow
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Text(statusText)
        if !controller.permissionsOK {
            Text(controller.needsRelaunch ? "需要重新啟動才能套用權限" : "尚未完成權限設定")
        }
        Divider()
        Button("顯示主視窗") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Toggle("開機時自動啟動", isOn: $launchAtLogin)
            .onChange(of: launchAtLogin) { _, on in
                do {
                    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    HostController.log.error("設定開機自動啟動失敗：\(error.localizedDescription, privacy: .public)")
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        Toggle("外網連線（自動開埠）", isOn: Binding(get: { external.isEnabled }, set: { external.setEnabled($0) }))
        if external.isEnabled { Text(externalText) }
        if external.publicIPChanged {
            Button("公網位址已變更，手機需更新（按此確認）") { external.acknowledgeIPChange() }
        }
        if external.isEnabled {
            Button(external.ddnsHostname.isEmpty ? "設定固定網域（Cloudflare）…" : "固定網域：\(external.ddnsHostname)…") {
                openWindow(id: "ddns")
                NSApp.activate()
            }
        }
        helperItems
        Divider()
        Button("結束 DeskPilot") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var statusText: String {
        switch controller.status {
        case .idle: "啟動中…"
        case .listening: "等待手機連線"
        case .connected(let name): "已連線：\(name)"
        case .failed(let msg): "錯誤：\(msg)"
        }
    }

    @ViewBuilder private var helperItems: some View {
        switch helper.status {
        case .notRegistered:
            Button("安裝外網通道元件…") { Task { await helper.install() } }
        case .requiresApproval:
            Button("到系統設定核准通道元件…") { helper.openApprovalSettings() }
        case .ready(let v):
            Text("通道元件已就緒（v\(v)）")
            Button("配對手機（外網）…") {
                openWindow(id: "pair")
                NSApp.activate()
            }
            .disabled(!external.isEnabled)
            Button("重新安裝通道元件（App 搬位置後用）") { Task { await helper.reinstall() } }
        case .failed(let msg):
            Text("通道元件錯誤：\(msg)")
            Button("重新安裝通道元件") { Task { await helper.install() } }
        }
    }

    private var externalText: String {
        switch external.state {
        case .off: "已關閉"
        case .checking: "檢查中…"
        case .ready(let ip, let method): "可從外網連入：\(ip)（\(method?.rawValue ?? "手動")）"
        case .needsManualForward(let ip): "請在路由器手動轉發 UDP \(ExternalAccessController.listenPort)（公網 \(ip)）"
        case .blockedByNAT: "你的網路沒有公網 IP（營運商或上層路由器有 NAT），外網直連不可用"
        case .offline: "無法連到網際網路"
        case .failed(let msg): "錯誤：\(msg)"
        }
    }
}
