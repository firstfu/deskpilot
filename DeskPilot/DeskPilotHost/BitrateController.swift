//
//  BitrateController.swift
//  DeskPilotHost
//
//  依畫面內容自動切換位元率。捲動文字用低位元率就清楚（停下後靠畫質補強），
//  但影片／大面積動畫在低位元率會糊，需要高位元率。
//  分辨方式：手機沒有任何輸入、畫面卻持續大面積變動 → 視為影片／動畫；有輸入 → 視為人在操作（捲動等）。
//

import Foundation
import os

final class BitrateController: @unchecked Sendable {
    enum Mode { case text, video }

    /// 一個統計區間的長度（秒）。
    private static let bucket = 0.5
    /// 區間內每秒影格數達此值，且平均變動面積達 `busyDirty`，才算「忙」。
    private static let busyFps = 15.0
    private static let busyDirty = 0.2
    /// 連續幾個忙區間後升到影片模式（4 秒，擋掉視窗切換這類短暫的全畫面變動），連續幾個不忙區間後降回文字模式（2 秒）。
    private static let upBuckets = 8
    private static let downBuckets = 4

    private struct State {
        var mode = Mode.text
        var bucketStart = 0.0
        var frames = 0
        var dirtySum = 0.0
        var sawInput = false
        var streak = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    /// 模式改變時呼叫（可能在擷取或工作階段佇列上）。
    var onModeChange: ((Mode) -> Void)?

    var mode: Mode { state.withLock { $0.mode } }

    /// 擷取到一張內容有變的影格。
    /// - Parameter dirty: 變動面積佔整個畫面的比例（0～1）
    func noteFrame(now: Double, dirty: Double) {
        advance(now: now) { $0.frames += 1; $0.dirtySum += dirty }
    }

    /// 收到手機輸入（捲動、點擊、打字…）。
    func noteInput(now: Double) {
        advance(now: now) { $0.sawInput = true }
    }

    /// 定時呼叫，畫面靜止沒有影格時也要能結算區間。
    func tick(now: Double) {
        advance(now: now) { _ in }
    }

    private func advance(now: Double, _ update: (inout State) -> Void) {
        let changed: Mode? = state.withLock { s in
            if s.bucketStart == 0 { s.bucketStart = now }
            var newMode: Mode?
            // 補結算已經結束的區間（長時間沒有事件時一次補多個空區間）
            while now - s.bucketStart >= Self.bucket {
                let busy = !s.sawInput
                    && Double(s.frames) / Self.bucket >= Self.busyFps
                    && s.dirtySum / Double(max(s.frames, 1)) >= Self.busyDirty
                switch s.mode {
                case .text:
                    s.streak = busy ? s.streak + 1 : 0
                    if s.streak >= Self.upBuckets { s.mode = .video; s.streak = 0; newMode = .video }
                case .video:
                    s.streak = busy ? 0 : s.streak + 1
                    if s.streak >= Self.downBuckets { s.mode = .text; s.streak = 0; newMode = .text }
                }
                s.bucketStart += Self.bucket
                s.frames = 0
                s.dirtySum = 0
                s.sawInput = false
            }
            update(&s)
            return newMode
        }
        if let changed { onModeChange?(changed) }
    }
}
