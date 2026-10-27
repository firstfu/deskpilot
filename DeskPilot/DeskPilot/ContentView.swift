//
//  ContentView.swift
//  DeskPilot（iOS 用戶端）
//
//  兩個畫面：區網主機清單 → 遠端操作畫面（含浮動工具列與即時統計）。
//

import Network
import SwiftUI

struct ContentView: View {
    @State private var session = ClientSession()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if session.desktopSize != nil {
                RemoteScreen(session: session)
            } else {
                HostListScreen(session: session)
            }
        }
        .onAppear { session.startBrowsing() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { session.appBecameActive() }
        }
    }
}

/// 主機清單。
struct HostListScreen: View {
    let session: ClientSession
    /// 上次手動輸入的位址（例如 WireGuard 通道裡的 Mac：10.66.0.1）。
    @AppStorage("manualHostAddress") private var manualAddress = "10.66.0.1"

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

                Section {
                    HStack {
                        TextField("IP 位址", text: $manualAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("連線") {
                            let addr = manualAddress.trimmingCharacters(in: .whitespaces)
                            guard !addr.isEmpty else { return }
                            let host = DiscoveredHost(name: addr,
                                                      endpoint: .hostPort(host: NWEndpoint.Host(addr),
                                                                          port: NWEndpoint.Port(rawValue: ProtocolConstants.port)!),
                                                      hostID: nil)
                            session.connect(to: host, viewPixels: Self.screenPixels)
                        }
                    }
                } header: {
                    Text("在外面（透過 WireGuard）")
                } footer: {
                    Text("先打開 WireGuard App，再輸入 Mac 的通道位址連線。第一次配對必須在同一個 Wi-Fi 下完成。")
                }

                if case .connecting(let name) = session.state {
                    Section { Label("正在連線到 \(name)…", systemImage: "antenna.radiowaves.left.and.right") }
                }
                if case .pairing(let name, let code) = session.state {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("第一次連線到 \(name)，請在 Mac 上確認數字一致後按「允許」：")
                            Text(code.prefix(3) + " " + code.suffix(3))
                                .font(.system(size: 34, weight: .bold, design: .monospaced))
                        }
                    } footer: {
                        Text("數字不一致就在 Mac 上按「拒絕」，可能有人在攔截連線。")
                    }
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
    @State private var showShortcuts = false
    @State private var showStats = true

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RemoteSurface(session: session, keyboardVisible: $keyboardVisible)
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 8) {
                    if session.displayCount > 1 {
                        toolButton("display.2", active: false) { session.cycleDisplay() }
                    }
                    toolButton("keyboard", active: keyboardVisible) { keyboardVisible.toggle() }
                    toolButton("command", active: showShortcuts || !session.armedModifiers.isEmpty) { showShortcuts.toggle() }
                    moreMenu
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
                if let status = session.benchmarkStatus {
                    panel(status)
                } else if let result = session.benchmarkResult {
                    panel(result)
                        .onTapGesture { session.benchmarkResult = nil }
                }
            }
            .padding(10)
        }
        // 快捷鍵列放在底部：鍵盤出現時 SwiftUI 會自動把它推到鍵盤上方
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showShortcuts { ShortcutBar(session: session) }
        }
        .overlay(alignment: .center) {
            if case .reconnecting = session.state {
                Label("連線中斷，重新連線中…", systemImage: "arrow.triangle.2.circlepath")
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
            } else if let toast = session.toast {
                Text(toast)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.75), in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
    }

    /// 不常用的功能收進選單，工具列才不會擠。
    private var moreMenu: some View {
        Menu {
            // 用文字直接標示開／關：選單裡同時有省流量的選項與顯示統計的打勾，單靠打勾容易看錯是哪一項
            Button {
                session.setAudio(!session.audioEnabled)
            } label: {
                Label(session.audioEnabled ? "聲音：開（點一下關閉）" : "聲音：關（點一下開啟）",
                      systemImage: session.audioEnabled ? "speaker.wave.2.fill" : "speaker.slash")
            }
            Picker("省流量模式", selection: Binding(get: { session.saverPreference },
                                                    set: { session.setSaverPreference($0) })) {
                ForEach(ClientSession.SaverPreference.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Toggle(isOn: $showStats) { Label("顯示統計", systemImage: "chart.bar") }
            Button { Task { await session.runBenchmark() } } label: {
                Label("量測延遲與流量", systemImage: "speedometer")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(.white)
                .background(Color.black.opacity(0.55), in: Circle())
        }
    }

    private var statsText: String {
        let rtt = session.rttMs.map { String(format: "%.0f ms", $0) } ?? "— ms"
        let rate = session.kbps >= 1000 ? String(format: "%.1f Mbps", session.kbps / 1000)
                                        : String(format: "%.0f kbps", session.kbps)
        let saver = session.saverShouldBeOn ? " · 省流量" : ""
        return "\(session.fps) fps · \(rate) · RTT \(rtt) · \(String(format: "%.1f MB", session.totalMB))\(saver)"
    }

    /// 量測進度／結果面板（點一下結果可關閉）。
    private func panel(_ text: String) -> some View {
        Text(text)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.leading)
            .padding(10)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 10))
            .foregroundStyle(.white)
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
