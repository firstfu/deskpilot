//
//  ContentView.swift
//  DeskPilot（iOS 用戶端）
//
//  兩個畫面：區網主機清單 → 遠端操作畫面（含浮動工具列與即時統計）。
//

import SwiftUI

struct ContentView: View {
    @State private var session = ClientSession()

    var body: some View {
        Group {
            if session.desktopSize != nil {
                RemoteScreen(session: session)
            } else {
                HostListScreen(session: session)
            }
        }
        .onAppear { session.startBrowsing() }
    }
}

/// 主機清單。
struct HostListScreen: View {
    let session: ClientSession

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if session.hosts.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("正在搜尋區網內的電腦…")
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(session.hosts) { host in
                        Button {
                            session.connect(to: host, viewPixels: Self.screenPixels)
                        } label: {
                            Label(host.name, systemImage: "desktopcomputer")
                        }
                    }
                } footer: {
                    Text("請在電腦上開啟 DeskPilot 主機，並確認手機與電腦在同一個 Wi-Fi。")
                }

                if case .connecting(let name) = session.state {
                    Section { Label("正在連線到 \(name)…", systemImage: "antenna.radiowaves.left.and.right") }
                }
                if case .failed(let msg) = session.state {
                    Section { Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
                }
            }
            .navigationTitle("DeskPilot")
        }
    }

    /// 手機螢幕原生像素大小，主機會以此為編碼解析度上限。
    private static var screenPixels: CGSize {
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.screen.nativeBounds.size ?? CGSize(width: 2556, height: 1179)
    }
}

/// 遠端操作畫面。
struct RemoteScreen: View {
    let session: ClientSession
    @State private var keyboardVisible = false
    @State private var commandArmed = false
    @State private var showStats = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RemoteSurface(session: session, keyboardVisible: $keyboardVisible, commandArmed: $commandArmed)
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    toolButton("keyboard", active: keyboardVisible) { keyboardVisible.toggle() }
                    toolButton("command", active: commandArmed) { commandArmed.toggle() }
                    toolButton("escape", active: false) { session.tapKey(MacKeyCode.escape) }
                    toolButton("arrow.right.to.line", active: false) { session.tapKey(MacKeyCode.tab) }
                    toolButton("chart.bar", active: showStats) { showStats.toggle() }
                    toolButton("xmark", active: false) { session.disconnect() }
                }
                if showStats {
                    Text(statsText)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(10)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    private var statsText: String {
        let rtt = session.rttMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
        let rate = session.kbps >= 1000 ? String(format: "%.1f Mbps", session.kbps / 1000)
                                        : String(format: "%.0f kbps", session.kbps)
        return "\(session.fps) fps · \(rate) · RTT \(rtt) · \(String(format: "%.1f MB", session.totalMB))"
    }

    private func toolButton(_ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? .black : .white)
                .background(active ? Color.white : Color.black.opacity(0.55), in: Circle())
        }
        .buttonStyle(.plain)
    }
}
