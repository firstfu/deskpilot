//
//  RemoteSurfaceView.swift
//  DeskPilot（iOS 用戶端）
//
//  遠端桌面操作面：顯示影像、本地繪製游標、把手勢轉成滑鼠／鍵盤事件。
//  手感設計（觸控板模式）：
//  - 單指滑動：移動游標（有加速度，慢移精準、快移遠）
//  - 單指點一下：左鍵；連點兩下就是雙擊（主機依時間判定，手機端不必等待，零延遲）
//  - 雙指點一下：右鍵
//  - 雙指滑動：放大時平移檢視；沒放大時捲動
//  - 三指滑動：捲動（放大時也能捲）
//  - 四指滑動：Mac 系統手勢——左右切換桌面（⌃←／⌃→）、上滑 Mission Control（⌃↑）、下滑 App Exposé（⌃↓）
//  - 雙指捏合：本地放大／縮小畫面（立即反應，不等網路）
//  - 單指長按後拖曳：按住左鍵拖曳
//  游標與縮放都在手機本地處理，所以就算網路延遲，手指底下的反應也是即時的。
//

import AVFoundation
import SwiftUI
import UIKit

/// 承載 AVSampleBufferDisplayLayer 的 view，硬體解碼後直接上螢幕。
final class VideoLayerView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

final class RemoteSurfaceView: UIView, UIGestureRecognizerDelegate {
    private let session: ClientSession
    private let videoView = VideoLayerView()
    private let cursorLayer = CAShapeLayer()
    let keyboardField = KeyboardField()

    /// 本地縮放倍率（1 = 整個桌面塞進螢幕）。
    private var zoom: CGFloat = 1
    /// 縮放後畫面相對「置中適配位置」的位移。
    private var pan = CGPoint.zero
    private var pinchActive = false
    private var twoFingerPansView = false
    private var moveStartTime: CFTimeInterval = 0
    private var scrollRemainder = CGPoint.zero
    private var lastDragLocation = CGPoint.zero
    /// 游標是否已貼在桌面邊緣；進入邊緣的那一刻震動一下，之後不重複。
    private var cursorAtEdge = false
    private let clickHaptic = UIImpactFeedbackGenerator(style: .light)
    private let rightClickHaptic = UIImpactFeedbackGenerator(style: .medium)
    private let edgeHaptic = UIImpactFeedbackGenerator(style: .rigid)

    /// 游標靈敏度（桌面寬度的比例 / 每 point 手指位移），以 zoom = 1 為基準。
    private let baseSensitivity: CGFloat = 1.3

    init(session: ClientSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true

        videoView.displayLayer.videoGravity = .resize
        videoView.isUserInteractionEnabled = false
        addSubview(videoView)

        cursorLayer.path = Self.arrowPath()
        cursorLayer.fillColor = UIColor.white.cgColor
        cursorLayer.strokeColor = UIColor.black.cgColor
        cursorLayer.lineWidth = 1.2
        cursorLayer.shadowOpacity = 0.4
        cursorLayer.shadowRadius = 2
        cursorLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(cursorLayer)

        keyboardField.session = session
        keyboardField.frame = CGRect(x: 0, y: -100, width: 10, height: 10)
        addSubview(keyboardField)

        installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            session.attach(renderer: videoView.displayLayer.sampleBufferRenderer)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyLayout()
    }

    // MARK: 版面

    /// 整個桌面以等比例塞進螢幕時的矩形。
    private var fitRect: CGRect {
        guard let d = session.desktopSize, d.width > 0, d.height > 0 else { return bounds }
        return AVMakeRect(aspectRatio: d, insideRect: bounds)
    }

    /// 目前桌面實際顯示的矩形（含縮放與位移）。
    private var displayRect: CGRect {
        let f = fitRect
        return CGRect(x: f.minX + pan.x, y: f.minY + pan.y, width: f.width * zoom, height: f.height * zoom)
    }

