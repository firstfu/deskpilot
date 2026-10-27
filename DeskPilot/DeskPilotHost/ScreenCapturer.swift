//
//  ScreenCapturer.swift
//  DeskPilotHost
//
//  用 ScreenCaptureKit 擷取指定螢幕。重點：
//  - 只轉交「內容有變」的影格（status == .complete）；畫面靜止時 ScreenCaptureKit 送的是 .idle，
//    我們直接丟掉，所以閒置時影像流量是 0
//  - 直接輸出 420v，與硬體編碼器原生格式一致，省一次色彩轉換
//  - 不擷取游標，游標改由手機本地繪製（零延遲手感）
//

import CoreMedia
import ScreenCaptureKit

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private var config: SCStreamConfiguration?
    private let queue = DispatchQueue(label: "deskpilot.capture", qos: .userInteractive)

    /// 有新影格時呼叫（在擷取佇列上）。第三個參數是變動面積佔整個畫面的比例（0～1，未知時為 1）。
    var onFrame: ((CVPixelBuffer, CMTime, Double) -> Void)?
    /// 有新的系統聲音時呼叫（在聲音佇列上）。
    var onAudio: ((CMSampleBuffer) -> Void)?
    private let audioQueue = DispatchQueue(label: "deskpilot.capture.audio", qos: .userInteractive)
    /// 擷取意外停止時呼叫。
    var onStop: ((Error) -> Void)?

    /// 開始擷取指定螢幕。
    /// - Parameters:
    ///   - displayID: 要擷取的螢幕
    ///   - width: 輸出像素寬
    ///   - height: 輸出像素高
    /// - Throws: 沒有螢幕錄製權限或找不到螢幕時拋出 ScreenCaptureKit 的錯誤。
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int = 60, audio: Bool = false) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "DeskPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到螢幕"])
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        // 系統聲音：預設關，手機要求時才用 updateConfiguration 打開；排除自己，避免回授
        config.capturesAudio = audio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        // 輸出轉成 sRGB + BT.709：否則廣色域螢幕（內建 XDR）的 P3 色會被當成 709 解碼而偏色
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        // 佇列太深會增加延遲，太淺編碼器忙時會掉幀；靜止補強會長期持有一張，所以比最低值 3 多留一格
        config.queueDepth = 4

        // 測試用：環境變數 DESKPILOT_EXCLUDE_BUNDLES（逗號分隔 bundle id）指定的 App 不擷取。
        // 用模擬器當用戶端時必須排除模擬器，否則它顯示串流畫面 → 被擷取 → 再串流，形成無限迴圈，量不到真實數字
        let excludedIDs = Set((ProcessInfo.processInfo.environment["DESKPILOT_EXCLUDE_BUNDLES"] ?? "")
            .split(separator: ",").map(String.init))
        let excludedApps = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
        self.config = config
    }

    /// 擷取中改輸出大小（手機切換畫質時用），不必重開擷取。
    func reconfigure(width: Int, height: Int, fps: Int) async throws {
        guard let stream, let config else { return }
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        try await stream.updateConfiguration(config)
    }

    /// 開關系統聲音擷取。
    func setAudio(_ on: Bool) async throws {
        guard let stream, let config, config.capturesAudio != on else { return }
        config.capturesAudio = on
        try await stream.updateConfiguration(config)
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    /// 停止並等到確實停下；換螢幕前使用，避免舊螢幕的影格混進新解析度的編碼器。
    func stopAndWait() async {
        let s = stream
        stream = nil
        try? await s?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            if sampleBuffer.isValid { onAudio?(sampleBuffer) }
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let dirty = Self.dirtyFraction(attachments.first?[.dirtyRects], pixelBuffer)
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp, dirty)
    }

    /// 變動矩形的面積總和 ÷ 畫面面積。矩形座標與輸出像素同一個空間；解析不出來就當整個畫面都變。
    private static func dirtyFraction(_ raw: Any?, _ pb: CVPixelBuffer) -> Double {
        guard let rects = raw as? [Any] else { return 1 }
        let total = Double(CVPixelBufferGetWidth(pb) * CVPixelBufferGetHeight(pb))
        guard total > 0 else { return 1 }
        var area = 0.0
        for r in rects {
            if let d = r as? NSDictionary, let rect = CGRect(dictionaryRepresentation: d) {
                area += Double(rect.width * rect.height)
            } else if let v = r as? CGRect {
                area += Double(v.width * v.height)
            } else {
                return 1
            }
        }
        return min(1, area / total)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
