//
//  ClientSession.swift
//  DeskPilot（iOS 用戶端）
//
//  用 Bonjour 找區網內的主機、建立連線、把收到的影格直接丟給硬體解碼顯示層，並送出輸入事件。
//  影像路徑刻意不經過主執行緒：網路佇列收到 → 組 CMSampleBuffer → 交給 AVSampleBufferVideoRenderer，
//  主執行緒卡頓也不會影響畫面更新。
//

import AVFoundation
import CryptoKit
import LocalAuthentication
import Network
import Observation
import UIKit
import os

/// 區網內找到的主機。
struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    /// 主機在 Bonjour TXT 公告的 ID，用來找本機存的配對金鑰。
    let hostID: UUID?
    var id: String { name }
}

@MainActor
@Observable
final class ClientSession {
    enum State: Equatable {
        case browsing
        case connecting(String)
        /// 首次配對：等使用者在 Mac 上確認確認碼。
        case pairing(name: String, code: String)
        case connected(String)
        /// 連線意外中斷，正在自動重連（畫面停在最後一張）。
        case reconnecting(String)
        case failed(String)
    }

    /// 省流量模式偏好：自動 = 只有在行動網路等「計量網路」上才開。
    enum SaverPreference: String, CaseIterable {
        case auto, on, off
        var title: String {
            switch self {
            case .auto: "自動"
            case .on: "開"
            case .off: "關"
            }
        }
    }

    private(set) var state: State = .browsing
    private(set) var hosts: [DiscoveredHost] = []
    /// 遠端桌面大小（point），用來算長寬比。連上前為 nil。
    private(set) var desktopSize: CGSize?
    /// 最近一次向主機要求的畫質（true = 原生解析度），避免重複送。
    private var requestedNativeDetail = false
    /// 主機的螢幕數量與目前操控的螢幕序號（0 起算）。
    private(set) var displayCount = 1
    private(set) var currentDisplay = 0
    /// 游標位置（0...1 正規化）。
    var cursor = CGPoint(x: 0.5, y: 0.5)
    /// 主機回報的游標更新次數；畫面據此判斷要不要跟著移動。
    private(set) var cursorRevision = 0

    private(set) var fps = 0
    private(set) var kbps = 0.0
    private(set) var rttMs: Double?
    private(set) var totalMB = 0.0
    /// 量測進行中的狀態文字；nil 表示沒有在量。
    var benchmarkStatus: String?
    /// 最近一次量測結果。
    var benchmarkResult: String?
    /// 延遲探針結果（毫秒），量測期間累積。
    var probeSamples: [Double] = []

    /// 黏滯修飾鍵：按一下武裝，下一個按鍵（快捷鍵列或手機鍵盤的英數字）用掉後自動放開。
    private(set) var armedModifiers: KeyModifiers = []
    /// 短暫提示（例如「已拷貝到手機剪貼簿」），數秒後自動消失。
    private(set) var toast: String?
    private(set) var saverPreference = SaverPreference(rawValue: UserDefaults.standard.string(forKey: "saverPreference") ?? "") ?? .auto
    /// 目前網路是不是計量網路（行動網路、個人熱點）。
    private(set) var networkIsExpensive = false
    private(set) var audioEnabled = false
    private var saverActive = false
    private var pathMonitor: NWPathMonitor?
    /// 自動重連：最近一次連線的目標與手機顯示區大小。
    private var lastHost: DiscoveredHost?
    private var lastViewPixels = CGSize.zero
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private static let reconnectDelays: [Double] = [1, 2, 3, 5, 8, 10, 15, 20]
    /// 手機目前想要的畫質（放大時 true）；重連後要重送。
    private var desiredNative = false
    private var toastTask: Task<Void, Never>?

    /// 主機明確拒絕時的原因；斷線時顯示這個而不是籠統的「連線中斷」。
    private var rejection: String?
    private var browser: NWBrowser?
    private(set) var link: ClientLink?
    private var statsTimer: Timer?
    private var renderer: AVSampleBufferVideoRenderer?

    // MARK: 探索

    func startBrowsing() {
        guard browser == nil else { return }
        startPathMonitor()
        let b = NWBrowser(for: .bonjourWithTXTRecord(type: ProtocolConstants.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var hostID: UUID?
                if case let .bonjour(txt) = r.metadata, let s = txt["id"] { hostID = UUID(uuidString: s) }
                return DiscoveredHost(name: name, endpoint: r.endpoint, hostID: hostID)
            }.sorted { $0.name < $1.name }
            Task { @MainActor in self?.hosts = found }
        }
        b.start(queue: .main)
        browser = b
    }