    /// 限制位移：放大時桌面邊緣不能內縮到螢幕裡，留出黑邊。
    private func clampPan() {
        let f = fitRect
        let size = CGSize(width: f.width * zoom, height: f.height * zoom)
        func clamp(_ v: CGFloat, origin: CGFloat, content: CGFloat, view: CGFloat) -> CGFloat {
            if content <= view { return (view - content) / 2 - origin }
            return min(max(v, view - content - origin), -origin)
        }
        pan.x = clamp(pan.x, origin: f.minX, content: size.width, view: bounds.width)
        pan.y = clamp(pan.y, origin: f.minY, content: size.height, view: bounds.height)
    }

    func applyLayout() {
        clampPan()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoView.frame = displayRect
        updateCursorLayer()
        CATransaction.commit()
        updateDetail()
    }

    /// 放大超過 1.4 倍要原生解析度、縮回 1.15 倍以下改回手機像素；中間留一段不動，避免在門檻附近來回切。
    /// 影像永遠是整個桌面，切換只影響清晰度，平移與縮放都在手機本地完成，不會有黑邊。
    private func updateDetail() {
        guard session.desktopSize != nil else { return }
        if zoom > 1.4 { session.requestNativeDetail(true) } else if zoom < 1.15 { session.requestNativeDetail(false) }
    }

    func updateCursorLayer() {
        let r = displayRect
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.position = CGPoint(x: r.minX + session.cursor.x * r.width, y: r.minY + session.cursor.y * r.height)
        CATransaction.commit()
    }

    /// 放大狀態下游標靠近螢幕邊緣時，自動平移讓游標保持可見。
    private func followCursor() {
        guard zoom > 1 else { return }
        let r = displayRect
        let p = CGPoint(x: r.minX + session.cursor.x * r.width, y: r.minY + session.cursor.y * r.height)
        let margin: CGFloat = 40
        if p.x < margin { pan.x += margin - p.x }
        if p.x > bounds.width - margin { pan.x -= p.x - (bounds.width - margin) }
        if p.y < margin { pan.y += margin - p.y }
        if p.y > bounds.height - margin { pan.y -= p.y - (bounds.height - margin) }
    }

    // MARK: 手勢

