//
//  DeskPilotHostApp.swift
//  DeskPilotHost
//
//  macOS 主機端入口：選單列 App（沒有 Dock 圖示），讓手機透過區網或 Cloudflare Tunnel 控制這台電腦。
//  主視窗平常不開；缺權限、有配對請求時才自動跳出來。
//

import os
import ServiceManagement
import SwiftUI

@main
struct DeskPilotHostApp: App {
    @State private var controller = HostController()

    var body: some Scene {
        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            MenuBarIcon(controller: controller)
        }

        Window("DeskPilot 主機", id: "main") {
            ContentView(controller: controller)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

/// 選單列圖示。它在 App 啟動時就會建立，所以順便負責啟動主機與「該不該把視窗叫出來」。
private struct MenuBarIcon: View {
    let controller: HostController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: symbol)
            .task {
                controller.start()
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
}