    // MARK: 連線

    /// 連到指定主機。
    /// - Parameter viewPixels: 手機顯示區的像素大小，主機據此決定編碼解析度
    func connect(to host: DiscoveredHost, viewPixels: CGSize) {
        // 連線前先驗證本人（Face ID，失敗可改用手機密碼）：手機遺失時，撿到的人拿不到 Mac 的控制權
        let context = LAContext()
        context.localizedFallbackTitle = "輸入手機密碼"
        Task { @MainActor in
            do {
                guard try await context.evaluatePolicy(.deviceOwnerAuthentication,
                                                       localizedReason: "連線到 \(host.name)") else { return }
            } catch {
                state = .failed("未通過身分驗證")
                return
            }
            reconnectAttempt = 0
            startConnection(to: host, viewPixels: viewPixels)
        }
    }

    private func startConnection(to host: DiscoveredHost, viewPixels: CGSize, reconnecting: Bool = false) {
        reconnectTask?.cancel()
        closeLink()
        saverActive = false
        lastHost = host
        lastViewPixels = viewPixels
        if !reconnecting { state = .connecting(host.name) }
        let l = ClientLink(endpoint: host.endpoint, host: host)
        l.renderer = renderer
        l.onPairingCode = { [weak self] code in
            Task { @MainActor in self?.state = .pairing(name: host.name, code: code) }
        }
        l.onRejected = { [weak self] reason in
            Task { @MainActor in self?.rejection = reason }
        }
        l.onSecured = { [weak l] in
            let w = UInt16(max(viewPixels.width, viewPixels.height))
            let h = UInt16(min(viewPixels.width, viewPixels.height))
            l?.send(.hello, HelloMessage(viewWidth: w, viewHeight: h).encode())
        }
        l.onHelloAck = { [weak self] ack in
            Task { @MainActor in
                guard let self else { return }
                self.desktopSize = CGSize(width: Int(ack.desktopWidth), height: Int(ack.desktopHeight))
                self.state = .connected(host.name)
                self.reconnectAttempt = 0
                self.syncSettingsToHost()
            }
        }
        l.onHostClipboard = { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                if text.isEmpty {
                    self.showToast("Mac 的剪貼簿是空的")
                } else {
                    UIPasteboard.general.string = text
                    self.showToast("已拷貝到手機剪貼簿")
                }
            }
        }
        l.onDisplayInfo = { [weak self] info in
            Task { @MainActor in
                self?.displayCount = Int(info.count)
                self?.currentDisplay = Int(info.current)
            }
        }
        l.onCursor = { [weak self] c in
            Task { @MainActor in
                self?.cursor = CGPoint(x: NormalizedCoordinate.decode(c.x), y: NormalizedCoordinate.decode(c.y))
                self?.cursorRevision += 1
            }
        }
        l.onPong = { [weak self] rtt in
            Task { @MainActor in self?.rttMs = rtt }
        }
        l.onProbeResult = { [weak self] ms in
            Task { @MainActor in self?.probeSamples.append(ms) }
        }
        l.onEnded = { [weak self, weak l] in
            Task { @MainActor in
                guard let self, self.link === l else { return }
                self.link = nil
                self.statsTimer?.invalidate()
                self.statsTimer = nil
                // 沒被明確拒絕的中斷（切換網路、手機睡眠、Wi-Fi 閃斷）自動重連，不必回清單重點
                if self.rejection == nil, self.desktopSize != nil, self.lastHost != nil, self.scheduleReconnect() { return }
                self.desktopSize = nil
                self.state = .failed(self.rejection ?? "連線中斷")
                self.rejection = nil
                self.reconnectAttempt = 0
            }
        }
        link = l
        l.start()

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// 要求主機切換畫質：放大看小字時要原生解析度，平常縮到手機像素省流量。
    func requestNativeDetail(_ native: Bool) {
        desiredNative = native
        guard native != requestedNativeDetail else { return }
        requestedNativeDetail = native
        link?.send(.setDetail, Data([native ? 1 : 0]))
    }

    // MARK: 自動重連

