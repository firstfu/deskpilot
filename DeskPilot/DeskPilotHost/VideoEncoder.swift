//
//  VideoEncoder.swift
//  DeskPilotHost
//
//  VideoToolbox 硬體編碼器包裝。設定以「低延遲」優先：
//  不用 B-frame（不重排）、開啟 low-latency rate control、關鍵幀只在需要時才產生
//  （桌面大多靜止，定期關鍵幀只是浪費流量）。
//

import CoreMedia
import VideoToolbox
import os

final class VideoEncoder: @unchecked Sendable {
    /// 一個編碼完成的影格。
    struct EncodedFrame {
        var isKeyframe: Bool
        /// AVCC 格式（每個 NAL 前 4 bytes 長度）。
        var data: Data
        /// 只在關鍵幀時帶，供用戶端（重新）建立解碼器。
        var format: VideoFormatMessage?
        /// 延遲探針編號（0 = 無）。
        var probeId: UInt32 = 0
        /// 送進編碼器到編好的耗時（毫秒）。
        var encodeMs = 0.0
    }

    let codec: VideoCodec
    /// 輸出解析度；擷取端換尺寸時，用來丟掉尺寸不符的舊畫面。
    let width: Int
    let height: Int
    private let session: VTCompressionSession
    private let forceKeyframe = OSAllocatedUnfairLock(initialState: true)

    /// 編碼完成時呼叫（在 VideoToolbox 內部執行緒上）。
    var onEncoded: ((EncodedFrame) -> Void)?

    /// 建立編碼器。依序嘗試 HEVC 低延遲 → H.264 低延遲 → HEVC 一般模式，
    /// 因為 low-latency rate control 對 HEVC 的支援依機型而定。
    /// - Parameters:
    ///   - width: 影像像素寬
    ///   - height: 影像像素高
    ///   - bitrate: 平均位元率（bps），只在畫面變動時才會用到
    /// - Throws: 所有組合都建立失敗時拋出 `NSError`（OSStatus）。
    init(width: Int, height: Int, bitrate: Int) throws {
        self.width = width
        self.height = height
        var attempts: [(CMVideoCodecType, VideoCodec, Bool)] = [
            (kCMVideoCodecType_HEVC, .hevc, true),
            (kCMVideoCodecType_H264, .h264, true),
            (kCMVideoCodecType_HEVC, .hevc, false),
        ]
        // 量測用：DESKPILOT_CODEC=h264 時優先試 H.264，方便 A/B 比較編碼延遲
        if ProcessInfo.processInfo.environment["DESKPILOT_CODEC"] == "h264" {
            attempts.swapAt(0, 1)
        }
        var lastStatus: OSStatus = noErr
        for (cmCodec, codec, lowLatency) in attempts {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var out: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: cmCodec,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &out)
            if lastStatus == noErr, let out {
                self.session = out
                self.codec = codec
                Self.configure(out, codec: codec, bitrate: bitrate)
                HostController.log.notice("編碼器：\(codec == .hevc ? "HEVC" : "H.264", privacy: .public) 低延遲=\(lowLatency, privacy: .public) \(width, privacy: .public)×\(height, privacy: .public)")
                return
            }
        }
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(lastStatus))
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    private static func configure(_ s: VTCompressionSession, codec: VideoCodec, bitrate: Int) {
        func set(_ key: CFString, _ value: Any) {
            let status = VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
            if status != noErr {
                HostController.log.notice("編碼器不支援 \(key as String, privacy: .public)（\(status, privacy: .public)）")
            }
        }
        // 編碼器內部最多只能壓 0 幀：送進一幀就立刻吐出一幀，不為了品質先攢幾幀
        set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0)
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // 關鍵幀由用戶端要求才產生；設很大的間隔避免編碼器自作主張
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 36000)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        // 明確標成 sRGB 色域（BT.709 原色／轉換函數／矩陣）：沒標的話解碼端自己猜，顏色常偏淡或偏色
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// 執行中調整平均位元率（依內容自動切換用）。
    func setBitrate(_ bitrate: Int) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFTypeRef)
    }

    /// 下一個影格強制編成關鍵幀（新用戶端加入或解碼失敗時）。
    func requestKeyframe() {
        forceKeyframe.withLock { $0 = true }
    }

    /// 送一張畫面進編碼器；結果非同步回到 `onEncoded`。
    /// - Parameter probeId: 延遲探針編號，原樣帶到輸出影格（0 = 無）
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, probeId: UInt32 = 0) {
        let start = DispatchTime.now().uptimeNanoseconds
        let force = forceKeyframe.withLock { v -> Bool in
            defer { v = false }
            return v
        }
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            self.handle(sampleBuffer, probeId: probeId, encodeMs: ms)
        }
    }

    private func handle(_ sb: CMSampleBuffer, probeId: UInt32, encodeMs: Double) {
        guard let block = sb.dataBuffer, let data = try? block.dataBytes() else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync
        var format: VideoFormatMessage?
        if isKey, let desc = sb.formatDescription {
            format = VideoFormatMessage(codec: codec, parameterSets: Self.parameterSets(desc, codec: codec))
        }
        onEncoded?(EncodedFrame(isKeyframe: isKey, data: data, format: format, probeId: probeId, encodeMs: encodeMs))
    }

    /// 從格式描述取出參數集（H.264: SPS/PPS；HEVC: VPS/SPS/PPS）。
    private static func parameterSets(_ desc: CMFormatDescription, codec: VideoCodec) -> [Data] {
        /// 取第 index 個參數集；index 傳 0 且只要 count 時 ptr/size 不使用。
        func get(_ index: Int, _ ptr: inout UnsafePointer<UInt8>?, _ size: inout Int, _ count: inout Int) -> OSStatus {
            switch codec {
            case .hevc:
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    desc, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            case .h264:
                return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    desc, parameterSetIndex: index, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
        }
        var ptr: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        guard get(0, &ptr, &size, &count) == noErr else { return [] }
        var sets: [Data] = []
        for i in 0..<count where get(i, &ptr, &size, &count) == noErr {
            if let ptr { sets.append(Data(bytes: ptr, count: size)) }
        }
        return sets
    }
}
