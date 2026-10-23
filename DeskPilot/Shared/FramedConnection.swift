//
//  FramedConnection.swift
//  DeskPilot 共用（主機 macOS ／ 用戶端 iOS 兩邊都編譯）
//
//  把 Network.framework 的 TCP 位元組流切成協定訊息框，並統計流量與傳送中的影格數。
//  v0 先全部走 TCP：區網掉包極少，換來實作簡單；之後影像改走 UDP + FEC 時只需替換這層。
//

import Foundation
import Network
import os

final class FramedConnection: @unchecked Sendable {
    /// 流量與傳送狀態的快照。
    struct Stats {
        var bytesSent: UInt64 = 0
        var bytesReceived: UInt64 = 0
        /// 已交給 socket 但還沒送完的影格數，用來做背壓（見 `sendVideo`）。
        var videoFramesInFlight = 0
    }

    let connection: NWConnection
    private let queue: DispatchQueue
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    /// 收到完整訊息時呼叫（在 `queue` 上）。
    var onMessage: ((MessageType, Data) -> Void)?
    /// 連線狀態改變時呼叫（在 `queue` 上）。
    var onStateChange: ((NWConnection.State) -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// 兩端共用的 TCP 參數。
    /// 關掉 Nagle（noDelay）：輸入事件只有幾 bytes，被 Nagle 攢著等於白白多 40ms 延遲。
    static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        return params
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: queue)
        receiveHeader()
    }

    func cancel() {
        connection.cancel()
    }

    var currentStats: Stats { stats.withLock { $0 } }

    /// 送出一般訊息。
    func send(_ type: MessageType, _ payload: Data = Data()) {
        let frame = Self.frame(type, payload)
        stats.withLock { $0.bytesSent += UInt64(frame.count) }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// 送出影格，並追蹤「已送出但未完成」的數量。
    /// 主機依 `videoFramesInFlight` 決定要不要跳過新影格：網路跟不上時寧可丟幀，
    /// 也不要讓 socket 佇列越積越長——那會讓延遲無上限地累加。
    func sendVideo(_ type: MessageType, _ payload: Data) {
        let frame = Self.frame(type, payload)
        stats.withLock {
            $0.bytesSent += UInt64(frame.count)
            $0.videoFramesInFlight += 1
        }
        connection.send(content: frame, completion: .contentProcessed { [weak self] _ in
            self?.stats.withLock { $0.videoFramesInFlight -= 1 }
        })
    }

    private static func frame(_ type: MessageType, _ payload: Data) -> Data {
        var w = ByteWriter()
        w.u8(type.rawValue)
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        return w.data
    }

    // MARK: - 接收

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: ProtocolConstants.headerSize,
                           maximumLength: ProtocolConstants.headerSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil, let data, data.count == ProtocolConstants.headerSize else {
                if isComplete || error != nil { self.connection.cancel() }
                return
            }
            var r = ByteReader(data)
            let rawType = (try? r.u8()) ?? 0
            let length = Int((try? r.u32()) ?? 0)
            guard length <= ProtocolConstants.maxPayload else {
                self.connection.cancel()
                return
            }
            self.stats.withLock { $0.bytesReceived += UInt64(ProtocolConstants.headerSize) }
            if length == 0 {
                self.deliver(rawType, Data())
                self.receiveHeader()
            } else {
                self.receiveBody(rawType, length: length)
            }
        }
    }

    private func receiveBody(_ rawType: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, data.count == length else {
                self.connection.cancel()
                return
            }
            self.stats.withLock { $0.bytesReceived += UInt64(length) }
            self.deliver(rawType, data)
            self.receiveHeader()
        }
    }

    private func deliver(_ rawType: UInt8, _ payload: Data) {
        // 未知類型直接略過，讓舊版用戶端能忽略新版主機多送的訊息
        guard let type = MessageType(rawValue: rawType) else { return }
        onMessage?(type, payload)
    }
}