    /// 排程下一次重連；超過次數上限回傳 false，由呼叫端顯示失敗。
    private func scheduleReconnect() -> Bool {
        guard reconnectAttempt < Self.reconnectDelays.count, let host = lastHost else { return false }
        let delay = Self.reconnectDelays[reconnectAttempt]
        reconnectAttempt += 1
        state = .reconnecting(host.name)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let host = self.lastHost else { return }
            self.startConnection(to: host, viewPixels: self.lastViewPixels, reconnecting: true)
        }
        return true
    }

    /// App 回到前景：正在等下一次重連就不要再等，馬上試。
    func appBecameActive() {
        guard case .reconnecting = state, let host = lastHost else { return }
        reconnectTask?.cancel()
        startConnection(to: host, viewPixels: lastViewPixels, reconnecting: true)
    }

    // MARK: 剪貼簿

    /// 把手機剪貼簿的文字送到 Mac 並貼上（⌘V）。
    func pasteToMac() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            showToast("手機剪貼簿沒有文字")
            return
        }
        link?.send(.clipboard, Data(text.utf8.prefix(1_000_000)))
        // 主機寫剪貼簿是非同步的，稍等一下再送 ⌘V，否則可能貼到舊內容
        let mods = consumeModifiers()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.tapKey(ANSIKeyCodes.code(for: "v") ?? 9, modifiers: mods.union(.command))
        }
    }

    /// 在 Mac 上拷貝（⌘C），再把 Mac 的剪貼簿文字取回手機。
    func copyFromMac() {
        let mods = consumeModifiers()
        tapKey(ANSIKeyCodes.code(for: "c") ?? 8, modifiers: mods.union(.command))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.link?.send(.clipboard, Data())
        }
    }

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: 修飾鍵

    func toggleModifier(_ m: KeyModifiers) {
        if armedModifiers.contains(m) { armedModifiers.remove(m) } else { armedModifiers.insert(m) }
    }

    /// 取出目前武裝的修飾鍵並清掉（用掉一次就放開）。
    func consumeModifiers() -> KeyModifiers {
        defer { armedModifiers = [] }
        return armedModifiers
    }

    // MARK: 省流量與聲音

    func setSaverPreference(_ p: SaverPreference) {
        saverPreference = p
        UserDefaults.standard.set(p.rawValue, forKey: "saverPreference")
        syncSettingsToHost()
    }

    /// 目前實際是否該開省流量：偏好「開」，或「自動」且在計量網路上。
    var saverShouldBeOn: Bool {
        switch saverPreference {
        case .on: true
        case .off: false
        case .auto: networkIsExpensive
        }
    }

    func setAudio(_ on: Bool) {
        audioEnabled = on
        link?.setAudioPlayback(on)
        link?.send(.setAudio, Data([on ? 1 : 0]))
    }

    /// 連上（或重連上）後，把手機這邊的設定重送給主機：畫質等級、省流量、聲音。
    private func syncSettingsToHost() {
        guard let link else { return }
        requestedNativeDetail = false
        if desiredNative {
            requestedNativeDetail = true
            link.send(.setDetail, Data([1]))
        }
        // 新連線的主機預設是關；只在跟主機現況不同時才送
        if saverShouldBeOn != saverActive {
            saverActive = saverShouldBeOn
            link.send(.setSaver, Data([saverActive ? 1 : 0]))
        }
        if audioEnabled {
            link.setAudioPlayback(true)
            link.send(.setAudio, Data([1]))
        }
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                self.networkIsExpensive = path.isExpensive
                if self.link != nil, self.saverShouldBeOn != self.saverActive { self.syncSettingsToHost() }
            }
        }
        m.start(queue: .main)
        pathMonitor = m
    }

    /// 切到下一台螢幕（只有一台時不做事）。
    func cycleDisplay() {
        guard displayCount > 1 else { return }
        link?.send(.selectDisplay, Data([UInt8((currentDisplay + 1) % displayCount)]))
    }

    /// 只關掉目前的連線與計時器，不動畫面狀態（重連時畫面要保留）。
    private func closeLink() {
        link?.stop()
        link = nil
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// 使用者主動斷線：不重連、回到清單。
    func disconnect() {
        reconnectTask?.cancel()
        lastHost = nil
        reconnectAttempt = 0
        closeLink()
        desktopSize = nil
        requestedNativeDetail = false
        desiredNative = false
        audioEnabled = false
        armedModifiers = []
        rttMs = nil
        fps = 0
        kbps = 0
        if case .connected = state { state = .browsing }
        if case .connecting = state { state = .browsing }
        if case .pairing = state { state = .browsing }
        if case .reconnecting = state { state = .browsing }
        if case .failed = state { state = .browsing }
    }

    /// 由畫面提供硬體解碼顯示用的 renderer。
    func attach(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
        link?.renderer = renderer
        link?.resync()
    }

    // MARK: 輸入

    func send(_ event: InputEvent) {
        link?.send(.input, event.encode())
    }

    /// 移動游標到正規化座標並通知主機。
    func moveCursor(to p: CGPoint) {
        cursor = CGPoint(x: min(max(p.x, 0), 1), y: min(max(p.y, 0), 1))
        send(.mouseMove(x: NormalizedCoordinate.encode(cursor.x), y: NormalizedCoordinate.encode(cursor.y)))
    }

    func click(_ button: MouseButton) {
        send(.mouseButton(button, down: true))
        send(.mouseButton(button, down: false))
    }

    func tapKey(_ code: UInt16, modifiers: KeyModifiers = []) {
        send(.key(code: code, down: true, modifiers: modifiers))
        send(.key(code: code, down: false, modifiers: modifiers))
    }

    private func tick() {
        guard let link else { return }
        let s = link.takeSecondStats()
        fps = s.frames
        kbps = Double(s.bytes) * 8 / 1000
        totalMB = Double(s.totalBytes) / 1_000_000
        link.ping()
    }
}

