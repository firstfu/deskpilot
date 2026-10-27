//
//  SecureChannel.swift
//  DeskPilot 共用（主機 macOS ／ 用戶端 iOS 兩邊都編譯）
//
//  配對與加密。設計重點：
//  - 每次連線雙方各產生一把臨時 X25519 金鑰交換，舊錄下的流量事後拿到長期金鑰也解不開
//  - 已配對：交換結果再混入配對時存下的 32 bytes 金鑰（PSK），沒有 PSK 的一方算不出正確的加密金鑰
//  - 首次配對：兩端由同一份交換結果算出 6 位數字，使用者在 Mac 上確認與手機一致後按允許；
//    中間人兩邊各做一次交換，數字會不同（猜中機率百萬分之一）
//  - 加密後每則訊息是 ChaChaPoly(內層 type + payload)，nonce 用各方向遞增計數器，不另外傳
//

import CryptoKit
import Foundation
import Security

/// 一個方向的加密器。nonce 為 12 bytes 的遞增計數器，同一把金鑰絕不重用 nonce。
struct DirectionalCipher {
    private let key: SymmetricKey
    private var counter: UInt64 = 0

    init(key: SymmetricKey) { self.key = key }

    private mutating func nextNonce() throws -> ChaChaPoly.Nonce {
        var bytes = [UInt8](repeating: 0, count: 12)
        withUnsafeBytes(of: counter.bigEndian) { bytes.replaceSubrange(4..<12, with: $0) }
        counter += 1
        return try ChaChaPoly.Nonce(data: bytes)
    }

    /// 回傳 ciphertext + 16 bytes tag。
    mutating func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nextNonce())
        // ciphertext 是切片、索引不從 0 開始；轉成獨立的 Data，呼叫端用下標才安全
        return Data(box.ciphertext) + box.tag
    }

    /// - Throws: 驗證失敗（被竄改、金鑰不對、順序錯亂）時拋出。
    mutating func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw ProtocolError.truncated }
        let box = try ChaChaPoly.SealedBox(nonce: nextNonce(), ciphertext: data.dropLast(16), tag: data.suffix(16))
        return try ChaChaPoly.open(box, using: key)
    }
}

/// 交握訊息（手機→主機，明文）：模式、手機 ID、臨時公鑰、手機名稱（僅配對時有意義）。
struct HandshakeMessage {
    enum Mode: UInt8 {
        case pair = 0
        case resume = 1
    }

    var version: UInt16 = ProtocolConstants.version
    var mode: Mode
    var deviceID: UUID
    var ephemeralKey: Data
    var deviceName: String

    func encode() -> Data {
        var w = ByteWriter()
        w.u16(version); w.u8(mode.rawValue)
        w.bytes(deviceID.data); w.blob(ephemeralKey); w.bytes(Data(deviceName.utf8))
        return w.data
    }

    static func decode(_ d: Data) throws -> HandshakeMessage {
        var r = ByteReader(d)
        let version = try r.u16()
        guard let mode = Mode(rawValue: try r.u8()) else { throw ProtocolError.invalidValue }
        let id = try UUID(data: r.fixed(16))
        let key = try r.blob()
        let name = String(data: r.rest(), encoding: .utf8) ?? ""
        return HandshakeMessage(version: version, mode: mode, deviceID: id, ephemeralKey: key, deviceName: name)
    }
}

/// 交握回覆（主機→手機，明文）：主機 ID、臨時公鑰。
struct HandshakeAckMessage {
    var hostID: UUID
    var ephemeralKey: Data

    func encode() -> Data {
        var w = ByteWriter()
        w.bytes(hostID.data); w.blob(ephemeralKey)
        return w.data
    }

    static func decode(_ d: Data) throws -> HandshakeAckMessage {
        var r = ByteReader(d)
        return HandshakeAckMessage(hostID: try UUID(data: r.fixed(16)), ephemeralKey: try r.blob())
    }
}

/// 交握完成後兩端算出的金鑰組。
struct SessionKeys {
    let clientToHost: SymmetricKey
    let hostToClient: SymmetricKey
    /// 配對確認碼（6 位數字）；只在配對模式顯示。
    let pairingCode: String
    /// 配對成功後要存下的長期金鑰。
    let pairingKey: Data

    /// - Parameter psk: 已配對時的長期金鑰；首次配對傳 nil。
    static func derive(myPrivate: Curve25519.KeyAgreement.PrivateKey, theirPublic: Data,
                       clientEphemeral: Data, hostEphemeral: Data,
                       deviceID: UUID, hostID: UUID, psk: Data?) throws -> SessionKeys {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPublic)
        let shared = try myPrivate.sharedSecretFromKeyAgreement(with: peer)
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        // 把整段交握內容當 salt：任何一個欄位被換掉，兩邊算出的金鑰就對不上
        let transcript = clientEphemeral + hostEphemeral + deviceID.data + hostID.data
        let ikm = SymmetricKey(data: sharedBytes + (psk ?? Data()))
        func key(_ info: String, _ input: SymmetricKey = ikm) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: transcript, info: Data(info.utf8), outputByteCount: 32)
        }
        let sharedKey = SymmetricKey(data: sharedBytes)
        let codeValue = key("deskpilot-code", sharedKey).withUnsafeBytes { raw in
            raw.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        }
        return SessionKeys(clientToHost: key("deskpilot-c2h"),
                           hostToClient: key("deskpilot-h2c"),
                           pairingCode: String(format: "%06u", codeValue % 1_000_000),
                           pairingKey: key("deskpilot-psk", sharedKey).withUnsafeBytes { Data($0) })
    }
}

/// 配對紀錄，存在 Keychain。主機端以手機 ID 為帳號，手機端以主機 ID 為帳號。
enum PairingStore {
    struct Entry: Identifiable {
        let id: UUID
        let name: String
    }

    private static let service = "tw.firstfu.DeskPilot.pairing"

    static func save(id: UUID, name: String, key: Data) {
        remove(id: id)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecAttrLabel: name,
            kSecValueData: key,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func key(for id: UUID) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func remove(id: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: id.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func all() -> [Entry] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecReturnAttributes: true,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[CFString: Any]] else { return [] }
        return items.compactMap { a in
            guard let account = a[kSecAttrAccount] as? String, let id = UUID(uuidString: account) else { return nil }
            return Entry(id: id, name: a[kSecAttrLabel] as? String ?? "未命名裝置")
        }
    }

    /// 本機的固定 ID（手機用作 deviceID、主機用作 hostID），第一次使用時產生。
    static var localID: UUID {
        let k = "DeskPilotLocalID"
        if let s = UserDefaults.standard.string(forKey: k), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: k)
        return id
    }
}

extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }

    init(data: Data) throws {
        guard data.count == 16 else { throw ProtocolError.truncated }
        var u: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &u) { $0.copyBytes(from: data) }
        self.init(uuid: u)
    }
}
