//
//  ShortcutBar.swift
//  DeskPilot（iOS 用戶端）
//
//  快捷鍵列：黏滯修飾鍵（⇧⌃⌥⌘，按一下武裝、用過一次就放開）加常用按鍵與組合鍵。
//  手機鍵盤沒有這些鍵，遠端操作最常卡在這裡。
//

import SwiftUI

struct ShortcutBar: View {
    let session: ClientSession

    private struct Combo: Identifiable {
        let id: String
        let title: String
        let code: UInt16
        let modifiers: KeyModifiers
    }

    private static func ansi(_ s: String) -> UInt16 { ANSIKeyCodes.code(for: s) ?? 0 }

    private let keys: [Combo] = [
        Combo(id: "esc", title: "esc", code: MacKeyCode.escape, modifiers: []),
        Combo(id: "tab", title: "tab", code: MacKeyCode.tab, modifiers: []),
        Combo(id: "left", title: "←", code: MacKeyCode.leftArrow, modifiers: []),
        Combo(id: "down", title: "↓", code: MacKeyCode.downArrow, modifiers: []),
        Combo(id: "up", title: "↑", code: MacKeyCode.upArrow, modifiers: []),
        Combo(id: "right", title: "→", code: MacKeyCode.rightArrow, modifiers: []),
        Combo(id: "return", title: "⏎", code: MacKeyCode.returnKey, modifiers: []),
    ]

    private let combos: [Combo] = [
        Combo(id: "a", title: "全選", code: ShortcutBar.ansi("a"), modifiers: .command),
        Combo(id: "x", title: "剪下", code: ShortcutBar.ansi("x"), modifiers: .command),
        Combo(id: "z", title: "復原", code: ShortcutBar.ansi("z"), modifiers: .command),
        Combo(id: "sz", title: "重做", code: ShortcutBar.ansi("z"), modifiers: [.command, .shift]),
        Combo(id: "s", title: "存檔", code: ShortcutBar.ansi("s"), modifiers: .command),
        Combo(id: "f", title: "尋找", code: ShortcutBar.ansi("f"), modifiers: .command),
        Combo(id: "r", title: "重整", code: ShortcutBar.ansi("r"), modifiers: .command),
        Combo(id: "t", title: "新分頁", code: ShortcutBar.ansi("t"), modifiers: .command),
        Combo(id: "w", title: "關閉", code: ShortcutBar.ansi("w"), modifiers: .command),
        Combo(id: "q", title: "結束", code: ShortcutBar.ansi("q"), modifiers: .command),
    ]

    /// 單手拇指好按的大按鈕：Mac 上最常用的系統層動作。
    private let quickActions: [(icon: String, title: String, code: UInt16, modifiers: KeyModifiers)] = [
        ("rectangle.3.group", "Mission Control", MacKeyCode.upArrow, .control),
        ("magnifyingglass", "Spotlight", MacKeyCode.space, .command),
        ("square.on.square", "切換 App", MacKeyCode.tab, .command),
        ("camera.viewfinder", "截圖", ShortcutBar.ansi("5"), [.command, .shift]),
    ]

    var body: some View {
        VStack(spacing: 0) {
            quickBar
            keyBar
        }
        .background(.black.opacity(0.7))
    }

    private var quickBar: some View {
        HStack(spacing: 8) {
            ForEach(quickActions, id: \.title) { a in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    session.tapKey(a.code, modifiers: a.modifiers)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: a.icon).font(.system(size: 20, weight: .medium))
                        Text(a.title).font(.system(size: 11, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .foregroundStyle(.white)
                    .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var keyBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                modifier("⇧", .shift)
                modifier("⌃", .control)
                modifier("⌥", .option)
                modifier("⌘", .command)
                divider
                chip("拷貝") { session.copyFromMac() }
                chip("貼上") { session.pasteToMac() }
                divider
                ForEach(keys) { k in
                    chip(k.title) { session.tapKey(k.code, modifiers: session.consumeModifiers().union(k.modifiers)) }
                }
                divider
                ForEach(combos) { c in
                    chip(c.title) { session.tapKey(c.code, modifiers: session.consumeModifiers().union(c.modifiers)) }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var divider: some View {
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 20)
    }

    private func modifier(_ label: String, _ flag: KeyModifiers) -> some View {
        let on = session.armedModifiers.contains(flag)
        return Button { session.toggleModifier(flag) } label: {
            Text(label)
                .font(.system(size: 16, weight: .semibold))
                .frame(minWidth: 34, minHeight: 32)
                .foregroundStyle(on ? .black : .white)
                .background(on ? Color.white : Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .padding(.horizontal, 10)
                .frame(minHeight: 32)
                .foregroundStyle(.white)
                .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