/// 網路與解碼工作者，全部在自己的序列佇列上執行。
final class ClientLink: @unchecked Sendable {
    static let log = Logger(subsystem: "tw.firstfu.DeskPilot", category: "client")
    struct SecondStats {
        var frames = 0
        var bytes: UInt64 = 0
        var totalBytes: UInt64 = 0
    }

    private let queue = DispatchQueue(label: "deskpilot.client", qos: .userInteractive)
    private let framed: FramedConnection
    private var formatDescription: CMVideoFormatDescription?
    private var waitingForKeyframe = true
    private let counters = OSAllocatedUnfairLock(initialState: (frames: 0, lastBytes: UInt64(0)))
    private let rendererBox = OSAllocatedUnfairLock<AVSampleBufferVideoRenderer?>(initialState: nil)

    var renderer: AVSampleBufferVideoRenderer? {
        get { rendererBox.withLock { $0 } }
        set { rendererBox.withLock { $0 = newValue } }
    }

    /// 交握完成、可以送 Hello 時呼叫。
    var onSecured: (() -> Void)?
    /// 首次配對時呼叫，參數為要給使用者核對的 6 位數字。
    var onPairingCode: ((String) -> Void)?
    /// 主機拒絕（不認得這支手機、使用者按拒絕）時呼叫，參數為給使用者看的原因。
    var onRejected: ((String) -> Void)?
    var onHelloAck: ((HelloAckMessage) -> Void)?
    var onCursor: ((CursorMessage) -> Void)?
    var onDisplayInfo: ((DisplayInfoMessage) -> Void)?
    var onHostClipboard: ((String) -> Void)?
    /// 聲音播放器；開啟聲音後收到格式才建立。只在 `queue` 上存取。
    private var audioPlayer: AudioPlayer?
    private var audioPlaybackWanted = false

    var onPong: ((Double) -> Void)?
    /// 收到帶探針編號的影格時呼叫，參數為探針來回毫秒數。
    var onProbeResult: ((Double) -> Void)?
    /// 已送出、尚未收到回應的探針送出時間（奈秒）。只在 `queue` 上存取。
    private var probeSentAt: [UInt32: UInt64] = [:]
    var onEnded: (() -> Void)?

    private let host: DiscoveredHost
    /// 下次連線強制走配對（手動輸入 IP 被主機拒絕後設定，配對成功清除）。存 UserDefaults，換一個連線物件也記得。
    private static var forcePairNext: Bool {
        get { UserDefaults.standard.bool(forKey: "deskpilot.forcePairNext") }
        set { UserDefaults.standard.set(newValue, forKey: "deskpilot.forcePairNext") }
    }
    /// 交握用的臨時金鑰與這次的模式；只在 `queue` 上存取。
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var pendingPairKey: (hostID: UUID, key: Data)?
    private var resuming = false

    init(endpoint: NWEndpoint, host: DiscoveredHost) {
        self.host = host
        framed = FramedConnection(connection: NWConnection(to: endpoint, using: FramedConnection.tcpParameters()),
                                  queue: queue)
    }

