//
//  HelperProtocol.swift
//  Shared
//
//  Mac 主機 App 與特權 helper（root 的 LaunchDaemon）之間的 XPC 介面。
//  刻意只放「無參數或固定格式參數」的方法：helper 不接收路徑、指令字串或整份設定檔，
//  否則 root 行程等於替呼叫者開了提權後門。
//

import Foundation

enum HelperConstants {
    /// launchd 的 Label，同時是 Mach 服務名稱與 helper 的程式碼簽章識別。
    static let label = "tw.firstfu.DeskPilotHost.helper"
    /// 放在 App bundle `Contents/Library/LaunchDaemons/` 的 plist 檔名（SMAppService 用）。
    static let plistName = "tw.firstfu.DeskPilotHost.helper.plist"
    static let hostBundleID = "tw.firstfu.DeskPilotHost"
    static let teamID = "WY468E45SJ"

    /// helper 只接受「同 Team 簽出的主機 App」連線。
    static let hostRequirement =
        "identifier \"\(hostBundleID)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    static let wireguardIdentifier = "tw.firstfu.DeskPilotHost.wireguard-go"
    /// helper 只執行「同 Team 簽出的 wireguard-go」。
    static let wireguardRequirement =
        "identifier \"\(wireguardIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
    /// 主機 App 只信任「同 Team 簽出的 helper」。
    static let helperRequirement =
        "identifier \"\(label)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""
}

@objc protocol DeskPilotHelperProtocol {
    /// helper 版本，用來確認連到的是預期的實作。
    func version(reply: @escaping (Int) -> Void)
    /// 啟動外網通道（位址、埠固定，由 helper 決定）。reply：成功與否、說明。已在執行時直接回成功。
    func startTunnel(reply: @escaping (Bool, String) -> Void)
    func stopTunnel(reply: @escaping (Bool, String) -> Void)
    /// 設定唯一的手機 peer（只收公鑰，base64 且必須是 32 bytes；位址固定 10.66.0.2/32）。新的會取代舊的。
    func setPeer(publicKey: String, reply: @escaping (Bool, String) -> Void)
    func removePeer(reply: @escaping (Bool, String) -> Void)
    /// reply：是否執行中、utun 介面名稱（沒有則空字串）、Mac 公鑰（base64，尚未產生則空字串）。
    func tunnelStatus(reply: @escaping (Bool, String, String) -> Void)
}
