//
//  HostController.swift
//  DeskPilotHost
//
//  主機端總控：發布 Bonjour 服務、接受手機連線，串起「擷取 → 編碼 → 傳送」與「接收 → 注入輸入」。
//  同一時間只服務一支手機；新連線進來會取代舊的。
//

import AppKit
import CoreMedia
import CryptoKit
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
    private(set) var screenGranted = CGPreflightScreenCaptureAccess()
    /// 啟動當下有沒有螢幕錄製權限。啟動後才授權的話，擷取要重開 App 才生效。
    private let screenGrantedAtLaunch = CGPreflightScreenCaptureAccess()
    var needsRelaunch: Bool { screenGranted && !screenGrantedAtLaunch }
    /// 兩項權限都齊、且不需要重開，才算可以正常使用。
    var permissionsOK: Bool { screenGranted && accessibilityGranted && !needsRelaunch }
    /// 每秒更新一次的統計。
    private(set) var fps = 0
    private(set) var kbps = 0.0
    private(set) var totalMB = 0.0
    private(set) var videoSize = ""
    private(set) var codecName = ""
    /// 最近一次串流失敗的原因，顯示在視窗上。
    private(set) var lastError: String?
    /// 延遲探針標記：每收到一個探針就改變，讓主機視窗重繪、產生一張新影格。
    private(set) var probeMarker: UInt32 = 0
    /// 編碼耗時（毫秒，近一秒平均）。
    private(set) var encodeMs = 0.0

    /// 等待使用者確認的配對請求。
    struct PairRequest: Identifiable {
        let id = UUID()
        /// 發出請求的連線；連線斷了請求就要從視窗上消失。
        let session: ObjectIdentifier
        let deviceName: String
        let code: String
        let respond: (Bool) -> Void
    }

    private(set) var pairRequest: PairRequest?
    private(set) var pairedDevices: [PairingStore.Entry] = PairingStore.all()

    private var listener: NWListener?
    private let tunnelRelay = TunnelRelay(port: ProtocolConstants.port)
    private var session: HostSession?
    /// 尚未通過驗證的連線。驗證前不取代目前的連線，陌生人連進來也踢不掉使用者。
    private var pending: [ObjectIdentifier: HostSession] = [:]
    private static let maxPending = 4
    private var statsTimer: Timer?

    func start() {
        guard listener == nil else { return }
        // 主動檢查並要求螢幕錄製權限：沒授權時系統會把本 App 加進設定清單並提示使用者
        let screenOK = CGPreflightScreenCaptureAccess()
        Self.log.info("螢幕錄製權限預檢：\(screenOK, privacy: .public)")
        if !screenOK { CGRequestScreenCaptureAccess() }
        do {
            let l = try NWListener(using: FramedConnection.tcpParameters(), on: NWEndpoint.Port(rawValue: ProtocolConstants.port)!)
            // TXT 帶主機 ID：手機連線前就知道要用哪一組配對金鑰
            l.service = NWListener.Service(name: Host.current().localizedName ?? "Mac",
                                           type: ProtocolConstants.bonjourType,
                                           txtRecord: NWTXTRecord(["id": PairingStore.localID.uuidString]))
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

    /// 開啟系統設定的對應隱私權頁面。
    func openPrivacySettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 重新開啟本 App：螢幕錄製權限在授權後要重開才會生效。
    func relaunch() {
        // 新程序要等舊的放掉監聽埠才能啟動，所以交給 shell 延遲 1 秒再開
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    nonisolated static let log = Logger(subsystem: "tw.firstfu.DeskPilotHost", category: "host")

    private func listenerChanged(_ state: NWListener.State) {
        Self.log.info("Listener 狀態：\(String(describing: state), privacy: .public)")
        switch state {
        case .ready:
            if session == nil { status = .listening }
            // 主監聽器綁好萬用位址後才開通道轉接；轉接器若先綁特定位址，主監聽器會因埠被占用而啟動失敗
            tunnelRelay.start()
        case .failed(let e): status = .failed(e.localizedDescription)
        default: break
        }
    }

    /// 允許或拒絕目前的配對請求。
    func answerPairRequest(_ allow: Bool) {
        pairRequest?.respond(allow)
        pairRequest = nil
    }

    /// 移除已配對的裝置；該裝置下次連線會被拒絕。
    func removePairedDevice(_ id: UUID) {
        PairingStore.remove(id: id)
        pairedDevices = PairingStore.all()
        // 正在連線中的這支手機要立刻斷開，不能等它下次連線才擋
        if session?.deviceID == id { session?.stop() }
        for s in pending.values where s.deviceID == id { s.stop() }
    }

    /// 只接受私有網段來的連線（區網、WireGuard 通道 10.66.0.0/24、本機）。
    /// 路由器只轉送 WireGuard 的 UDP 埠，正常不會有公網連線進來；這層是防路由器設錯的保險。
    nonisolated static func isPrivate(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            let b = [UInt8](a.rawValue)
            return b[0] == 10 || b[0] == 127 || (b[0] == 172 && (16...31).contains(b[1]))
                || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254)
        case .ipv6(let a):
            if a.isLoopback || a.isLinkLocal { return true }
            if let v4 = a.asIPv4 { return isPrivate(.hostPort(host: .ipv4(v4), port: 0)) }
            return [UInt8](a.rawValue)[0] & 0xFE == 0xFC  // ULA fc00::/7
        default:
            return false
        }
    }

    private func accept(_ conn: NWConnection) {
        guard Self.isPrivate(conn.endpoint) else {
            Self.log.notice("拒絕非私有網段的連線：\(String(describing: conn.endpoint), privacy: .public)")
            conn.cancel()
            return
        }
        guard pending.count < Self.maxPending else {
            conn.cancel()
            return
        }
        let s = HostSession(connection: conn)
        let key = ObjectIdentifier(s)
        s.onAuthorized = { [weak self, weak s] name in
            Task { @MainActor in
                guard let self, let s else { return }
                self.promote(s, name: name)
            }
        }
        s.onPairRequest = { [weak self] name, code, respond in
            Task { @MainActor in
                guard let self else { return respond(false) }
                // 同時只顯示一個請求；舊的視同拒絕
                self.pairRequest?.respond(false)
                self.pairRequest = PairRequest(session: key, deviceName: name, code: code, respond: respond)
                NSApp.activate()
            }
        }
        s.onEnded = { [weak self, weak s] in
            Task { @MainActor in
                guard let self else { return }
                self.pending[key] = nil
                if self.pairRequest?.session == key { self.pairRequest = nil }
                guard let s, self.session === s else { return }
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
        s.onProbe = { [weak self] id in
            Task { @MainActor in self?.probeMarker = id }
        }
        pending[key] = s
        s.start()
    }

    /// 通過驗證的連線取代目前的連線。
    private func promote(_ s: HostSession, name: String) {
        pending[ObjectIdentifier(s)] = nil
        if session !== s { session?.stop() }
        session = s
        pairedDevices = PairingStore.all()
        lastError = nil
        status = .connected(name)
    }

    private func refreshStats() {
        accessibilityGranted = InputInjector.isTrusted(prompt: false)
        screenGranted = CGPreflightScreenCaptureAccess()
        guard let s = session else {
            fps = 0; kbps = 0
            return
        }
        let snap = s.takeSecondStats()
        fps = snap.frames
        kbps = Double(snap.bytes) * 8 / 1000
        totalMB = Double(snap.totalBytes) / 1_000_000
        encodeMs = snap.encodeMs
        Self.log.notice("stats fps=\(snap.frames, privacy: .public) kbps=\(Int(self.kbps), privacy: .public) encodeMs=\(String(format: "%.1f", snap.encodeMs), privacy: .public) ax=\(self.accessibilityGranted, privacy: .public) scrolls=\(snap.scrolls, privacy: .public) dirty=\(String(format: "%.2f", snap.dirty), privacy: .public) mode=\(s.bitrateMode == .video ? "video" : "text", privacy: .public)")
    }
}

/// 一支手機的連線工作階段。除了 UI 回呼外，所有工作都在自己的序列佇列上。
final class HostSession: @unchecked Sendable {
    struct SecondStats {
        var frames = 0
        var bytes: UInt64 = 0
        var totalBytes: UInt64 = 0
        var encodeMs = 0.0
        var scrolls = 0
        var dirty = 0.0
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
    private let counters = OSAllocatedUnfairLock(initialState: (frames: 0, lastBytes: UInt64(0), encodeTotalMs: 0.0))
    /// 最近一張擷取到的畫面與時間（host clock 秒），供靜止後的畫質補強使用。
    private let lastFrame = OSAllocatedUnfairLock<(buffer: CVPixelBuffer, time: Double, refined: Int)?>(initialState: nil)
    private var refineTimer: DispatchSourceTimer?
    private let bitrateController = BitrateController()
    private let dirtyStats = OSAllocatedUnfairLock(initialState: (sum: 0.0, count: 0))
    private var textBitrate = 1_000_000
    private var audioWanted = false
    /// 影片／大面積動畫模式的位元率（捲動文字用 `textBitrate`）。
    private var videoBitrate: Int { saverOn ? 3_000_000 : 6_000_000 }
    /// 畫面停止變化多久後開始補強、最多補幾張。
    private static let refineDelay = 0.12
    private var maxRefines: Int { saverOn ? 3 : 5 }
    /// 靜止補強期間的位元率；下一張真實影格來時還原。
    private var refineBitrate: Int { saverOn ? 4_000_000 : 8_000_000 }
    /// 省流量模式（手機開啟）：位元率、補強次數、影格率都降低，也不升原生解析度。
    private let saver = OSAllocatedUnfairLock(initialState: false)
    private var saverOn: Bool { saver.withLock { $0 } }
    /// 目前內容類型該用的位元率。
    private var targetBitrate: Int { bitrateController.mode == .video ? videoBitrate : (saverOn ? min(textBitrate, 1_000_000) : textBitrate) }
    private let refineBoosted = OSAllocatedUnfairLock(initialState: false)
    /// 等待中的延遲探針：(編號, 收到時的 host clock 秒數)。擷取時間晚於此的第一張影格會帶上編號。
    private let pendingProbe = OSAllocatedUnfairLock<(UInt32, Double)?>(initialState: nil)

    /// 手機回報的顯示區大小與目前操控的螢幕（工作階段佇列／beginStreaming 內使用）。
    private var hello: HelloMessage?
    private var displayID = CGMainDisplayID()
    private var switching = false
    /// 手機放大時要原生解析度（小字才清楚）；平常縮到手機像素。
    private var nativeDetail = false
    /// 換畫質進行中時，後到的請求先記著，做完再套最新那個（只在 `queue` 上存取）。
    private var detailBusy = false
    private var pendingDetail: Bool?
    /// 編碼器世代：換編碼器後，舊編碼器還在路上的輸出一律丟掉，避免跟新解析度的影格混在一起。
    private let encoderGeneration = OSAllocatedUnfairLock(initialState: 0)

    var bitrateMode: BitrateController.Mode { bitrateController.mode }

    /// 交握與授權狀態（只在 `queue` 上存取）。未授權前除交握外的訊息一律忽略。
    private var handshakeDone = false
    private var authorized = false
    private var pairingKeys: SessionKeys?
    private var pairingDevice: (id: UUID, name: String)?
    /// 交握時手機回報的裝置 ID（明文，授權前不可信，只用來在使用者移除裝置時找到對應連線）。
    private(set) var deviceID: UUID? {
        get { deviceIDBox.withLock { $0 } }
        set { deviceIDBox.withLock { $0 = newValue } }
    }
    private let deviceIDBox = OSAllocatedUnfairLock<UUID?>(initialState: nil)
    /// 手機是否要求原生解析度（省流量模式開著時不升）。
    private var wantsNative = false
    private let audioEncoder = OSAllocatedUnfairLock<AudioEncoder?>(initialState: nil)
    /// 已配對裝置交握後、尚未收到第一則成功解密訊息前的裝置名稱。
    private var resumeDeviceName: String?

    /// 通過驗證（已配對裝置，或使用者剛允許配對）時呼叫，參數為裝置名稱。主控據此才取代舊連線。
    var onAuthorized: ((String) -> Void)?
    /// 首次配對請求：裝置名稱、確認碼、回覆函式（true = 允許）。
    var onPairRequest: ((String, String, @escaping (Bool) -> Void) -> Void)?
    var onEnded: (() -> Void)?
    var onStarted: (((Int, Int), VideoCodec) -> Void)?
    /// 無法開始串流時呼叫（例如缺螢幕錄製權限）。
    var onError: ((String) -> Void)?
    /// 收到延遲探針時呼叫，主機視窗據此重繪。
    var onProbe: ((UInt32) -> Void)?

    /// 允許同時「在路上」的影格數。超過就丟掉新影格，延遲才不會越積越多。
    private static let maxFramesInFlight = 2

    init(connection: NWConnection) {
        framed = FramedConnection(connection: connection, queue: queue)
    }

    func start() {
        framed.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        framed.onStateChange = { [weak self] state in
            switch state {
            case .failed(let e):
                HostController.log.notice("連線失敗：\(e.localizedDescription, privacy: .public)")
                self?.teardown()
            case .cancelled: self?.teardown()
            default: break
            }
        }
        framed.start()
        // 交握逾時：10 秒內沒完成交握就斷線，避免閒置連線佔位
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, !self.handshakeDone else { return }
            HostController.log.notice("交握逾時")
            self.framed.cancel()
        }
    }

    func stop() {
        framed.cancel()
    }

    /// 處理交握：交換臨時金鑰、驗證或發起配對，之後所有訊息加密。
    private func handleHandshake(_ payload: Data) {
        guard !handshakeDone, let hs = try? HandshakeMessage.decode(payload),
              hs.version == ProtocolConstants.version else {
            HostController.log.error("交握：格式或版本不符（\(payload.count, privacy: .public) bytes）")
            framed.cancel()
            return
        }
        HostController.log.notice("交握：\(hs.mode == .pair ? "配對" : "驗證", privacy: .public) 裝置 \(hs.deviceName, privacy: .public)")
        handshakeDone = true
        deviceID = hs.deviceID
        let psk: Data?
        switch hs.mode {
        case .resume:
            guard let k = PairingStore.key(for: hs.deviceID) else {
                HostController.log.notice("交握：沒有這支手機的配對紀錄，回 authFailed")
                framed.send(.authFailed)
                framed.cancel()
                return
            }
            psk = k
        case .pair:
            psk = nil
        }
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let hostEph = priv.publicKey.rawRepresentation
        let hostID = PairingStore.localID
        guard let keys = try? SessionKeys.derive(myPrivate: priv, theirPublic: hs.ephemeralKey,
                                                 clientEphemeral: hs.ephemeralKey, hostEphemeral: hostEph,
                                                 deviceID: hs.deviceID, hostID: hostID, psk: psk) else {
            framed.cancel()
            return
        }
        framed.send(.handshakeAck, HandshakeAckMessage(hostID: hostID, ephemeralKey: hostEph).encode())
        framed.enableEncryption(send: keys.hostToClient, receive: keys.clientToHost)

        let name = hs.deviceName.isEmpty ? "iPhone" : String(hs.deviceName.prefix(64))
        if hs.mode == .resume {
            // 先不算通過：手機 ID 是明文，有人冒用時 PSK 不對，第一則加密訊息就解不開（FramedConnection 斷線）。
            // 等第一則訊息成功解密才算驗證完成，否則冒用者也能把使用者目前的連線踢掉
            resumeDeviceName = name
            return
        }
        pairingKeys = keys
        pairingDevice = (hs.deviceID, name)
        var answered = false
        let respond: (Bool) -> Void = { [weak self] allow in
            self?.queue.async {
                guard let self, !answered else { return }
                answered = true
                self.finishPairing(allow)
            }
        }
        onPairRequest?(name, keys.pairingCode, respond)
        // 60 秒沒回應視同拒絕
        queue.asyncAfter(deadline: .now() + 60) { respond(false) }
    }

    private func finishPairing(_ allow: Bool) {
        guard let keys = pairingKeys, let device = pairingDevice else { return }
        pairingKeys = nil
        framed.send(.pairResult, Data([allow ? 1 : 0]))
        guard allow else {
            framed.cancel()
            return
        }
        PairingStore.save(id: device.id, name: device.name, key: keys.pairingKey)
        authorized = true
        onAuthorized?(device.name)
    }

    /// 取出並重置這一秒的統計。
    func takeSecondStats() -> SecondStats {
        let total = framed.currentStats.bytesSent
        let dirty = dirtyStats.withLock { d -> Double in
            defer { d = (0, 0) }
            return d.count > 0 ? d.sum / Double(d.count) : 0
        }
        return counters.withLock { c in
            let avg = c.frames > 0 ? c.encodeTotalMs / Double(c.frames) : 0
            let s = SecondStats(frames: c.frames, bytes: total - c.lastBytes, totalBytes: total, encodeMs: avg,
                                scrolls: injector.scrollCount, dirty: dirty)
            c.frames = 0
            c.lastBytes = total
            c.encodeTotalMs = 0
            return s
        }
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        guard handshakeDone else {
            if type == .handshake { handleHandshake(payload) } else {
                HostController.log.error("交握前收到其他訊息：\(type.rawValue, privacy: .public)")
                framed.cancel()
            }
            return
        }
        if let name = resumeDeviceName {
            resumeDeviceName = nil
            authorized = true
            onAuthorized?(name)
        }
        guard authorized else { return }
        switch type {
        case .hello:
            guard let hello = try? HelloMessage.decode(payload), hello.version == ProtocolConstants.version else {
                framed.cancel()
                return
            }
            self.hello = hello
            Task { await self.beginStreaming(hello, display: self.displayID) }
        case .input:
            guard let event = try? InputEvent.decode(payload) else { return }
            switch event {
            case .mouseMove, .mouseButton: lastRemoteMouse = ProcessInfo.processInfo.systemUptime
            default: break
            }
            bitrateController.noteInput(now: CMClockGetTime(CMClockGetHostTimeClock()).seconds)
            injector.handle(event)
        case .setDetail:
            guard let v = payload.first, !switching, hello != nil else { return }
            wantsNative = v == 1
            requestDetail(wantsNative && !saverOn)
        case .setSaver:
            guard let v = payload.first, hello != nil else { return }
            Task { await self.applySaver(v == 1) }
        case .setAudio:
            guard let v = payload.first else { return }
            Task { await self.applyAudio(v == 1) }
        case .clipboard:
            handleClipboard(payload)
        case .selectDisplay:
            guard let index = payload.first.map(Int.init) else { return }
            let list = Self.activeDisplays()
            guard list.indices.contains(index), list[index] != displayID, !switching, let hello else { return }
            switching = true
            Task { await self.switchDisplay(to: list[index], hello: hello) }
        case .ping:
            framed.send(.pong, payload)
        case .requestKeyframe:
            encoder?.requestKeyframe()
        case .probe:
            var r = ByteReader(payload)
            guard let id = try? r.u32() else { return }
            pendingProbe.withLock { $0 = (id, CMClockGetTime(CMClockGetHostTimeClock()).seconds) }
            onProbe?(id)
        case .report:
            let text = String(data: payload, encoding: .utf8) ?? ""
            HostController.log.notice("量測回報：\(text, privacy: .public)")
        default:
            break
        }
    }

    /// 省流量模式切換：降影格率與位元率；開啟時若在原生解析度，退回手機像素，關閉時依手機的放大需求還原。
    private func applySaver(_ on: Bool) async {
        guard saverOn != on else { return }
        saver.withLock { $0 = on }
        HostController.log.notice("省流量模式：\(on ? "開" : "關", privacy: .public)")
        encoder?.setBitrate(targetBitrate)
        if let geo = hello.map({ Self.geometry(display: displayID, native: nativeDetail, hello: $0) }) {
            try? await capturer.reconfigure(width: geo.width, height: geo.height, fps: on ? 30 : 60)
        }
        queue.async { self.requestDetail(self.wantsNative && !on) }
    }

    /// 開關聲音串流。
    private func applyAudio(_ on: Bool) async {
        guard audioWanted != on else { return }
        audioWanted = on
        if on {
            guard let enc = AudioEncoder() else {
                HostController.log.error("無法建立聲音編碼器")
                audioWanted = false
                return
            }
            audioEncoder.withLock { $0 = enc }
            framed.send(.audioFormat, AudioFormatMessage(sampleRate: UInt32(AudioEncoder.sampleRate),
                                                         channels: UInt8(AudioEncoder.channels)).encode())
        }
        do {
            try await capturer.setAudio(on)
        } catch {
            HostController.log.error("切換聲音失敗：\(error.localizedDescription, privacy: .public)")
        }
        if !on { audioEncoder.withLock { $0 = nil } }
        HostController.log.notice("聲音串流：\(on ? "開" : "關", privacy: .public)")
    }

    private func encodeAudio(_ sample: CMSampleBuffer) {
        let packets = audioEncoder.withLock { $0?.encode(sample) } ?? []
        for p in packets { framed.send(.audioFrame, p) }
    }

    /// 剪貼簿：有內容 = 寫進 Mac 的剪貼簿；空 = 回傳 Mac 目前的剪貼簿文字。
    private func handleClipboard(_ payload: Data) {
        if payload.isEmpty {
            DispatchQueue.main.async {
                let text = NSPasteboard.general.string(forType: .string) ?? ""
                // 文字上限 1 MB，避免剪貼簿裡的超大內容塞滿連線
                let data = Data(text.utf8.prefix(1_000_000))
                self.queue.async { self.framed.send(.hostClipboard, data) }
            }
        } else if payload.count <= 1_000_000, let text = String(data: payload, encoding: .utf8) {
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }

    /// 作用中的螢幕，主螢幕排第一，其餘由左到右。序號即協定裡的螢幕序號。
    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let main = CGMainDisplayID()
        return ids.prefix(Int(count)).sorted {
            if $0 == main || $1 == main { return $0 == main }
            return CGDisplayBounds($0).minX < CGDisplayBounds($1).minX
        }
    }

    private func sendDisplayInfo() {
        let list = Self.activeDisplays()
        let current = list.firstIndex(of: displayID) ?? 0
        framed.send(.displayInfo, DisplayInfoMessage(count: UInt8(list.count), current: UInt8(current)).encode())
    }

    /// 換成另一台螢幕：停掉舊擷取、依新螢幕重建編碼器與擷取，再通知手機新的桌面大小。
    private func switchDisplay(to display: CGDirectDisplayID, hello: HelloMessage) async {
        await capturer.stopAndWait()
        lastFrame.withLock { $0 = nil }
        displayID = display
        injector.displayID = display
        injector.centerCursor()
        lastCursor = nil
        await beginStreaming(hello, display: display)
        switching = false
    }

    /// 編碼解析度：平常縮到手機像素（多出來的像素手機顯示不了，純浪費流量）；
    /// 手機放大時改原生解析度，放大後的小字才是真的像素而不是放大的模糊圖。
    private static func geometry(display: CGDirectDisplayID, native: Bool, hello: HelloMessage) -> (width: Int, height: Int) {
        let bounds = CGDisplayBounds(display)
        let mode = CGDisplayCopyDisplayMode(display)
        let nativeW = Double(mode?.pixelWidth ?? Int(bounds.width))
        let nativeH = Double(mode?.pixelHeight ?? Int(bounds.height))
        let scale = native ? 1 : min(1, Double(hello.viewWidth) / nativeW, Double(hello.viewHeight) / nativeH)
        return (Int(nativeW * scale) & ~1, Int(nativeH * scale) & ~1)
    }

    /// 建立新的編碼器並換上；舊編碼器之後吐出的影格會因世代不符被丟掉。
    private func installEncoder(width: Int, height: Int) throws -> VideoEncoder {
        let target = targetBitrate
        let enc = try VideoEncoder(width: width, height: height, bitrate: target)
        let gen = encoderGeneration.withLock { g -> Int in g += 1; return g }
        enc.onEncoded = { [weak self] frame in
            guard let self, self.encoderGeneration.withLock({ $0 }) == gen else { return }
            self.send(frame)
        }
        refineBoosted.withLock { $0 = false }
        encoderBox.withLock { $0 = enc }
        return enc
    }

    /// 手機切換畫質等級：合併連續請求，一次只做一個。
    private func requestDetail(_ native: Bool) {
        guard !detailBusy else {
            pendingDetail = native
            return
        }
        guard native != nativeDetail else { return }
        detailBusy = true
        Task {
            await self.applyDetail(native)
            self.queue.async {
                self.detailBusy = false
                if let next = self.pendingDetail {
                    self.pendingDetail = nil
                    self.requestDetail(next)
                }
            }
        }
    }

    /// 換編碼解析度：先換編碼器，再改擷取輸出大小；過渡期尺寸不符的畫面在 `captured` 丟掉。
    /// 影像永遠是整個桌面，手機端只是縮放顯示，所以不會出現黑邊。
    private func applyDetail(_ native: Bool) async {
        guard let hello, !switching else { return }
        let geo = Self.geometry(display: displayID, native: native, hello: hello)
        do {
            lastFrame.withLock { $0 = nil }
            _ = try installEncoder(width: geo.width, height: geo.height)
            nativeDetail = native
            try await capturer.reconfigure(width: geo.width, height: geo.height, fps: saverOn ? 30 : 60)
            HostController.log.info("畫質：\(native ? "原生" : "手機", privacy: .public) \(geo.width, privacy: .public)×\(geo.height, privacy: .public)")
        } catch {
            HostController.log.error("換畫質失敗：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 依手機螢幕大小決定編碼解析度，啟動擷取與編碼。
    private func beginStreaming(_ hello: HelloMessage, display: CGDirectDisplayID) async {
        let bounds = CGDisplayBounds(display)
        let geo = Self.geometry(display: display, native: nativeDetail, hello: hello)
        let (w, h) = (geo.width, geo.height)

        do {
            // 預設 2 Mbps（移動中）；停下後由靜止補強暫時拉到 refineBitrate 把小字補清楚（實機 1 Mbps 固定位元率時小字明顯糊）。
            // DESKPILOT_BITRATE 可覆寫（量測用）
            let bitrate = Int(ProcessInfo.processInfo.environment["DESKPILOT_BITRATE"] ?? "") ?? 2_000_000
            textBitrate = bitrate
            bitrateController.onModeChange = { [weak self] mode in
                guard let self else { return }
                let target = self.targetBitrate
                self.encoder?.setBitrate(target)
                HostController.log.notice("位元率切換：\(mode == .video ? "影片" : "文字", privacy: .public) \(target / 1000, privacy: .public) kbps")
            }
            let enc = try installEncoder(width: w, height: h)
            capturer.onFrame = { [weak self] pb, pts, dirty in self?.captured(pb, pts, dirty) }
            capturer.onStop = { [weak self] _ in self?.framed.cancel() }
            capturer.onAudio = { [weak self] sample in self?.encodeAudio(sample) }
            try await capturer.start(displayID: display, width: w, height: h, fps: saverOn ? 30 : 60, audio: audioWanted)

            let ack = HelloAckMessage(desktopWidth: UInt16(bounds.width), desktopHeight: UInt16(bounds.height),
                                      videoWidth: UInt16(w), videoHeight: UInt16(h))
            framed.send(.helloAck, ack.encode())
            sendDisplayInfo()
            onStarted?((w, h), enc.codec)
            queue.async {
                // 切換螢幕時計時器已在跑，不重複建立
                if self.cursorTimer == nil { self.startCursorReporting() }
                if self.refineTimer == nil { self.startRefining() }
            }
        } catch {
            HostController.log.error("無法開始串流：\(error.localizedDescription, privacy: .public)")
            onError?(error.localizedDescription)
            framed.cancel()
        }
    }

    private func captured(_ pb: CVPixelBuffer, _ pts: CMTime, _ dirty: Double) {
        guard let encoder else { return }
        // 換解析度的過渡期，擷取端可能還在送舊尺寸的畫面：交給新編碼器會出錯，直接丟掉
        guard CVPixelBufferGetWidth(pb) == encoder.width, CVPixelBufferGetHeight(pb) == encoder.height else { return }
        if refineBoosted.withLock({ let b = $0; $0 = false; return b }) {
            encoder.setBitrate(targetBitrate)
        }
        dirtyStats.withLock { $0.sum += dirty; $0.count += 1 }
        bitrateController.noteFrame(now: CMClockGetTime(CMClockGetHostTimeClock()).seconds, dirty: dirty)
        // 即使這張因背壓被丟掉，也要記住最新畫面，靜止補強時才會用到正確內容
        lastFrame.withLock { $0 = (pb, pts.seconds, 0) }
        if framed.currentStats.videoFramesInFlight >= Self.maxFramesInFlight { return }
        // 擷取時間晚於探針抵達的第一張影格，就是反映這次輸入的畫面
        let probeId = pendingProbe.withLock { p -> UInt32 in
            guard let (id, armed) = p, pts.seconds > armed else { return 0 }
            p = nil
            return id
        }
        encoder.encode(pb, pts: pts, probeId: probeId)
    }

    private func send(_ frame: VideoEncoder.EncodedFrame) {
        if let format = frame.format {
            framed.send(.videoFormat, format.encode())
        }
        let msg = VideoFrameMessage(isKeyframe: frame.isKeyframe,
                                    captureTimeNs: DispatchTime.now().uptimeNanoseconds,
                                    probeId: frame.probeId,
                                    payload: frame.data)
        framed.sendVideo(.videoFrame, msg.encode())
        counters.withLock {
            $0.frames += 1
            $0.encodeTotalMs += frame.encodeMs
        }
    }

    /// 靜止畫質補強：畫面停止變化 `refineDelay` 秒後，把最後一張再編碼幾次。
    /// 編碼器拿「原始畫面」和「上一張解碼後的模糊結果」比差異，所以重複送同一張會逐步把細節補回來；
    /// 這讓移動中可以用低位元率（省流量），停下來後文字又恢復清晰。每次停頓只多花幾十 KB。
    private func startRefining() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(40))
        t.setEventHandler { [weak self] in
            guard let self, let encoder = self.encoder,
                  self.framed.currentStats.videoFramesInFlight < Self.maxFramesInFlight else { return }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            self.bitrateController.tick(now: now.seconds)
            let buffer = self.lastFrame.withLock { f -> CVPixelBuffer? in
                guard let cur = f, now.seconds - cur.time > Self.refineDelay, cur.refined < self.maxRefines else { return nil }
                f = (cur.buffer, cur.time, cur.refined + 1)
                return cur.buffer
            }
            if let buffer {
                if !self.refineBoosted.withLock({ let b = $0; $0 = true; return b }) { encoder.setBitrate(self.refineBitrate) }
                encoder.encode(buffer, pts: now)
            }
        }
        t.resume()
        refineTimer = t
    }

    /// 30Hz 檢查實體游標，有變才送（4 bytes + 5 bytes 標頭）。
    private func startCursorReporting() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            guard ProcessInfo.processInfo.systemUptime - self.lastRemoteMouse > 0.5,
                  let pos = InputInjector.currentCursorNormalized(display: self.displayID) else { return }
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
        refineTimer?.cancel()
        refineTimer = nil
        lastFrame.withLock { $0 = nil }
        capturer.stop()
        encoderBox.withLock { $0 = nil }
        onEnded?()
    }
}
