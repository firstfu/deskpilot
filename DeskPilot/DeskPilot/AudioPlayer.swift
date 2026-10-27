//
//  AudioPlayer.swift
//  DeskPilot（iOS 用戶端）
//
//  播放主機傳來的 AAC 系統聲音。延遲優先：排隊太多就丟掉新封包，寧可斷一下也不要越播越落後。
//

import AVFoundation
import os

final class AudioPlayer: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pcmFormat: AVAudioFormat
    private let inFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// 已排進播放器、還沒播完的區塊數（每塊 1024 frames ≈ 21 ms）。
    private let pending = OSAllocatedUnfairLock(initialState: 0)
    private static let maxPending = 10

    init?(sampleRate: Double, channels: AVAudioChannelCount) {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: channels, interleaved: false) else { return nil }
        var desc = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: channels,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let comp = AVAudioFormat(streamDescription: &desc),
              let conv = AVAudioConverter(from: comp, to: pcm) else { return nil }
        pcmFormat = pcm
        inFormat = comp
        converter = conv
    }

    func start() throws {
        // 靜音開關或其他 App 的聲音不該擋住遠端聲音；也不蓋掉其他 App，所以用混音
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: pcmFormat)
        try engine.start()
        node.play()
    }

    func stop() {
        node.stop()
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 解一包 AAC 並排進播放器。
    func play(_ packet: Data) {
        guard pending.withLock({ $0 }) < Self.maxPending, !packet.isEmpty else { return }
        let comp = AVAudioCompressedBuffer(format: inFormat, packetCapacity: 1, maximumPacketSize: packet.count)
        packet.withUnsafeBytes { comp.data.copyMemory(from: $0.baseAddress!, byteCount: packet.count) }
        comp.byteLength = UInt32(packet.count)
        comp.packetCount = 1
        comp.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                         mDataByteSize: UInt32(packet.count))
        guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024) else { return }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return comp
        }
        guard status != .error, pcm.frameLength > 0 else { return }
        pending.withLock { $0 += 1 }
        node.scheduleBuffer(pcm, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.pending.withLock { $0 -= 1 }
        }
    }
}
