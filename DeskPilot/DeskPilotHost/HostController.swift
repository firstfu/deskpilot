//
//  HostController.swift
//  DeskPilotHost
//
//  主機端總控：發布 Bonjour 服務、接受手機連線，串起「擷取 → 編碼 → 傳送」與「接收 → 注入輸入」。
//  同一時間只服務一支手機；新連線進來會取代舊的。
//

import AppKit
import CoreMedia
import Network
import Observation
import os

@MainActor
@Observable
final class HostController {
    enum Status: Equatable {
        case idle
        case listening
        case connected(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    private(set) var accessibilityGranted = InputInjector.isTrusted(prompt: false)
    /// 每秒更新一次的統計。
    private(set) var fps = 0
    private(set) var kbps = 0.0
    private(set) var totalMB = 0.0
    private(set) var videoSize = ""
    private(set) var codecName = ""
    /// 最近一次串流失敗的原因，顯示在視窗上。
    private(set) var lastError: String?

    private var listener: NWListener?
    private var session: HostSession?
    private var statsTimer: Timer?

    func start() {
        guard listener == nil else { return }
        // 主動檢查並要求螢幕錄製權限：沒授權時系統會把本 App 加進設定清單並提示使用者
        let screenOK = CGPreflightScreenCaptureAccess()
        Self.log.info("螢幕錄製權限預檢：\(screenOK, privacy: .public)")
        if !screenOK { CGRequestScreenCaptureAccess() }
        do {
            let l = try NWListener(using: FramedConnection.tcpParameters())
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                           type: ProtocolConstants.bonjourType)
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.listenerChanged(state) }
            }
            l.serviceRegistrationUpdateHandler = { change in
                Self.log.info("Bonjour 註冊變更：\(String(describing: change), privacy: .public)")
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.accept(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            status = .failed(error.localizedDescription)
        }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStats() }
        }
    }

    /// 要求輔助使用權限（會跳系統提示）。
    func requestAccessibility() {
        accessibilityGranted = InputInjector.isTrusted(prompt: true)
    }

    nonisolated static let log = Logger(subsystem: "tw.firstfu.DeskPilotHost", category: "host")

    private func listenerChanged(_ state: NWListener.State) {
        Self.log.info("Listener 狀態：\(String(describing: state), privacy: .public)")
        switch state {
        case .ready: if session == nil { status = .listening }
        case .failed(let e): status = .failed(e.localizedDescription)
        default: break
        }
    }

    private func accept(_ conn: NWConnection) {
        session?.stop()
        let name: String
        if case let .hostPort(host, _) = conn.endpoint { name = "\(host)" } else { name = "\(conn.endpoint)" }
        let s = HostSession(connection: conn)
        s.onEnded = { [weak self, weak s] in
            Task { @MainActor in
                guard let self, self.session === s else { return }
                self.session = nil
                self.status = .listening
            }
        }
        s.onStarted = { [weak self] video, codec in
            Task { @MainActor in
                self?.videoSize = "\(video.0)×\(video.1)"
                self?.codecName = codec == .hevc ? "HEVC" : "H.264"
            }
        }
        s.onError = { [weak self] msg in
            Task { @MainActor in self?.lastError = msg }
        }
        session = s
        lastError = nil
        status = .connected(name)
        s.start()
    }

    private func refreshStats() {
        accessibilityGranted = InputInjector.isTrusted(prompt: false)
        guard let s = session else {
            fps = 0; kbps = 0
            return
        }
        let snap = s.takeSecondStats()
        fps = snap.frames
        kbps = Double(snap.bytes) * 8 / 1000
        totalMB = Double(snap.totalBytes) / 1_000_000
    }
}

/// 一支手機的連線工作階段。除了 UI 回呼外，所有工作都在自己的序列佇列上。
final class HostSession: @unchecked Sendable {
    struct SecondStats {
        var frames = 0
        var bytes: UInt64 = 0
        var totalBytes: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "deskpilot.session", qos: .userInteractive)
    private let framed: FramedConnection
    private let capturer = ScreenCapturer()
    private let injector = InputInjector()
    // 擷取佇列、工作階段佇列都會碰到編碼器，用鎖保護
    private let encoderBox = OSAllocatedUnfairLock<VideoEncoder?>(initialState: nil)
    private var encoder: VideoEncoder? { encoderBox.withLock { $0 } }
    private var cursorTimer: DispatchSourceTimer?
    private var lastCursor: (UInt16, UInt16)?
    /// 最近一次收到手機滑鼠事件的時間；期間內不回報游標，避免主機回報與手機本地游標互相拉扯。
    private var lastRemoteMouse: TimeInterval = 0
    private let counters = OSAllocatedUnfairLock(initialState: (frames: 0, lastBytes: UInt64(0)))

