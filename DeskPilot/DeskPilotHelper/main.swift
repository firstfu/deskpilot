//
//  main.swift
//  DeskPilotHelper
//
//  以 root 常駐的 LaunchDaemon（由 SMAppService 註冊、launchd 依 Mach 服務需要時啟動）。
//  這一層只做白名單內的特權操作，並且只接受同 Team 簽出的主機 App 連線。
//

import Foundation
import os

private let log = Logger(subsystem: HelperConstants.label, category: "helper")

private final class Service: NSObject, NSXPCListenerDelegate, DeskPilotHelperProtocol {
    static let currentVersion = 3
    private let tunnel = TunnelManager()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // 連線建立前先綁定對方的程式碼簽章要求；不符的連線在收到任何訊息前就會被系統中斷。
        connection.setCodeSigningRequirement(HelperConstants.hostRequirement)
        connection.exportedInterface = NSXPCInterface(with: DeskPilotHelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    func version(reply: @escaping (Int) -> Void) {
        reply(Self.currentVersion)
    }

    func startTunnel(reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = tunnel.start()
        reply(ok, msg)
    }

    func stopTunnel(reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = tunnel.stop()
        reply(ok, msg)
    }

    func setPeer(publicKey: String, reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = tunnel.setPeer(publicKeyBase64: publicKey)
        reply(ok, msg)
    }

    func removePeer(reply: @escaping (Bool, String) -> Void) {
        let (ok, msg) = tunnel.removePeer()
        reply(ok, msg)
    }

    func tunnelStatus(reply: @escaping (Bool, String, String) -> Void) {
        let (running, iface, pub) = tunnel.status()
        reply(running, iface, pub)
    }
}

private let service = Service()
private let listener = NSXPCListener(machServiceName: HelperConstants.label)
listener.delegate = service
listener.resume()
log.notice("helper 啟動，版本 \(Service.currentVersion, privacy: .public)")
RunLoop.main.run()
