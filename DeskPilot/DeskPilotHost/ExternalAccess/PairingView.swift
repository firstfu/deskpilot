//
//  PairingView.swift
//  DeskPilotHost
//
//  手機配對：Mac 當場產生手機的金鑰對，只把「公鑰」交給 helper，私鑰只存在 QR code 裡。
//  關掉視窗就清掉，Mac 這邊不保存手機私鑰；要重新配對就重新產生（舊手機隨即失效）。
//

import CoreImage.CIFilterBuiltins
import CryptoKit
import Observation
import SwiftUI

@MainActor @Observable
final class PairingModel {
    private(set) var qr: NSImage?
    private(set) var message = "準備中…"

    func generate(helper: HelperClient, external: ExternalAccessController) async {
        qr = nil
        let host: String
        switch external.state {
        case .ready(let ip, _), .needsManualForward(let ip): host = ip
        default:
            message = "外網連線尚未就緒，請先開啟選單裡的「外網連線」並等狀態顯示可連入。"
            return
        }
        guard await helper.startTunnel(), let st = await helper.tunnelStatus(), !st.publicKey.isEmpty else {
            message = "通道元件尚未就緒，無法產生金鑰。"
            return
        }
        let phone = Curve25519.KeyAgreement.PrivateKey()
        guard await helper.setPeer(publicKey: phone.publicKey.rawRepresentation.base64EncodedString()) else {
            message = "設定手機金鑰失敗。"
            return
        }
        let config = """
        [Interface]
        PrivateKey = \(phone.rawRepresentation.base64EncodedString())
        Address = \(TunnelAddresses.phone)/32

        [Peer]
        PublicKey = \(st.publicKey)
        AllowedIPs = \(TunnelAddresses.mac)/32
        Endpoint = \(host):\(ExternalAccessController.listenPort)
        PersistentKeepalive = 25
        """
        guard let image = Self.makeQR(config) else { message = "產生 QR code 失敗。"; return }
        qr = image
        message = "用手機的官方 WireGuard App 掃描（新增通道 → 從 QR code 建立）。"
    }

    func clear() { qr = nil; message = "已關閉，需要時請重新開啟。" }

    private static func makeQR(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let out = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

enum TunnelAddresses {
    static let mac = "10.66.0.1"
    static let phone = "10.66.0.2"
}

struct PairingView: View {
    let helper: HelperClient
    let external: ExternalAccessController
    @State private var model = PairingModel()

    var body: some View {
        VStack(spacing: 14) {
            if let qr = model.qr {
                Image(nsImage: qr).interpolation(.none).resizable().frame(width: 300, height: 300)
            } else {
                ProgressView().frame(width: 300, height: 300)
            }
            Text(model.message).font(.callout).multilineTextAlignment(.center).frame(width: 300)
            Text("這個 QR code 內含手機的私鑰，請勿截圖或分享。關閉視窗後 Mac 不會保留它；重新產生會讓先前配對的手機失效。")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 300)
            Button("重新產生") { Task { await model.generate(helper: helper, external: external) } }
        }
        .padding(24)
        .task { await model.generate(helper: helper, external: external) }
        .onDisappear { model.clear() }
    }
}
