//
//  InputInjector.swift
//  DeskPilotHost
//
//  把手機送來的輸入事件轉成 macOS CGEvent 注入系統。需要「輔助使用」權限。
//  文字用 CGEventKeyboardSetUnicodeString 直接注入 Unicode，不經過電腦端輸入法——
//  手機上用注音／倉頡選好的字，到電腦上一字不差，也不怕電腦目前是英文或中文輸入模式。
//

import AppKit
import ApplicationServices

final class InputInjector: @unchecked Sendable {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var position = CGPoint.zero
    private var buttonsDown: Set<MouseButton> = []
    // 連點判定：macOS 靠事件上的 clickState 認雙擊，必須自己算
    private var lastClickTime: TimeInterval = 0
    private var lastClickPosition = CGPoint.zero
    private var clickCount = 0
    /// 累計注入的捲動事件數（除錯／量測用）。
    private(set) var scrollCount = 0

    /// 是否已取得輔助使用權限。
    /// - Parameter prompt: true 時若未授權會跳出系統設定提示。
    static func isTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    /// 正在操控的螢幕；切換螢幕時由工作階段更新。
    var displayID: CGDirectDisplayID = CGMainDisplayID()

    /// 操控中螢幕在全域座標（左上原點，point）中的範圍。
    private var displayBounds: CGRect { CGDisplayBounds(displayID) }

    /// 目前游標位置的正規化座標（給主機回報游標用）。
    static func currentCursorNormalized(display: CGDirectDisplayID) -> (UInt16, UInt16)? {
        guard let loc = CGEvent(source: nil)?.location else { return nil }
        let b = CGDisplayBounds(display)
        return (NormalizedCoordinate.encode((loc.x - b.minX) / b.width),
                NormalizedCoordinate.encode((loc.y - b.minY) / b.height))
    }

    /// 把實體游標移到操控中螢幕的正中央（切換螢幕後，讓手機游標與實際位置一致）。
    func centerCursor() {
        let b = displayBounds
        position = CGPoint(x: b.midX, y: b.midY)
        CGWarpMouseCursorPosition(position)
    }

    /// 處理一個輸入事件（呼叫端需保證序列化，不可多執行緒同時呼叫）。
    func handle(_ event: InputEvent) {
        switch event {
        case let .mouseMove(x, y):
            let b = displayBounds
            // 最大值要落在最後一個像素內（maxX - 1）：位置在螢幕外一格時系統不認為游標「頂到邊」，
            // 自動隱藏的 Dock 就叫不出來
            position = CGPoint(x: min(b.minX + NormalizedCoordinate.decode(x) * b.width, b.maxX - 1),
                               y: min(b.minY + NormalizedCoordinate.decode(y) * b.height, b.maxY - 1))
            postMouseMove()
        case let .mouseButton(button, down):
            postButton(button, down: down)
        case let .scroll(dx, dy):
            // 協定定義正值 = 內容往下／右移，與 CGEvent wheel 正值（往上捲、內容下移）同向
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)
            // 明確指定位置：捲動事件送到「游標底下」的視窗，未設定時部分 App 會忽略
            if let loc = CGEvent(source: nil)?.location { e?.location = loc }
            e?.post(tap: .cghidEventTap)
            scrollCount += 1
        case let .key(code, down, mods):
            let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            // 放開時旗標一律清空：放開事件若還帶著修飾旗標，系統會把修飾鍵當成一直按著，
            // 之後所有點擊都變成 ⌃＋點擊（右鍵選單）。實測 ⌃↑ 的放開事件帶 ⌃ 會讓 Mac 修飾鍵狀態卡住
            e?.flags = down ? Self.flags(mods) : []
            e?.post(tap: .cghidEventTap)
        case let .text(s):
            postText(s)
        }
    }

    private func postMouseMove() {
        let type: CGEventType
        let button: CGMouseButton
        if buttonsDown.contains(.left) {
            (type, button) = (.leftMouseDragged, .left)
        } else if buttonsDown.contains(.right) {
            (type, button) = (.rightMouseDragged, .right)
        } else {
            (type, button) = (.mouseMoved, .left)
        }
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button)?
            .post(tap: .cghidEventTap)
    }

    private func postButton(_ button: MouseButton, down: Bool) {
        if down {
            buttonsDown.insert(button)
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(position.x - lastClickPosition.x, position.y - lastClickPosition.y) < 8
            clickCount = (now - lastClickTime < NSEvent.doubleClickInterval && near) ? clickCount + 1 : 1
            lastClickTime = now
            lastClickPosition = position
        } else {
            buttonsDown.remove(button)
        }
        let type: CGEventType
        let cgButton: CGMouseButton
        switch button {
        case .left: (type, cgButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
        case .right: (type, cgButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
        case .middle: (type, cgButton) = (down ? .otherMouseDown : .otherMouseUp, .center)
        }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: cgButton)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        e?.post(tap: .cghidEventTap)
    }

    private func postText(_ s: String) {
        // CGEventKeyboardSetUnicodeString 單次上限約 20 個 UTF-16 單位，長字串要分段
        let units = Array(s.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 20, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            i += 20
        }
    }

    private static func flags(_ m: KeyModifiers) -> CGEventFlags {
        var f: CGEventFlags = []
        if m.contains(.shift) { f.insert(.maskShift) }
        if m.contains(.control) { f.insert(.maskControl) }
        if m.contains(.option) { f.insert(.maskAlternate) }
        if m.contains(.command) { f.insert(.maskCommand) }
        return f
    }
}
