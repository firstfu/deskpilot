//
//  Protocol.swift
//  DeskPilot 共用（主機 macOS ／ 用戶端 iOS 兩邊都編譯）
//
//  定義手機與電腦之間的線上協定。設計原則是「每個 byte 都要有理由」：
//  - 傳輸框：[type: UInt8][length: UInt32 big-endian][payload]，標頭固定 5 bytes
//  - 座標一律正規化成 0...65535 的 UInt16，與兩端解析度無關，且只佔 2 bytes
//  - 所有多位元組數值皆為 big-endian
//

import Foundation

/// 協定層常數。
enum ProtocolConstants {
    /// 協定版本；不相容的改動要遞增，主機收到不同版本會拒絕連線。
    static let version: UInt16 = 1
    /// Bonjour 服務類型，需與 iOS Info.plist 的 NSBonjourServices 一致。
    static let bonjourType = "_deskpilot._tcp"
    /// 傳輸框標頭長度（type 1 byte + length 4 bytes）。
    static let headerSize = 5
    /// 單一訊息上限；超過視為協定錯誤，避免惡意或損毀的長度值把記憶體吃光。
    static let maxPayload = 16 * 1024 * 1024
}

/// 訊息種類。0x0_ 為用戶端→主機，0x8_ 為主機→用戶端。
enum MessageType: UInt8 {
    case hello = 0x01
    case input = 0x02
    case ping = 0x03
    case requestKeyframe = 0x04

    case helloAck = 0x81
    case videoFormat = 0x82
    case videoFrame = 0x83
    case cursor = 0x84
    case pong = 0x85
}

/// 協定解析錯誤。
enum ProtocolError: Error {
    case truncated
    case invalidValue
}

// MARK: - 位元組讀寫

/// 依 big-endian 寫入基本型別的小工具。
struct ByteWriter {
    private(set) var data = Data()

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { append(v.bigEndian) }
    mutating func u32(_ v: UInt32) { append(v.bigEndian) }
    mutating func u64(_ v: UInt64) { append(v.bigEndian) }
    mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    mutating func bytes(_ d: Data) { data.append(d) }

    /// 寫入「UInt32 長度 + 內容」的區塊。
    mutating func blob(_ d: Data) {
        u32(UInt32(d.count))
        data.append(d)
    }

    private mutating func append<T>(_ v: T) {
        withUnsafeBytes(of: v) { data.append(contentsOf: $0) }
    }
}

/// 依 big-endian 讀取基本型別的小工具。
struct ByteReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = data.startIndex
    }

    var remaining: Int { data.endIndex - offset }

    mutating func u8() throws -> UInt8 { try take(1).first! }
    mutating func u16() throws -> UInt16 { try integer() }
    mutating func u32() throws -> UInt32 { try integer() }
    mutating func u64() throws -> UInt64 { try integer() }
    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

    /// 讀取「UInt32 長度 + 內容」的區塊。
    /// - Throws: `ProtocolError.truncated` 長度超出剩餘資料時。
    mutating func blob() throws -> Data {
        let n = Int(try u32())
        return try take(n)
    }

    /// 取出剩下全部資料。
    mutating func rest() -> Data {
        let d = data[offset..<data.endIndex]
        offset = data.endIndex
        return Data(d)
    }

    private mutating func take(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ProtocolError.truncated }
        let d = data[offset..<offset + n]
        offset += n
        return d
    }

    private mutating func integer<T: FixedWidthInteger>() throws -> T {
        let d = try take(MemoryLayout<T>.size)
        // 逐 byte 組回，避免 Data 切片未對齊時直接 load 造成崩潰
        return d.reduce(T.zero) { ($0 << 8) | T($1) }
    }
}

// MARK: - 訊息

/// 用戶端連線後的第一個訊息，告知手機顯示區的像素大小，主機據此決定編碼解析度。
struct HelloMessage {
    var version: UInt16 = ProtocolConstants.version
    /// 手機橫向時的像素寬高（寬 ≥ 高）。
    var viewWidth: UInt16
    var viewHeight: UInt16

    func encode() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u16(viewWidth); w.u16(viewHeight)
        return w.data
    }

    static func decode(_ d: Data) throws -> HelloMessage {
        var r = ByteReader(d)
        let v = try r.u16()
        return HelloMessage(version: v, viewWidth: try r.u16(), viewHeight: try r.u16())
    }
}

/// 主機對 Hello 的回覆：桌面大小（point）與實際編碼的影像大小（pixel）。
struct HelloAckMessage {
    var desktopWidth: UInt16
    var desktopHeight: UInt16
    var videoWidth: UInt16
    var videoHeight: UInt16

    func encode() -> Data {
        var w = ByteWriter()
        w.u16(desktopWidth); w.u16(desktopHeight); w.u16(videoWidth); w.u16(videoHeight)
        return w.data
    }

    static func decode(_ d: Data) throws -> HelloAckMessage {
        var r = ByteReader(d)
        return HelloAckMessage(desktopWidth: try r.u16(), desktopHeight: try r.u16(),
                               videoWidth: try r.u16(), videoHeight: try r.u16())
    }
}

/// 影像編碼格式。
enum VideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2
}

/// 解碼器初始化資訊：codec 與參數集（H.264 為 SPS/PPS，HEVC 為 VPS/SPS/PPS）。
/// 每個關鍵幀前都會送一次，只有幾十 bytes，換來用戶端隨時可重建解碼器。
struct VideoFormatMessage {
    var codec: VideoCodec
    var parameterSets: [Data]