    /// 連上後第一件事：送交握。有存過這台主機的金鑰就走驗證，沒有就發起配對。
    private func sendHandshake() {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        ephemeral = priv
        // 手動輸入 IP（WireGuard）時沒有 Bonjour 公告的主機 ID：有任何配對紀錄就走驗證，
        // 交握回覆帶回主機 ID 後再找對應金鑰。配對只在區網進行，在外面也沒人能按允許
        // 上次被主機拒絕（不認得這支手機）就改走配對，否則會用舊金鑰無限重試
        let known = !Self.forcePairNext && (host.hostID.map { PairingStore.key(for: $0) != nil } ?? !PairingStore.all().isEmpty)
        resuming = known
        let hs = HandshakeMessage(mode: known ? .resume : .pair, deviceID: PairingStore.localID,
                                  ephemeralKey: priv.publicKey.rawRepresentation, deviceName: UIDevice.current.name)
        framed.send(.handshake, hs.encode())
    }

    private func handleHandshakeAck(_ payload: Data) {
        guard let priv = ephemeral, let ack = try? HandshakeAckMessage.decode(payload) else {
            fail("主機回覆格式錯誤")
            return
        }
        ephemeral = nil
        // 有公告 ID 時必須一致，避免被同名的假主機騙去配對
        if let expected = host.hostID, expected != ack.hostID {
            fail("主機身分與公告不符")
            return
        }
        let psk = PairingStore.key(for: ack.hostID)
        if resuming, psk == nil {
            Self.forcePairNext = true
            fail("這台 Mac 還沒配對過，請再點一次連線進行配對（要在 Mac 上按允許）")
            return
        }
        guard let keys = try? SessionKeys.derive(myPrivate: priv, theirPublic: ack.ephemeralKey,
                                                 clientEphemeral: priv.publicKey.rawRepresentation,
                                                 hostEphemeral: ack.ephemeralKey,
                                                 deviceID: PairingStore.localID, hostID: ack.hostID, psk: psk) else {
            fail("金鑰交換失敗")
            return
        }
        framed.enableEncryption(send: keys.clientToHost, receive: keys.hostToClient)
        Self.log.info("交握完成，模式：\(psk != nil ? "驗證" : "配對", privacy: .public)")
        if psk != nil {
            onSecured?()
        } else {
            pendingPairKey = (ack.hostID, keys.pairingKey)
            onPairingCode?(keys.pairingCode)
        }
    }

    /// 主動斷線並留下原因（給使用者看，也印到 console 方便除錯）。
    private func fail(_ reason: String) {
        Self.log.notice("斷線：\(reason, privacy: .public)")
        onRejected?(reason)
        framed.cancel()
    }

    func start() {
        framed.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        framed.onStateChange = { [weak self] state in
            switch state {
            case .ready: self?.sendHandshake()
            case .failed(let e):
                Self.log.notice("連線失敗：\(String(describing: e), privacy: .public)")
                self?.onEnded?()
            case .cancelled: self?.onEnded?()
            default: break
            }
        }
        framed.start()
    }

    func stop() {
        framed.cancel()
        queue.async {
            self.audioPlayer?.stop()
            self.audioPlayer = nil
        }
    }

    /// 開關手機端的聲音播放（主機端的串流開關另外用 `.setAudio` 送）。
    func setAudioPlayback(_ on: Bool) {
        queue.async {
            self.audioPlaybackWanted = on
            if !on {
                self.audioPlayer?.stop()
                self.audioPlayer = nil
            }
        }
    }

    func send(_ type: MessageType, _ payload: Data) {
        framed.send(type, payload)
    }

    /// 送出延遲探針並記錄送出時間。
    func sendProbe(_ id: UInt32) {
        queue.async {
            self.probeSentAt[id] = DispatchTime.now().uptimeNanoseconds
            var w = ByteWriter()
            w.u32(id)
            self.framed.send(.probe, w.data)
        }
    }

    /// 顯示層換新（或第一次掛上）時，從下一張關鍵幀重新開始解碼。
    func resync() {
        queue.async {
            self.waitingForKeyframe = true
            self.framed.send(.requestKeyframe)
        }
    }

    func ping() {
        var w = ByteWriter()
        w.u64(DispatchTime.now().uptimeNanoseconds)
        framed.send(.ping, w.data)
    }

    func takeSecondStats() -> SecondStats {
        let total = framed.currentStats.bytesReceived
        return counters.withLock { c in
            let s = SecondStats(frames: c.frames, bytes: total - c.lastBytes, totalBytes: total)
            c.frames = 0
            c.lastBytes = total
            return s
        }
    }

