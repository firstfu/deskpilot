//
//  ClientSession.swift
//  DeskPilot（iOS 用戶端）
//
//  用 Bonjour 找區網內的主機、建立連線、把收到的影格直接丟給硬體解碼顯示層，並送出輸入事件。
//  影像路徑刻意不經過主執行緒：網路佇列收到 → 組 CMSampleBuffer → 交給 AVSampleBufferVideoRenderer，
//  主執行緒卡頓也不會影響畫面更新。
//

import AVFoundation
import Network
import Observation
import UIKit
import os

/// 區網內找到的主機。
struct DiscoveredHost: Identifiable, Hashable {
    let name: String
    let endpoint: NWEndpoint
    var id: String { name }
}

@MainActor
@Observable
final class ClientSession {
    enum State: Equatable {
        case browsing
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    private(set) var state: State = .browsing
    private(set) var hosts: [DiscoveredHost] = []
    /// 遠端桌面大小（point），用來算長寬比。連上前為 nil。
    private(set) var desktopSize: CGSize?
    /// 游標位置（0...1 正規化）。
    var cursor = CGPoint(x: 0.5, y: 0.5)
    /// 主機回報的游標更新次數；畫面據此判斷要不要跟著移動。
    private(set) var cursorRevision = 0

    private(set) var fps = 0
    private(set) var kbps = 0.0
    private(set) var rttMs: Double?
    private(set) var totalMB = 0.0

    private var browser: NWBrowser?
    private var link: ClientLink?
    private var statsTimer: Timer?
    private var renderer: AVSampleBufferVideoRenderer?

    // MARK: 探索

    func startBrowsing() {
        guard browser == nil else { return }
        let b = NWBrowser(for: .bonjour(type: ProtocolConstants.bonjourType, domain: nil), using: .tcp)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> DiscoveredHost? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                return DiscoveredHost(name: name, endpoint: r.endpoint)
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
        disconnect()
        state = .connecting(host.name)
        let l = ClientLink(endpoint: host.endpoint)
        l.renderer = renderer
        l.onReady = { [weak l] in
            let w = UInt16(max(viewPixels.width, viewPixels.height))
            let h = UInt16(min(viewPixels.width, viewPixels.height))
            l?.send(.hello, HelloMessage(viewWidth: w, viewHeight: h).encode())
        }
        l.onHelloAck = { [weak self] ack in
            Task { @MainActor in
                self?.desktopSize = CGSize(width: Int(ack.desktopWidth), height: Int(ack.desktopHeight))
                self?.state = .connected(host.name)
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
        l.onEnded = { [weak self, weak l] in
            Task { @MainActor in
                guard let self, self.link === l else { return }
                self.link = nil
                self.desktopSize = nil
                self.state = .failed("連線中斷")
            }
        }
        link = l
        l.start()

        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func disconnect() {
        link?.stop()
        link = nil
        statsTimer?.invalidate()
        statsTimer = nil
        desktopSize = nil
        rttMs = nil
        fps = 0
        kbps = 0
        if case .connected = state { state = .browsing }
        if case .connecting = state { state = .browsing }
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

    var onReady: (() -> Void)?
    var onHelloAck: ((HelloAckMessage) -> Void)?
    var onCursor: ((CursorMessage) -> Void)?
    var onPong: ((Double) -> Void)?
    var onEnded: (() -> Void)?

    init(endpoint: NWEndpoint) {
        framed = FramedConnection(connection: NWConnection(to: endpoint, using: FramedConnection.tcpParameters()),
                                  queue: queue)
    }

    func start() {
        framed.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        framed.onStateChange = { [weak self] state in
            switch state {
            case .ready: self?.onReady?()
            case .failed, .cancelled: self?.onEnded?()
            default: break
            }
        }
        framed.start()
    }

    func stop() {
        framed.cancel()
    }

    func send(_ type: MessageType, _ payload: Data) {
        framed.send(type, payload)
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
        switch type {
        case .helloAck:
            if let ack = try? HelloAckMessage.decode(payload) { onHelloAck?(ack) }
        case .videoFormat:
            if let f = try? VideoFormatMessage.decode(payload) { formatDescription = Self.makeFormat(f) }
        case .videoFrame:
            guard let frame = try? VideoFrameMessage.decode(payload) else { return }
            render(frame)
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