    func encode() -> Data {
        var w = ByteWriter()
        w.u8(codec.rawValue)
        w.u8(UInt8(parameterSets.count))
        parameterSets.forEach { w.blob($0) }
        return w.data
    }

    static func decode(_ d: Data) throws -> VideoFormatMessage {
        var r = ByteReader(d)
        guard let codec = VideoCodec(rawValue: try r.u8()) else { throw ProtocolError.invalidValue }
        let count = Int(try r.u8())
        var sets: [Data] = []
        for _ in 0..<count { sets.append(try r.blob()) }
        return VideoFormatMessage(codec: codec, parameterSets: sets)
    }
}

/// 一個編碼後的影格（AVCC 格式：每個 NAL 前有 4 bytes 長度）。
struct VideoFrameMessage {
    var isKeyframe: Bool
    /// 主機擷取時間（mach 時間換算的奈秒），供統計用。
    var captureTimeNs: UInt64
    var payload: Data

    func encode() -> Data {
        var w = ByteWriter()
        w.u8(isKeyframe ? 1 : 0)
        w.u64(captureTimeNs)
        w.bytes(payload)
        return w.data
    }

    static func decode(_ d: Data) throws -> VideoFrameMessage {
        var r = ByteReader(d)
        let key = try r.u8() == 1
        let t = try r.u64()
        return VideoFrameMessage(isKeyframe: key, captureTimeNs: t, payload: r.rest())
    }
}

/// 主機回報游標位置（例如有人直接動了電腦的實體滑鼠）。
struct CursorMessage {
    var x: UInt16
    var y: UInt16

    func encode() -> Data {
        var w = ByteWriter()
        w.u16(x); w.u16(y)
        return w.data
    }

    static func decode(_ d: Data) throws -> CursorMessage {
        var r = ByteReader(d)
        return CursorMessage(x: try r.u16(), y: try r.u16())
    }
}

// MARK: - 輸入事件

/// 滑鼠按鍵。
enum MouseButton: UInt8 {
    case left = 0
    case right = 1
    case middle = 2
}

/// 修飾鍵位元旗標（1 byte 裝得下）。
struct KeyModifiers: OptionSet {
    let rawValue: UInt8
    static let shift = KeyModifiers(rawValue: 1 << 0)
    static let control = KeyModifiers(rawValue: 1 << 1)
    static let option = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)
}

/// macOS 虛擬鍵碼（Carbon kVK_*），用戶端只會送這幾個非文字按鍵。
enum MacKeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// 使用者輸入。編碼後每個事件只有 3～7 bytes（文字除外）。
enum InputEvent: Equatable {
    /// 游標絕對位置（正規化 0...65535）。用絕對值而非相對位移，掉一個封包也不會累積誤差。
    case mouseMove(x: UInt16, y: UInt16)
    case mouseButton(MouseButton, down: Bool)
    /// 捲動量（像素），正值 = 內容往下／往右。
    case scroll(dx: Int16, dy: Int16)
    case key(code: UInt16, down: Bool, modifiers: KeyModifiers)
    /// 已確認的文字（輸入法選字完成後才送），主機直接以 Unicode 注入，不受電腦端輸入法影響。
    case text(String)

    func encode() -> Data {
        var w = ByteWriter()
        switch self {
        case let .mouseMove(x, y):
            w.u8(0); w.u16(x); w.u16(y)
        case let .mouseButton(b, down):
            w.u8(1); w.u8(b.rawValue); w.u8(down ? 1 : 0)
        case let .scroll(dx, dy):
            w.u8(2); w.i16(dx); w.i16(dy)
        case let .key(code, down, mods):
            w.u8(3); w.u16(code); w.u8(down ? 1 : 0); w.u8(mods.rawValue)
        case let .text(s):
            w.u8(4); w.bytes(Data(s.utf8))
        }
        return w.data
    }

    /// - Throws: `ProtocolError` 資料截斷或子類型未知時。
    static func decode(_ d: Data) throws -> InputEvent {
        var r = ByteReader(d)
        switch try r.u8() {
        case 0:
            return .mouseMove(x: try r.u16(), y: try r.u16())
        case 1:
            guard let b = MouseButton(rawValue: try r.u8()) else { throw ProtocolError.invalidValue }
            return .mouseButton(b, down: try r.u8() == 1)
        case 2:
            return .scroll(dx: try r.i16(), dy: try r.i16())
        case 3:
            let code = try r.u16()
            let down = try r.u8() == 1
            return .key(code: code, down: down, modifiers: KeyModifiers(rawValue: try r.u8()))
        case 4:
            guard let s = String(data: r.rest(), encoding: .utf8) else { throw ProtocolError.invalidValue }
            return .text(s)
        default:
            throw ProtocolError.invalidValue
        }
    }
}

// MARK: - 座標正規化

enum NormalizedCoordinate {
    /// 把 0...1 的比例轉成線上用的 UInt16。
    static func encode(_ fraction: Double) -> UInt16 {
        UInt16((min(max(fraction, 0), 1) * 65535).rounded())
    }

    /// 把線上 UInt16 轉回 0...1 的比例。
    static func decode(_ v: UInt16) -> Double {
        Double(v) / 65535
    }
}