    private func installGestures() {
        let move = UIPanGestureRecognizer(target: self, action: #selector(onMove(_:)))
        move.minimumNumberOfTouches = 1
        move.maximumNumberOfTouches = 1
        addGestureRecognizer(move)

        // 雙指拖曳：放大時平移手機端的檢視位置（不動 Mac 游標），沒放大時捲動 Mac
        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        // 三指拖曳：一律捲動 Mac，放大時也能捲
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.minimumNumberOfTouches = 3
        scroll.maximumNumberOfTouches = 3
        addGestureRecognizer(scroll)

        // 四指滑動：放開時依方向送 Mac 的系統快捷鍵（切換桌面、Mission Control、App Exposé）
        let system = UIPanGestureRecognizer(target: self, action: #selector(onSystemSwipe(_:)))
        system.minimumNumberOfTouches = 4
        system.maximumNumberOfTouches = 4
        addGestureRecognizer(system)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap))
        addGestureRecognizer(tap)

        let rightTap = UITapGestureRecognizer(target: self, action: #selector(onRightTap))
        rightTap.numberOfTouchesRequired = 2
        addGestureRecognizer(rightTap)

        let drag = UILongPressGestureRecognizer(target: self, action: #selector(onDrag(_:)))
        drag.minimumPressDuration = 0.3
        addGestureRecognizer(drag)
    }

    /// 雙指捲動與捏合同時辨識，再依捏合幅度決定這次手勢是哪一種。
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer)
            || (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    @objc private func onMove(_ g: UIPanGestureRecognizer) {
        if g.state == .began { moveStartTime = CACurrentMediaTime() }
        guard g.state == .changed else { return }
        // 兩指不會同時落下：第一根先動的前一小段先不送出，第二根落下時單指手勢被取消，這段就丟掉，不會變成滑鼠移動
        guard CACurrentMediaTime() - moveStartTime > 0.08 else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        let v = g.velocity(in: self)
        // 指標加速：慢速 1 倍精準點選，快速最多 3 倍一次跨過螢幕
        let speed = hypot(v.x, v.y)
        let gain = baseSensitivity * (1 + min(speed / 1200, 2))
        // 放大時除以 √zoom：手指移動同樣距離，游標在桌面上走得較少 → 更精準，但又不至於慢到要一直滑
        let f = fitRect
        let dx = t.x * gain / f.width / max(zoom, 1).squareRoot()
        let dy = t.y * gain / f.height / max(zoom, 1).squareRoot()
        session.moveCursor(to: CGPoint(x: session.cursor.x + dx, y: session.cursor.y + dy))
        notifyEdgeIfNeeded()
        followCursor()
        applyLayout()
    }

    /// 游標剛碰到桌面邊緣時給一下震動，讓手指知道到底了。
    private func notifyEdgeIfNeeded() {
        let c = session.cursor
        let atEdge = c.x <= 0 || c.x >= 1 || c.y <= 0 || c.y >= 1
        if atEdge && !cursorAtEdge { edgeHaptic.impactOccurred(intensity: 0.6) }
        cursorAtEdge = atEdge
    }

    /// 四指滑動在放開時才判斷方向，位移太小視為誤觸。
    @objc private func onSystemSwipe(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        let t = g.translation(in: self)
        guard max(abs(t.x), abs(t.y)) > 60 else { return }
        let code: UInt16
        if abs(t.x) > abs(t.y) {
            // 手指往左滑 = 換到右邊的桌面，與 Mac 觸控板相同
            code = t.x < 0 ? MacKeyCode.rightArrow : MacKeyCode.leftArrow
        } else {
            code = t.y < 0 ? MacKeyCode.upArrow : MacKeyCode.downArrow
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        session.tapKey(code, modifiers: .control)
    }

    /// 手勢開始時決定這次是平移還是捲動，中途捏合改變縮放也不換，避免一次手勢做兩件事。
    @objc private func onTwoFingerPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { twoFingerPansView = zoom > 1 }
        guard twoFingerPansView else { return onScroll(g) }
        guard g.state == .changed else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // 捏合中由捏合以兩指中心為錨點處理位移，這裡不重複套用
        guard !pinchActive else { return }
        pan.x += t.x
        pan.y += t.y
        applyLayout()
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { scrollRemainder = .zero }
        guard g.state == .changed, !pinchActive else { return }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        // 換算成桌面 point，桌面比手機螢幕大，捲動量要跟著放大才跟手
        let f = fitRect
        let scale = (session.desktopSize?.width ?? f.width) / (f.width * zoom)
        let total = CGPoint(x: t.x * scale + scrollRemainder.x, y: t.y * scale + scrollRemainder.y)
        let dx = total.x.rounded(.towardZero)
        let dy = total.y.rounded(.towardZero)
        scrollRemainder = CGPoint(x: total.x - dx, y: total.y - dy)
        guard dx != 0 || dy != 0 else { return }
        session.send(.scroll(dx: Int16(clamping: Int(dx)), dy: Int16(clamping: Int(dy))))
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchActive = false
        case .changed:
            // 四指手勢進行中不當作縮放
            guard g.numberOfTouches <= 2 else { return }
            if !pinchActive && abs(g.scale - 1) > 0.08 { pinchActive = true }
            guard pinchActive else { return }
            // 以兩指中心為錨點縮放：手指下方的那個桌面位置保持不動
            let focal = g.location(in: self)
            let before = displayRect
            let anchor = CGPoint(x: (focal.x - before.minX) / before.width, y: (focal.y - before.minY) / before.height)
            zoom = min(max(zoom * g.scale, 1), 6)
            g.scale = 1
            let f = fitRect
            let newSize = CGSize(width: f.width * zoom, height: f.height * zoom)
            pan = CGPoint(x: focal.x - anchor.x * newSize.width - f.minX,
                          y: focal.y - anchor.y * newSize.height - f.minY)
            applyLayout()
        default:
            pinchActive = false
        }
    }

    @objc private func onTap() {
        clickHaptic.impactOccurred()
        session.click(.left)
    }

    @objc private func onRightTap() {
        rightClickHaptic.impactOccurred()
        session.click(.right)
    }

    @objc private func onDrag(_ g: UILongPressGestureRecognizer) {
        let loc = g.location(in: self)
        switch g.state {
        case .began:
            lastDragLocation = loc
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            session.send(.mouseButton(.left, down: true))
        case .changed:
            let d = CGPoint(x: loc.x - lastDragLocation.x, y: loc.y - lastDragLocation.y)
            lastDragLocation = loc
            let f = fitRect
            let dx = d.x * baseSensitivity / f.width / max(zoom, 1).squareRoot()
            let dy = d.y * baseSensitivity / f.height / max(zoom, 1).squareRoot()
            session.moveCursor(to: CGPoint(x: session.cursor.x + dx, y: session.cursor.y + dy))
            notifyEdgeIfNeeded()
            followCursor()
            applyLayout()
        default:
            session.send(.mouseButton(.left, down: false))
        }
    }

    /// 經典箭頭游標，尖端在 (0,0)。
    private static func arrowPath() -> CGPath {
        let p = UIBezierPath()
        p.move(to: .zero)
        p.addLine(to: CGPoint(x: 0, y: 17))
        p.addLine(to: CGPoint(x: 4.5, y: 13))
        p.addLine(to: CGPoint(x: 7.5, y: 19.5))
        p.addLine(to: CGPoint(x: 10, y: 18.5))
        p.addLine(to: CGPoint(x: 7, y: 12))
        p.addLine(to: CGPoint(x: 12.5, y: 12))
        p.close()
        return p.cgPath
    }
}

// MARK: - 鍵盤

/// 隱形輸入框：接手機鍵盤（含注音、倉頡等輸入法）的輸入。
/// 選字中的組字（markedText）不送，等使用者確認後才把整串文字一次送出——
/// 這是中文輸入在遠端桌面上不亂掉的關鍵。
final class KeyboardField: UITextField, UITextFieldDelegate {
    weak var session: ClientSession?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        autocorrectionType = .no
        autocapitalizationType = .none
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        alpha = 0.01
        addTarget(self, action: #selector(changed), for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() {
        guard markedTextRange == nil, let s = text, !s.isEmpty else { return }
        text = ""
        // 有黏滯修飾鍵時，下一個英數字以「修飾鍵＋鍵」送出（例如 ⌘C、⌃A）
        if let session, !session.armedModifiers.isEmpty, s.count == 1, let code = ANSIKeyCodes.code(for: s) {
            session.tapKey(code, modifiers: session.consumeModifiers())
            return
        }
        session?.send(.text(s))
    }

