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

            if !controller.accessibilityGranted {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("需要「輔助使用」權限才能讓手機控制滑鼠與鍵盤。")
                        Button("開啟權限設定") { controller.requestAccessibility() }
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("畫面靜止時不傳任何影像資料，流量會降到 0。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { controller.start() }
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
