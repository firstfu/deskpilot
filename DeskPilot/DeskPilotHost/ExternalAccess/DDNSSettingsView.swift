//
//  DDNSSettingsView.swift
//  DeskPilotHost
//
//  設定 Cloudflare 主機名稱與 API Token，讓 QR code 記名稱而不是會變動的公網 IP。
//

import SwiftUI

struct DDNSSettingsView: View {
    let external: ExternalAccessController
    @State private var hostname = ""
    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("固定網域（Cloudflare）").font(.headline)
            Text("公網 IP 會不定時變動。填入你放在 Cloudflare 的網域名稱後，DeskPilot 會自動把它指向目前的 IP，手機配對一次就不必再更新。")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            TextField("主機名稱，例如 mac.example.com", text: $hostname)
                .textFieldStyle(.roundedBorder)
            SecureField(external.ddnsHostname.isEmpty ? "API Token" : "API Token（留空沿用已儲存的）", text: $token)
                .textFieldStyle(.roundedBorder)
            Text("Token 在 Cloudflare 後台建立，權限選「區域 › DNS › 編輯」，範圍只選這個網域。Token 只存在這台 Mac 的鑰匙圈。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            if saved { Text("已儲存。若手機已用舊的 QR code 配對，請重新產生一次。").font(.callout).foregroundStyle(.green) }
            if case .failed(let msg) = external.ddnsStatus { Text("最近一次更新失敗：\(msg)").font(.caption).foregroundStyle(.orange) }

            HStack {
                Button("清除設定", role: .destructive) { save(clear: true) }
                    .disabled(external.ddnsHostname.isEmpty || busy)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("儲存並測試") { save(clear: false) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(hostname.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            }
        }
        .padding(24)
        .frame(width: 400)
        .onAppear { hostname = external.ddnsHostname }
    }

    private func save(clear: Bool) {
        busy = true; error = nil; saved = false
        Task {
            let err = await external.configureDDNS(hostname: clear ? "" : hostname, token: token)
            busy = false
            error = err
            if err == nil {
                saved = !clear
                token = ""
                if clear { hostname = "" }
            }
        }
    }
}