    /// 輸入框是空的也會呼叫，正好拿來送退格鍵。
    override func deleteBackward() {
        if markedTextRange != nil {
            super.deleteBackward()
            return
        }
        session?.tapKey(MacKeyCode.delete)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        session?.tapKey(MacKeyCode.returnKey)
        return false
    }
}

/// 英數字 → macOS ANSI 虛擬鍵碼（只給 ⌘ 組合鍵用；一般文字走 Unicode 注入）。
enum ANSIKeyCodes {
    private static let table: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
        "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31,
        "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
    ]

    static func code(for s: String) -> UInt16? {
        guard let c = s.lowercased().first else { return nil }
        return table[c]
    }
}

// MARK: - SwiftUI 包裝

struct RemoteSurface: UIViewRepresentable {
    let session: ClientSession
    @Binding var keyboardVisible: Bool

    func makeUIView(context: Context) -> RemoteSurfaceView {
        RemoteSurfaceView(session: session)
    }

    func updateUIView(_ v: RemoteSurfaceView, context: Context) {
        // 讀取這兩個值讓 SwiftUI 在它們變動時呼叫本方法
        _ = session.cursorRevision
        _ = session.desktopSize
        if keyboardVisible, !v.keyboardField.isFirstResponder {
            v.keyboardField.becomeFirstResponder()
        } else if !keyboardVisible, v.keyboardField.isFirstResponder {
            v.keyboardField.resignFirstResponder()
        }
        v.setNeedsLayout()
    }
}
