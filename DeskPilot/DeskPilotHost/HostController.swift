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
import IOKit.pwr_mgt
import Network
import Observation
import os
import ScreenCaptureKit

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

    /// 只接受私有網段來的連線（區網、本機）。外網經 Cloudflare Tunnel 進來時，cloudflared 在本機轉接，來源是 127.0.0.1。
    /// 路由器沒有轉送任何埠，正常不會有公網連線直接進來；這層是防路由器設錯的保險。
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

    /// 這條連線能不能發起配對。配對要人在 Mac 旁按允許，只開放給區網。
    /// 本機回送位址的連線就是 cloudflared 從公網轉進來的：不准配對，
    /// 否則任何知道網域的人都能讓 Mac 跳出配對視窗，誤按一次就拿到整台 Mac 的控制權。
    nonisolated static func allowsPairing(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a): return !a.isLoopback
        case .ipv6(let a): return !(a.isLoopback || (a.asIPv4?.isLoopback ?? false))
        default: return false
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
        let s = HostSession(connection: conn, allowsPairing: Self.allowsPairing(conn.endpoint))
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
    /// 只串流單一視窗時的目標；nil＝整個螢幕。
    private struct WindowTarget {
        var id: CGWindowID
        /// 全域座標（左上原點，point）。
        var frame: CGRect
        /// 視窗所在螢幕的像素／point 比。
        var scale: CGFloat
    }
    private var window: WindowTarget?
    /// 每 0.5 秒檢查視窗有沒有移動、縮放或關掉。
    private var windowTimer: DispatchSourceTimer?
    /// 視窗大小變了、等下一次檢查確認穩定才重開擷取（拖曳縮放時不會每 0.5 秒重開一次）。
    private var pendingWindowSize: CGSize?
    /// 手機要求「解析度配合手機」。
    private var fitResolution = false
    /// 被改過解析度的螢幕與它原本的模式；還原時用。
    private let originalMode = OSAllocatedUnfairLock<(display: CGDirectDisplayID, mode: CGDisplayMode)?>(initialState: nil)
    private var switching = false
    /// 擷取中斷後正在接回（只在 `queue` 上存取）。
    private var recovering = false
    /// 最近幾次接回擷取的時間，用來判斷是否反覆中斷該放棄。
    private var recoveryTimes: [TimeInterval] = []
    /// 連線已結束；重試中的開始串流看到就停手。
    private let ended = OSAllocatedUnfairLock(initialState: false)
    /// 串流期間不讓螢幕閒置睡著的電源宣告。
    private let displayAssertion = OSAllocatedUnfairLock<IOPMAssertionID?>(initialState: nil)
    private var screenObserver: NSObjectProtocol?
    private var lockObservers: [NSObjectProtocol] = []
    /// 上次告訴手機的主機狀態旗標（只在 `queue` 上存取）；nil＝還沒送過。
    private var sentHostState: UInt8?
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

    /// 這條連線能否發起首次配對（經 Cloudflare Tunnel 來的不行，見 `HostController.allowsPairing`）。
    private let allowsPairing: Bool

    init(connection: NWConnection, allowsPairing: Bool) {
        framed = FramedConnection(connection: connection, queue: queue)
        self.allowsPairing = allowsPairing
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
        // 螢幕配置變了（闔上筆電、拔插外接螢幕）：正在擷取的螢幕不見就換到還在的那台，否則只更新手機的螢幕數
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard self.hello != nil, self.authorized else { return }
                if Self.activeDisplays().contains(self.displayID) {
                    if !self.switching, !self.recovering { self.sendDisplayInfo() }
                } else {
                    self.recoverCapture("螢幕 \(self.displayID) 不見了")
                }
            }
        }
        // Mac 鎖定／解鎖：告訴手機，鎖定畫面打不了字（安全輸入），手機才不會以為是鍵盤壞了
        let center = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            lockObservers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: nil) { [weak self] _ in
                guard let self else { return }
                // 通知比 CGSession 的狀態稍早到，等一下再讀
                self.queue.asyncAfter(deadline: .now() + 0.3) { self.sendHostState() }
            })
        }
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
        guard allowsPairing else {
            // 回「不允許從這裡配對」(2)；舊版手機會當成被拒絕。晚一點才斷線，否則回覆可能來不及送出
            HostController.log.notice("交握：外網來的配對請求，拒絕（裝置 \(name, privacy: .public)）")
            framed.send(.pairResult, Data([PairResultCode.remoteNotAllowed]))
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.framed.cancel() }
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
        framed.send(.pairResult, Data([allow ? PairResultCode.allowed : PairResultCode.rejected]))
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
            Task { await self.beginStreaming(hello) }
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
        case .setFitResolution:
            guard let v = payload.first, let hello, !switching, !recovering, (v == 1) != fitResolution else { return }
            fitResolution = v == 1
            switching = true
            Task {
                await self.applyFitResolution(hello: hello)
                self.queue.async { self.switching = false }
            }
        case .clipboard:
            handleClipboard(payload)
        case .listWindows:
            let current = window?.id ?? 0
            Task {
                let items = await Self.windowList()
                self.framed.send(.windowList, WindowListMessage(current: current, items: items).encode())
            }
        case .selectWindow:
            var r = ByteReader(payload)
            guard let id = try? r.u32(), !switching, !recovering, let hello else { return }
            switching = true
            Task {
                await self.switchWindow(to: id == 0 ? nil : id, hello: hello)
                self.queue.async { self.switching = false }
            }
        case .selectDisplay:
            guard let index = payload.first.map(Int.init) else { return }
            let list = Self.activeDisplays()
            guard list.indices.contains(index), list[index] != displayID, !switching, !recovering, let hello else { return }
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
        if let geo = hello.map({ geometry(native: nativeDetail, hello: $0) }) {
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
        useWindow(nil)
        // 解析度配合手機只套在正在看的那台：舊的還原、新的改小
        if fitResolution {
            Self.restoreMode(originalMode)
            if Self.applyFitMode(display, saving: originalMode) { try? await Task.sleep(for: .milliseconds(800)) }
        }
        useDisplay(display)
        injector.centerCursor()
        lastCursor = nil
        await beginStreaming(hello, display: display)
        switching = false
    }

    private func useDisplay(_ display: CGDirectDisplayID) {
        displayID = display
        injector.displayID = display
    }

    private func useWindow(_ w: WindowTarget?) {
        window = w
        injector.windowFrame = w?.frame
        pendingWindowSize = nil
    }

    // MARK: 解析度配合手機

    /// 依 `fitResolution` 把目前螢幕切到較低解析度或還原，然後重開擷取（重送 helloAck，手機更新桌面大小）。
    private func applyFitResolution(hello: HelloMessage) async {
        let changed = fitResolution ? Self.applyFitMode(displayID, saving: originalMode) : Self.restoreMode(originalMode)
        guard changed else { return }
        // 螢幕換模式要一點時間，等它穩定再重開擷取
        try? await Task.sleep(for: .milliseconds(800))
        await capturer.stopAndWait()
        lastFrame.withLock { $0 = nil }
        lastCursor = nil
        await beginStreaming(hello, display: displayID)
    }

    /// 挑一個跟目前比例相同、寬度最接近 1280 point 的模式（介面約放大 1.5 倍；手機橫放約 900 point 寬，再小 Mac 的視窗會塞不下），
    /// 同寬優先選 HiDPI（像素是 point 的兩倍，字比較銳利）。用 `.forSession` 套用：主機程式結束時系統會自動還原。
    private static func applyFitMode(_ display: CGDirectDisplayID, saving original: OSAllocatedUnfairLock<(display: CGDirectDisplayID, mode: CGDisplayMode)?>) -> Bool {
        guard let current = CGDisplayCopyDisplayMode(display), current.height > 0 else { return false }
        let aspect = Double(current.width) / Double(current.height)
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode] ?? []).filter {
            $0.isUsableForDesktopGUI() && $0.height > 0
                && abs(Double($0.width) / Double($0.height) - aspect) < 0.02
                && $0.width >= 960 && $0.width < current.width
        }
        func score(_ m: CGDisplayMode) -> Double {
            Double(abs(m.width - 1280)) - (m.pixelWidth > m.width ? 0.5 : 0) - (m.refreshRate == current.refreshRate ? 0.1 : 0)
        }
        guard let target = modes.min(by: { score($0) < score($1) }) else {
            HostController.log.notice("螢幕 \(display, privacy: .public) 沒有比目前小的同比例模式，不改解析度")
            return false
        }
        // 已經改過（例如換螢幕前）就不覆蓋原本記住的模式
        original.withLock { saved in if saved == nil { saved = (display, current) } }
        let ok = setMode(target, on: display)
        HostController.log.notice("解析度配合手機：\(current.width, privacy: .public)×\(current.height, privacy: .public) → \(target.width, privacy: .public)×\(target.height, privacy: .public)（像素 \(target.pixelWidth, privacy: .public)×\(target.pixelHeight, privacy: .public)）\(ok ? "" : "失敗", privacy: .public)")
        if !ok { original.withLock { $0 = nil } }
        return ok
    }

    /// 還原被改過的解析度；沒改過回 false。
    @discardableResult
    private static func restoreMode(_ original: OSAllocatedUnfairLock<(display: CGDirectDisplayID, mode: CGDisplayMode)?>) -> Bool {
        guard let saved = original.withLock({ s -> (display: CGDirectDisplayID, mode: CGDisplayMode)? in defer { s = nil }; return s }) else { return false }
        let ok = setMode(saved.mode, on: saved.display)
        HostController.log.notice("還原螢幕 \(saved.display, privacy: .public) 解析度 \(saved.mode.width, privacy: .public)×\(saved.mode.height, privacy: .public)\(ok ? "" : " 失敗", privacy: .public)")
        return ok
    }

    private static func setMode(_ mode: CGDisplayMode, on display: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }

    // MARK: 單一視窗模式

    /// 改成只串流一個視窗（nil＝回到整個螢幕）：把那個 App 帶到前景、視窗升到最上層，游標移到視窗中央，再重開擷取。
    private func switchWindow(to id: CGWindowID?, hello: HelloMessage) async {
        if let id {
            guard let info = Self.windowInfo(id), let windowDisplay = Self.display(at: info.frame) else {
                HostController.log.notice("要切換的視窗 \(id, privacy: .public) 已不在")
                return
            }
            await capturer.stopAndWait()
            lastFrame.withLock { $0 = nil }
            Self.bringToFront(pid: info.pid, frame: info.frame)
            useDisplay(windowDisplay)
            useWindow(WindowTarget(id: id, frame: info.frame, scale: Self.scale(of: windowDisplay)))
            HostController.log.notice("只串流視窗 \(id, privacy: .public)（\(info.app, privacy: .public)）")
        } else {
            await capturer.stopAndWait()
            lastFrame.withLock { $0 = nil }
            useWindow(nil)
            HostController.log.notice("回到整個螢幕")
        }
        injector.centerCursor()
        lastCursor = nil
        await beginStreaming(hello, display: displayID)
        queue.async { self.startWindowTracking() }
    }

    /// 視窗模式下追蹤視窗：移動只更新座標範圍（擷取本來就跟著視窗）；大小變了且穩定才重開擷取；關掉了就回到整個螢幕。
    private func startWindowTracking() {
        guard windowTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 0.5, repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.checkWindow() }
        t.resume()
        windowTimer = t
    }

    private func checkWindow() {
        guard let w = window, !switching, !recovering, let hello else { return }
        guard let info = Self.windowInfo(w.id) else {
            recoverCapture("視窗 \(w.id) 關掉了")
            return
        }
        let size = info.frame.size
        if abs(size.width - w.frame.width) < 1, abs(size.height - w.frame.height) < 1 {
            pendingWindowSize = nil
            if info.frame.origin != w.frame.origin {
                // 移到別台螢幕就整個重開；同一台只改裁切範圍
                guard Self.display(at: info.frame) == displayID else {
                    recoverCapture("視窗移到別的螢幕")
                    return
                }
                window?.frame = info.frame
                injector.windowFrame = info.frame
                let crop = Self.localRect(info.frame, on: displayID)
                Task { try? await self.capturer.setCrop(crop) }
            }
            return
        }
        // 大小變了：等下一次檢查大小沒再變（拖曳縮放結束）才重開擷取，並重送 helloAck 讓手機更新比例
        guard let pending = pendingWindowSize, abs(pending.width - size.width) < 1, abs(pending.height - size.height) < 1 else {
            pendingWindowSize = size
            return
        }
        pendingWindowSize = nil
        HostController.log.notice("視窗大小改成 \(Int(size.width), privacy: .public)×\(Int(size.height), privacy: .public)，重開擷取")
        switching = true
        Task {
            await capturer.stopAndWait()
            lastFrame.withLock { $0 = nil }
            await beginStreaming(hello, display: displayID)
            queue.async { self.switching = false }
        }
    }

    /// 視窗目前的位置與擁有者；視窗關掉或不在畫面上時回 nil。
    /// 位置裁在視窗中心所在的螢幕內：超出螢幕的部分拍不到，座標範圍也要跟著一致。
    private static func windowInfo(_ id: CGWindowID) -> (frame: CGRect, pid: pid_t, app: String)? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let info = list.first,
              (info[kCGWindowIsOnscreen as String] as? Bool) == true,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let raw = CGRect(dictionaryRepresentation: boundsDict),
              let pid = info[kCGWindowOwnerPID as String] as? pid_t,
              let display = display(at: raw) else { return nil }
        let frame = raw.intersection(CGDisplayBounds(display))
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        return (frame, pid, info[kCGWindowOwnerName as String] as? String ?? "")
    }

    /// 視窗中心所在的螢幕。
    private static func display(at frame: CGRect) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(CGPoint(x: frame.midX, y: frame.midY), 1, &id, &count)
        return count > 0 ? id : nil
    }

    /// 螢幕的像素／point 比（Retina 是 2）。
    private static func scale(of display: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(display), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    /// 全域座標的矩形換成該螢幕的本地座標（`sourceRect` 用），並裁在螢幕範圍內。
    private static func localRect(_ r: CGRect, on display: CGDirectDisplayID) -> CGRect {
        let b = CGDisplayBounds(display)
        return r.intersection(b).offsetBy(dx: -b.minX, dy: -b.minY)
    }

    /// 可以單獨串流的視窗：一般層級、夠大、不是自己；依前後順序排（最前面的在前）。
    private static func windowList() async -> [WindowListMessage.Item] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return [] }
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let me = Bundle.main.bundleIdentifier
        let candidates: [SCWindow] = content.windows.filter { w in
            guard w.windowLayer == 0, w.frame.width >= 120, w.frame.height >= 80,
                  let app = w.owningApplication, app.bundleIdentifier != me else { return false }
            return true
        }
        let sorted = candidates.sorted { a, b in
            let ra: Int = rank[a.windowID] ?? Int.max
            let rb: Int = rank[b.windowID] ?? Int.max
            return ra < rb
        }
        return sorted.map { w in
            WindowListMessage.Item(id: w.windowID, app: w.owningApplication?.applicationName ?? "", title: w.title ?? "")
        }
    }

    /// 把 App 帶到前景並把指定視窗升到最上層（打字才會進到這個視窗）。視窗用位置與大小比對。
    private static func bringToFront(pid: pid_t, frame: CGRect) {
        DispatchQueue.main.async { _ = NSRunningApplication(processIdentifier: pid)?.activate() }
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        for w in windows {
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            var pos = CGPoint.zero
            var size = CGSize.zero
            guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posRef, let sizeRef,
                  AXValueGetValue(posRef as! AXValue, .cgPoint, &pos),
                  AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { continue }
            if abs(pos.x - frame.minX) < 2, abs(pos.y - frame.minY) < 2,
               abs(size.width - frame.width) < 2, abs(size.height - frame.height) < 2 {
                AXUIElementPerformAction(w, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
                return
            }
        }
    }

    /// 這次該擷取的螢幕：指定的或記住的還在就用它，不在了（闔上筆電、拔掉外接螢幕）就改用目前的主螢幕；
    /// 完全沒有作用中的螢幕時回 nil。
    private func resolveDisplay(preferred: CGDirectDisplayID?) -> CGDirectDisplayID? {
        let list = Self.activeDisplays()
        for candidate in [preferred, displayID].compactMap({ $0 }) where list.contains(candidate) {
            return candidate
        }
        guard let main = list.first else { return nil }
        HostController.log.notice("螢幕 \(self.displayID, privacy: .public) 已不在，改用主螢幕 \(main, privacy: .public)")
        return main
    }

    /// 擷取中途停掉（螢幕被拔掉、闔上筆電、睡著）或螢幕配置變了：停掉舊擷取，換到還在的螢幕重開。
    /// 短時間內反覆失敗就放棄，避免無限重試。
    private func recoverCapture(_ reason: String) {
        guard let hello, !switching, !recovering, !ended.withLock({ $0 }) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        recoveryTimes = recoveryTimes.filter { now - $0 < 60 } + [now]
        guard recoveryTimes.count <= 3 else {
            HostController.log.error("擷取一分鐘內中斷超過 3 次，放棄")
            fail("Mac 的螢幕擷取一直中斷，請檢查 Mac 的螢幕狀態後再連一次")
            return
        }
        HostController.log.notice("擷取中斷（\(reason, privacy: .public)），嘗試接回")
        recovering = true
        Task {
            await capturer.stopAndWait()
            lastFrame.withLock { $0 = nil }
            lastCursor = nil
            await beginStreaming(hello)
            queue.async { self.recovering = false }
        }
    }

    /// Mac 是否停在鎖定畫面。解鎖時 `CGSSessionScreenIsLocked` 這個鍵不存在。
    private static func screenIsLocked() -> Bool {
        let info = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (info?["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// 串流中才送，狀態沒變不重送（只在 `queue` 上呼叫）。
    private func sendHostState() {
        guard hello != nil, authorized, !ended.withLock({ $0 }) else { return }
        let locked = Self.screenIsLocked()
        let flags: UInt8 = locked ? HostStateFlags.screenLocked : 0
        guard flags != sentHostState else { return }
        sentHostState = flags
        HostController.log.notice("Mac \(locked ? "已鎖定" : "未鎖定", privacy: .public)，通知手機")
        framed.send(.hostState, Data([flags]))
    }

    /// 告訴手機為什麼斷線，等 1 秒再斷（立刻斷的話回覆可能送不到，見 external-access.md）。
    private func fail(_ message: String) {
        onError?(message)
        framed.send(.hostError, Data(message.utf8))
        queue.asyncAfter(deadline: .now() + 1) { self.framed.cancel() }
    }

    /// 叫醒螢幕並在串流期間不讓它因閒置而睡著：睡著的螢幕 ScreenCaptureKit 擷取不到。
    private func keepDisplayAwake() {
        var wake: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("DeskPilot 遠端連線" as CFString, kIOPMUserActiveLocal, &wake)
        displayAssertion.withLock { id in
            guard id == nil else { return }
            var newID: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "DeskPilot 遠端連線中" as CFString, &newID) == kIOReturnSuccess {
                id = newID
            }
        }
    }

    private func releaseDisplayAssertion() {
        displayAssertion.withLock { id in
            if let id { IOPMAssertionRelease(id) }
            id = nil
        }
    }

    /// 編碼解析度：平常縮到手機像素（多出來的像素手機顯示不了，純浪費流量）；
    /// 手機放大時改原生解析度，放大後的小字才是真的像素而不是放大的模糊圖。
    private func geometry(native: Bool, hello: HelloMessage) -> (width: Int, height: Int) {
        let nativeW: Double
        let nativeH: Double
        if let window {
            nativeW = Double(window.frame.width * window.scale)
            nativeH = Double(window.frame.height * window.scale)
        } else {
            let bounds = CGDisplayBounds(displayID)
            let mode = CGDisplayCopyDisplayMode(displayID)
            nativeW = Double(mode?.pixelWidth ?? Int(bounds.width))
            nativeH = Double(mode?.pixelHeight ?? Int(bounds.height))
        }
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
        let geo = geometry(native: native, hello: hello)
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
    /// 螢幕可能剛睡醒或剛換過配置，所以失敗會叫醒螢幕、改用還在的螢幕，每秒重試一次，最多 5 次；都失敗才告訴手機原因並斷線。
    private func beginStreaming(_ hello: HelloMessage, display preferred: CGDirectDisplayID? = nil) async {
        var lastError = ""
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            if ended.withLock({ $0 }) { return }
            keepDisplayAwake()
            guard let display = resolveDisplay(preferred: preferred) else {
                lastError = "Mac 沒有可用的螢幕（筆電闔上又沒接外接螢幕？）"
                HostController.log.notice("沒有作用中的螢幕（第 \(attempt + 1, privacy: .public) 次）")
                continue
            }
            useDisplay(display)
            // 視窗模式：視窗還在就拍它所在的螢幕、裁出視窗；關掉了或拍不到就改回整個螢幕
            if let w = window {
                if let info = Self.windowInfo(w.id), let windowDisplay = Self.display(at: info.frame) {
                    useDisplay(windowDisplay)
                    useWindow(WindowTarget(id: w.id, frame: info.frame, scale: Self.scale(of: windowDisplay)))
                    do {
                        try await startCapture(hello, display: windowDisplay)
                        return
                    } catch {
                        HostController.log.notice("擷取視窗失敗：\(error.localizedDescription, privacy: .public)")
                    }
                }
                HostController.log.notice("視窗 \(w.id, privacy: .public) 已不在，改回整個螢幕")
                useWindow(nil)
            }
            do {
                try await startCapture(hello, display: display)
                return
            } catch {
                lastError = error.localizedDescription
                HostController.log.notice("開始串流失敗（第 \(attempt + 1, privacy: .public) 次）：\(lastError, privacy: .public)")
            }
        }
        HostController.log.error("無法開始串流：\(lastError, privacy: .public)")
        queue.async { self.fail("Mac 無法開始串流：\(lastError)") }
    }

    private func startCapture(_ hello: HelloMessage, display: CGDirectDisplayID) async throws {
        let bounds = window?.frame ?? CGDisplayBounds(display)
        let geo = geometry(native: nativeDetail, hello: hello)
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
            capturer.onStop = { [weak self] error in
                guard let self else { return }
                self.queue.async { self.recoverCapture(error.localizedDescription) }
            }
            capturer.onAudio = { [weak self] sample in self?.encodeAudio(sample) }
            let crop = window.map { Self.localRect($0.frame, on: display) }
            try await capturer.start(displayID: display, crop: crop, width: w, height: h, fps: saverOn ? 30 : 60, audio: audioWanted)

            let ack = HelloAckMessage(desktopWidth: UInt16(bounds.width), desktopHeight: UInt16(bounds.height),
                                      videoWidth: UInt16(w), videoHeight: UInt16(h))
            framed.send(.helloAck, ack.encode())
            sendDisplayInfo()
            queue.async { self.sentHostState = nil; self.sendHostState() }
            onStarted?((w, h), enc.codec)
            queue.async {
                // 切換螢幕時計時器已在跑，不重複建立
                if self.cursorTimer == nil { self.startCursorReporting() }
                if self.refineTimer == nil { self.startRefining() }
            }
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
                  let pos = InputInjector.currentCursorNormalized(in: self.injector.targetBounds) else { return }
            if let last = self.lastCursor, last == pos { return }
            self.lastCursor = pos
            self.framed.send(.cursor, CursorMessage(x: pos.0, y: pos.1).encode())
        }
        t.resume()
        cursorTimer = t
    }

    private func teardown() {
        ended.withLock { $0 = true }
        Self.restoreMode(originalMode)
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        lockObservers.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        lockObservers = []
        releaseDisplayAssertion()
        windowTimer?.cancel()
        windowTimer = nil
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