    private func handle(_ type: MessageType, _ payload: Data) {
        // 交握完成前只接受交握回覆；其他明文訊息可能是假主機，直接斷線
        if ephemeral != nil, type != .handshakeAck, type != .authFailed {
            fail("交握前收到非預期訊息（\(type.rawValue)）")
            return
        }
        switch type {
        case .handshakeAck:
            handleHandshakeAck(payload)
        case .authFailed:
            // 主機已不認得這支手機（例如在 Mac 上被移除）：刪掉本地金鑰，下次連線改走配對
            // 手動輸入 IP 時沒有主機 ID、不知道該刪哪把金鑰，改記「下次走配對」，不然會用舊金鑰無限重試
            if let id = host.hostID { PairingStore.remove(id: id) } else { Self.forcePairNext = true }
            onRejected?("這台 Mac 已不認得這支手機，請再點一次重新配對")
        case .pairResult:
            guard let pending = pendingPairKey else { return }
            pendingPairKey = nil
            if payload.first == 1 {
                PairingStore.save(id: pending.hostID, name: host.name, key: pending.key)
                Self.forcePairNext = false
                onSecured?()
            } else {
                onRejected?("Mac 上拒絕了配對")
            }
        case .helloAck:
            if let ack = try? HelloAckMessage.decode(payload) { onHelloAck?(ack) }
        case .videoFormat:
            if let f = try? VideoFormatMessage.decode(payload) { formatDescription = Self.makeFormat(f) }
        case .videoFrame:
            guard let frame = try? VideoFrameMessage.decode(payload) else { return }
            if frame.probeId != 0, let sent = probeSentAt.removeValue(forKey: frame.probeId) {
                onProbeResult?(Double(DispatchTime.now().uptimeNanoseconds - sent) / 1_000_000)
            }
            render(frame)
        case .displayInfo:
            if let d = try? DisplayInfoMessage.decode(payload) { onDisplayInfo?(d) }
        case .hostClipboard:
            onHostClipboard?(String(data: payload, encoding: .utf8) ?? "")
        case .audioFormat:
            guard audioPlaybackWanted, let f = try? AudioFormatMessage.decode(payload) else { return }
            audioPlayer?.stop()
            audioPlayer = AudioPlayer(sampleRate: Double(f.sampleRate), channels: AVAudioChannelCount(f.channels))
            do { try audioPlayer?.start() } catch {
                Self.log.error("聲音播放啟動失敗：\(error.localizedDescription, privacy: .public)")
                audioPlayer = nil
            }
        case .audioFrame:
            audioPlayer?.play(payload)
        case .cursor:
            if let c = try? CursorMessage.decode(payload) { onCursor?(c) }
        case .pong:
            var r = ByteReader(payload)
            if let sent = try? r.u64() {
                onPong?(Double(DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000)
            }
        default:
            break
        }
    }

    private func render(_ frame: VideoFrameMessage) {
        counters.withLock { $0.frames += 1 }
        // 顯示層還沒準備好時整段丟棄；畫面掛上後 `resync()` 會再要一張關鍵幀
        guard let renderer, let fmt = formatDescription else {
            waitingForKeyframe = true
            return
        }
        if waitingForKeyframe {
            guard frame.isKeyframe else { return }
            waitingForKeyframe = false
        }
        guard let sample = Self.makeSample(frame.payload, format: fmt) else { return }
        if renderer.status == .failed {
            // 解碼器壞掉時清空並要求關鍵幀，從乾淨狀態重來
            renderer.flush()
            waitingForKeyframe = true
            framed.send(.requestKeyframe)
            return
        }
        renderer.enqueue(sample)
    }

    private static func makeFormat(_ f: VideoFormatMessage) -> CMVideoFormatDescription? {
        let sets = f.parameterSets
        guard !sets.isEmpty else { return nil }
        // 參數集指標只在 withUnsafeBytes 內有效，先全部複製成連續陣列再一次傳入
        let buffers = sets.map { [UInt8]($0) }
        var desc: CMFormatDescription?
        var status: OSStatus = -1
        let pointers = buffers.map { buf -> UnsafePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: buf.count)
            p.initialize(from: buf, count: buf.count)
            return UnsafePointer(p)
        }
        defer { pointers.forEach { UnsafeMutablePointer(mutating: $0).deallocate() } }
        let sizes = buffers.map(\.count)
        switch f.codec {
        case .hevc:
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &desc)
        case .h264:
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
        }
        return status == noErr ? desc : nil
    }

    private static func makeSample(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }

        // 不排程、收到就顯示：省掉顯示層自己的緩衝延遲
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}
