//
//  ContentView.swift
//  DeskPilotHost
//
//  主機狀態視窗：連線狀態、權限、即時流量統計。
//

import SwiftUI

struct ContentView: View {
    @State var controller: HostController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusText).font(.headline)
            }

            if let req = controller.pairRequest {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("「\(req.deviceName)」要求配對").font(.headline)
                        Text("確認手機上顯示的數字和這裡一樣，才按允許：")
                        Text(req.code.prefix(3) + " " + req.code.suffix(3))
                            .font(.system(size: 34, weight: .bold, design: .monospaced))
                        HStack {
                            Button("拒絕", role: .cancel) { controller.answerPairRequest(false) }
                            Button("允許") { controller.answerPairRequest(true) }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if !controller.permissionsOK {
                GroupBox("第一次使用：開啟兩項權限") {
                    VStack(alignment: .leading, spacing: 10) {
                        permissionRow("螢幕與系統錄音", "讓手機看到你的畫面", granted: controller.screenGranted,
                                      pane: "Privacy_ScreenCapture")
                        permissionRow("輔助使用", "讓手機控制滑鼠與鍵盤", granted: controller.accessibilityGranted,
                                      pane: "Privacy_Accessibility") { controller.requestAccessibility() }
                        if controller.needsRelaunch {
                            Divider()
                            Text("螢幕錄製已授權，重新啟動 DeskPilot 後才會生效。").font(.footnote)
                            Button("立即重新啟動") { controller.relaunch() }
                        } else {
                            Text("在系統設定裡把 DeskPilotHost 的開關打開，這裡會自動更新。").font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let err = controller.lastError {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("無法擷取畫面：\(err)").foregroundStyle(.red)
                        Text("請到「系統設定 › 隱私權與安全性 › 螢幕與系統錄音」允許 DeskPilotHost，然後重新開啟本 App。")
                            .font(.footnote)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox("即時統計") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                    GridRow { Text("影格率"); Text("\(controller.fps) fps").monospacedDigit() }
                    GridRow { Text("流量"); Text(String(format: "%.0f kbps", controller.kbps)).monospacedDigit() }
                    GridRow { Text("累計"); Text(String(format: "%.2f MB", controller.totalMB)).monospacedDigit() }
                    GridRow { Text("編碼"); Text(controller.codecName.isEmpty ? "—" : "\(controller.codecName) \(controller.videoSize)") }
                    GridRow { Text("編碼耗時"); Text(String(format: "%.1f ms", controller.encodeMs)).monospacedDigit() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            GroupBox("已配對的手機") {
                VStack(alignment: .leading, spacing: 6) {
                    if controller.pairedDevices.isEmpty {
                        Text("尚無。手機第一次連線時會要求配對。").foregroundStyle(.secondary)
                    }
                    ForEach(controller.pairedDevices) { d in
                        HStack {
                            Text(d.name)
                            Spacer()
                            Button("移除") { controller.removePairedDevice(d.id) }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 延遲探針標記：手機量延遲時每個探針換一次顏色，製造畫面變化。量測時本視窗需在螢幕上可見
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(controller.probeMarker % 2 == 0 ? Color.blue : Color.orange)
                    .frame(width: 28, height: 28)
                Text("延遲探針 #\(controller.probeMarker)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text("畫面靜止時不傳任何影像資料，流量會降到 0。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
    }

    private func permissionRow(_ title: String, _ detail: String, granted: Bool, pane: String,
                               request: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("開啟設定") {
                    request?()
                    controller.openPrivacySettings(pane)
                }
            }
        }
    }

    private var statusText: String {
        switch controller.status {
        case .idle: "啟動中…"
        case .listening: "等待手機連線"
        case .connected(let name): "已連線：\(name)"
        case .failed(let msg): "錯誤：\(msg)"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .connected: .green
        case .listening: .orange
        case .failed: .red
        case .idle: .gray
        }
    }
}
