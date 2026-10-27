//
//  AudioEncoder.swift
//  DeskPilotHost
//
//  把 ScreenCaptureKit 的系統聲音（48 kHz 立體聲 PCM）壓成 AAC-LC。
//  靜音時完全不輸出：沒有聲音就沒有流量。
//

import AVFoundation
import CoreMedia

final class AudioEncoder {
    static let sampleRate = 48_000.0
    static let channels: AVAudioChannelCount = 2
    private static let frameSize: AVAudioFrameCount = 1024

    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioEncoder.sampleRate,
                                          channels: AudioEncoder.channels, interleaved: false)!
    private let converter: AVAudioConverter
    private let outFormat: AVAudioFormat
    private var fifo: [[Float]] = [[], []]
    /// 連續靜音的 AAC 區塊數；超過門檻就不再輸出。
    private var silentChunks = 0
    private static let silenceHoldChunks = 24  // 約 0.5 秒

    init?(bitrate: Int = 64_000) {
        var desc = AudioStreamBasicDescription(mSampleRate: Self.sampleRate, mFormatID: kAudioFormatMPEG4AAC,
                                               mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: 1024,
                                               mBytesPerFrame: 0, mChannelsPerFrame: Self.channels,
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let out = AVAudioFormat(streamDescription: &desc),
              let conv = AVAudioConverter(from: pcmFormat, to: out) else { return nil }
        conv.bitRate = bitrate
        converter = conv
        outFormat = out
    }

    /// 餵入一段擷取到的聲音，回傳壓好的 AAC 封包（可能為空）。
    func encode(_ sample: CMSampleBuffer) -> [Data] {
        append(sample)
        var packets: [Data] = []
        while fifo[0].count >= Int(Self.frameSize) {
            guard let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: Self.frameSize) else { break }
            pcm.frameLength = Self.frameSize
            var peak: Float = 0
            for c in 0..<Int(Self.channels) {
                let dst = pcm.floatChannelData![c]
                for i in 0..<Int(Self.frameSize) {
                    let v = fifo[c][i]
                    dst[i] = v
                    peak = max(peak, abs(v))
                }
                fifo[c].removeFirst(Int(Self.frameSize))
            }
            if peak < 0.0005 {
                silentChunks += 1
                if silentChunks > Self.silenceHoldChunks { continue }
            } else {
                silentChunks = 0
            }
            if let p = compress(pcm) { packets.append(p) }
        }
        return packets
    }

    /// 重置累積資料（關閉聲音再打開時）。
    func reset() {
        fifo = [[], []]
        silentChunks = 0
        converter.reset()
    }

    private func compress(_ pcm: AVAudioPCMBuffer) -> Data? {
        let out = AVAudioCompressedBuffer(format: outFormat, packetCapacity: 1, maximumPacketSize: 1024)
        var fed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if fed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, out.packetCount > 0, out.byteLength > 0 else { return nil }
        return Data(bytes: out.data, count: Int(out.byteLength))
    }

    /// 把 CMSampleBuffer 內的 PCM 拆成左右聲道放進 FIFO（來源可能是分離或交錯格式）。
    private func append(_ sample: CMSampleBuffer) {
        try? sample.withAudioBufferList { list, _ in
            guard let asbd = sample.formatDescription?.audioStreamBasicDescription,
                  asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32 else { return }
            let frames = CMSampleBufferGetNumSamples(sample)
            let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            if planar {
                for c in 0..<min(list.count, 2) {
                    guard let p = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                    fifo[c].append(contentsOf: UnsafeBufferPointer(start: p, count: frames))
                }
                if list.count == 1 { fifo[1].append(contentsOf: fifo[0].suffix(frames)) }
            } else if let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(Int(asbd.mChannelsPerFrame), 1)
                for i in 0..<frames {
                    fifo[0].append(p[i * ch])
                    fifo[1].append(p[i * ch + (ch > 1 ? 1 : 0)])
                }
            }
        }
    }
}
