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
    }

    let codec: VideoCodec
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
        let attempts: [(CMVideoCodecType, VideoCodec, Bool)] = [
            (kCMVideoCodecType_HEVC, .hevc, true),
            (kCMVideoCodecType_H264, .h264, true),
            (kCMVideoCodecType_HEVC, .hevc, false),
        ]
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
            VTSessionSetProperty(s, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, true)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, 60)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        // 關鍵幀由用戶端要求才產生；設很大的間隔避免編碼器自作主張
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 36000)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    /// 下一個影格強制編成關鍵幀（新用戶端加入或解碼失敗時）。
    func requestKeyframe() {
        forceKeyframe.withLock { $0 = true }
    }

    /// 送一張畫面進編碼器；結果非同步回到 `onEncoded`。
    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        let force = forceKeyframe.withLock { v -> Bool in
            defer { v = false }
            return v
        }
        let props: CFDictionary? = force ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary : nil
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.handle(sampleBuffer)
        }
    }

    private func handle(_ sb: CMSampleBuffer) {
        guard let block = sb.dataBuffer, let data = try? block.dataBytes() else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync
        var format: VideoFormatMessage?
        if isKey, let desc = sb.formatDescription {
            format = VideoFormatMessage(codec: codec, parameterSets: Self.parameterSets(desc, codec: codec))
        }
        onEncoded?(EncodedFrame(isKeyframe: isKey, data: data, format: format))
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
