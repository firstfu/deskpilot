//
//  ScreenCapturer.swift
//  DeskPilotHost
//
//  用 ScreenCaptureKit 擷取主螢幕。重點：
//  - 只轉交「內容有變」的影格（status == .complete）；畫面靜止時 ScreenCaptureKit 送的是 .idle，
//    我們直接丟掉，所以閒置時影像流量是 0
//  - 直接輸出 420v，與硬體編碼器原生格式一致，省一次色彩轉換
//  - 不擷取游標，游標改由手機本地繪製（零延遲手感）
//

import CoreMedia
import ScreenCaptureKit

final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "deskpilot.capture", qos: .userInteractive)

    /// 有新影格時呼叫（在擷取佇列上）。
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// 擷取意外停止時呼叫。
    var onStop: ((Error) -> Void)?

    /// 開始擷取主螢幕。
    /// - Parameters:
    ///   - width: 輸出像素寬
    ///   - height: 輸出像素高
    /// - Throws: 沒有螢幕錄製權限或找不到螢幕時拋出 ScreenCaptureKit 的錯誤。
    func start(width: Int, height: Int) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw NSError(domain: "DeskPilot", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到螢幕"])
        }

        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false
        // 佇列太深會增加延遲，太淺編碼器忙時會掉幀；3 是 Apple 建議的低延遲下限
        config.queueDepth = 3

        // 測試用：環境變數 DESKPILOT_EXCLUDE_BUNDLES（逗號分隔 bundle id）指定的 App 不擷取。
        // 用模擬器當用戶端時必須排除模擬器，否則它顯示串流畫面 → 被擷取 → 再串流，形成無限迴圈，量不到真實數字
        let excludedIDs = Set((ProcessInfo.processInfo.environment["DESKPILOT_EXCLUDE_BUNDLES"] ?? "")
            .split(separator: ",").map(String.init))
        let excludedApps = content.applications.filter { excludedIDs.contains($0.bundleIdentifier) }
        let filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
        let s = stream
        stream = nil
        Task { try? await s?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }
}