    var onEnded: (() -> Void)?
    var onStarted: (((Int, Int), VideoCodec) -> Void)?
    /// 無法開始串流時呼叫（例如缺螢幕錄製權限）。
    var onError: ((String) -> Void)?

    /// 允許同時「在路上」的影格數。超過就丟掉新影格，延遲才不會越積越多。
    private static let maxFramesInFlight = 2

    init(connection: NWConnection) {
        framed = FramedConnection(connection: connection, queue: queue)
    }

    func start() {
        framed.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        framed.onStateChange = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.teardown()
            default: break
            }
        }
        framed.start()
    }

    func stop() {
        framed.cancel()
    }

    /// 取出並重置這一秒的統計。
    func takeSecondStats() -> SecondStats {
        let total = framed.currentStats.bytesSent
        return counters.withLock { c in
            let s = SecondStats(frames: c.frames, bytes: total - c.lastBytes, totalBytes: total)
            c.frames = 0
            c.lastBytes = total
            return s
        }
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        switch type {
        case .hello:
            guard let hello = try? HelloMessage.decode(payload), hello.version == ProtocolConstants.version else {
                framed.cancel()
                return
            }
            Task { await self.beginStreaming(hello) }
        case .input:
            guard let event = try? InputEvent.decode(payload) else { return }
            switch event {
            case .mouseMove, .mouseButton: lastRemoteMouse = ProcessInfo.processInfo.systemUptime
            default: break
            }
            injector.handle(event)
        case .ping:
            framed.send(.pong, payload)
        case .requestKeyframe:
            encoder?.requestKeyframe()
        default:
            break
        }
    }

    /// 依手機螢幕大小決定編碼解析度，啟動擷取與編碼。
    private func beginStreaming(_ hello: HelloMessage) async {
        let display = CGMainDisplayID()
        let bounds = CGDisplayBounds(display)
        let mode = CGDisplayCopyDisplayMode(display)
        let nativeW = Double(mode?.pixelWidth ?? Int(bounds.width))
        let nativeH = Double(mode?.pixelHeight ?? Int(bounds.height))
        // 只編碼到「手機看得到」的解析度：多出來的像素手機也顯示不了，純浪費流量
        let scale = min(1, Double(hello.viewWidth) / nativeW, Double(hello.viewHeight) / nativeH)
        let w = Int(nativeW * scale) & ~1
        let h = Int(nativeH * scale) & ~1

        do {
            let enc = try VideoEncoder(width: w, height: h, bitrate: 6_000_000)
            enc.onEncoded = { [weak self] frame in self?.send(frame) }
            encoderBox.withLock { $0 = enc }
            capturer.onFrame = { [weak self] pb, pts in self?.captured(pb, pts) }
            capturer.onStop = { [weak self] _ in self?.framed.cancel() }
            try await capturer.start(width: w, height: h)

            let ack = HelloAckMessage(desktopWidth: UInt16(bounds.width), desktopHeight: UInt16(bounds.height),
                                      videoWidth: UInt16(w), videoHeight: UInt16(h))
            framed.send(.helloAck, ack.encode())
            onStarted?((w, h), enc.codec)
            queue.async { self.startCursorReporting() }
        } catch {
            HostController.log.error("無法開始串流：\(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
            framed.cancel()
        }
    }

    private func captured(_ pb: CVPixelBuffer, _ pts: CMTime) {
        guard let encoder else { return }
        if framed.currentStats.videoFramesInFlight >= Self.maxFramesInFlight { return }
        encoder.encode(pb, pts: pts)
    }

    private func send(_ frame: VideoEncoder.EncodedFrame) {
        if let format = frame.format {
            framed.send(.videoFormat, format.encode())
        }
        let msg = VideoFrameMessage(isKeyframe: frame.isKeyframe,
                                    captureTimeNs: DispatchTime.now().uptimeNanoseconds,
                                    payload: frame.data)
        framed.sendVideo(.videoFrame, msg.encode())
        counters.withLock { $0.frames += 1 }
    }

    /// 30Hz 檢查實體游標，有變才送（4 bytes + 5 bytes 標頭）。
    private func startCursorReporting() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard ProcessInfo.processInfo.systemUptime - self.lastRemoteMouse > 0.5,
                  let pos = InputInjector.currentCursorNormalized() else { return }
            if let last = self.lastCursor, last == pos { return }
            self.lastCursor = pos
            self.framed.send(.cursor, CursorMessage(x: pos.0, y: pos.1).encode())
        }
        t.resume()
        cursorTimer = t
    }

    private func teardown() {
        cursorTimer?.cancel()
        cursorTimer = nil
        capturer.stop()
        encoderBox.withLock { $0 = nil }
        onEnded?()
    }
}
