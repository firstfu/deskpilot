# 共用協定模組（Shared）

> **何時讀**：改 `DeskPilot/Shared/Protocol.swift`／`FramedConnection.swift`、新增訊息類型、或兩端連不上／版本不合時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是線上協定的單一事實源。

## 模組定位

`DeskPilot/Shared/` 是一個 Xcode synchronized folder，同時加進 iOS 與 macOS 兩個 target 的 `fileSystemSynchronizedGroups`（Xcode MCP 沒有設定 target membership 的工具，當初是手改 pbxproj 加的）。目前全部走一條 TCP 連線（`noDelay`、`serviceClass = .interactiveVideo`），Bonjour 服務類型 `_deskpilot._tcp`，主機固定監聽 **TCP 52830**（`ProtocolConstants.port`，外網手動輸入 IP 時要用），Bonjour TXT 帶 `id`＝主機 ID。

## 訊息框與編碼規則

- 每則訊息：`[type: UInt8][length: UInt32 big-endian][payload]`，標頭固定 5 bytes；payload 上限 16 MB，超過視為協定錯誤直接斷線。
- 多位元組數值一律 big-endian。
- 座標一律正規化成 0…65535 的 `UInt16`：與兩端解析度無關、只佔 2 bytes。
- 滑鼠移動送**絕對座標**而非相對位移：掉一個封包也不會累積誤差。
- 未知的訊息類型直接略過，讓舊版能忽略新版多送的訊息。

## 配對與加密（v4 起，`SecureChannel.swift`）

- 連線後第一則必須是明文 `handshake`(0x08)：版本、模式（配對／驗證）、手機 ID、手機臨時 X25519 公鑰、手機名稱。主機回明文 `handshakeAck`(0x87)：主機 ID、主機臨時公鑰。之後**雙向全部加密**，外層 type 一律 `encrypted`(0x7F)，payload＝ChaChaPoly(內層 type＋內層 payload)，nonce 為各方向遞增計數器（不傳）。加密後收到明文或解不開的框直接斷線。
- 金鑰：HKDF-SHA256(ECDH 結果 ‖ PSK，salt＝兩把臨時公鑰＋手機 ID＋主機 ID) 導出 c2h／h2c。首次配對 PSK 為空，兩端由 ECDH 結果導出同一組 6 位確認碼，使用者在 Mac 上核對後按允許，主機回加密的 `pairResult`(0x89)，雙方把導出的 32 bytes 配對金鑰存進 Keychain。
- 主機不認得手機 ID 時回明文 `authFailed`(0x88) 並斷線，手機刪掉本地金鑰改走配對。
- **iOS Keychain 在重裝 App 後仍保留**配對紀錄，所以「剛重裝的手機」仍會用舊金鑰走驗證模式，被主機以 `authFailed` 拒絕。手機從 Bonjour 清單連線時知道主機 ID，會刪掉對應金鑰、改走配對；**手動輸入 IP（外網）沒有主機 ID**，不知道該刪哪把，原本會用同樣的舊金鑰無限重試、畫面只顯示「連線中斷」。手機端現在改記一個旗標「下次走配對」（`ClientSession.forcePairNext`，存 `UserDefaults`，配對成功才清除）；**這個修正尚未在實機驗證過**。
- 配對不限區網：主機接受私有網段來源（含 WireGuard 通道），只要人在 Mac 旁核對確認碼並按允許。
- 主機端：未授權前除交握外的訊息一律忽略；驗證模式要等**第一則訊息成功解密**才算通過（手機 ID 是明文，防冒用把現有連線踢掉）；新連線通過驗證才取代舊連線。

## 訊息類型

| 方向 | 類型 | 用途 |
|------|------|------|
| 手機→主機 | `hello` (0x01) | 協定版本＋手機橫向像素大小（寬 ≥ 高） |
| 手機→主機 | `input` (0x02) | 滑鼠移動／按鍵／捲動／按鍵碼／文字，每則 3～7 bytes（文字除外） |
| 手機→主機 | `ping` (0x03) / 主機回 `pong` (0x85) | 量 RTT，主機原樣回傳 |
| 手機→主機 | `requestKeyframe` (0x04) | 顯示層換新或解碼失敗時要求關鍵幀 |
| 手機→主機 | `probe` (0x05) / `report` (0x06) | 內建量測：延遲探針、把結果回寫主機 log（見 `client.md`） |
| 主機→手機 | `helloAck` (0x81) | 桌面大小（point）＋實際編碼大小（pixel） |
| 主機→手機 | `videoFormat` (0x82) | codec＋參數集；每個關鍵幀前都送，讓手機隨時能重建解碼器 |
| 主機→手機 | `videoFrame` (0x83) | 是否關鍵幀、擷取時間、`probeId`、AVCC 格式影像資料 |
| 主機→手機 | `cursor` (0x84) | 實體游標位置（有人直接動 Mac 滑鼠時） |
| 手機→主機 | `selectDisplay` (0x07) | 切換操控的螢幕，payload 為 UInt8 序號 |
| 主機→手機 | `displayInfo` (0x86) | 螢幕數量＋目前序號（主螢幕排第一，其餘由左到右） |
| 手機→主機 | `setDetail` (0x09) | 畫質等級 UInt8：0 = 縮到手機像素、1 = 原生解析度（手機放大時） |
| 手機→主機 | `clipboard` (0x0A) | UTF-8 文字＝寫進 Mac 剪貼簿（上限 1 MB）；空 payload＝請回傳 Mac 目前的剪貼簿 |
| 主機→手機 | `hostClipboard` (0x8A) | Mac 剪貼簿文字（回應空的 `clipboard`），可能為空 |
| 手機→主機 | `setSaver` (0x0B) | 省流量模式 UInt8：1 開、0 關 |
| 手機→主機 | `setAudio` (0x0C) | 聲音串流 UInt8：1 開、0 關，預設關 |
| 主機→手機 | `audioFormat` (0x8B)／`audioFrame` (0x8C) | 取樣率＋聲道數；之後每個 `audioFrame` 是單一 AAC-LC 封包，靜音時不送 |
| 雙向 | `handshake` (0x08)／`handshakeAck` (0x87)／`authFailed` (0x88)／`pairResult` (0x89)／`encrypted` (0x7F) | 見上方「配對與加密」 |

## ⚠️ 版本要完全相同

`ProtocolConstants.version` 目前是 **6**（v3 加螢幕切換、v4 加配對加密、v5 加畫質等級、v6 加剪貼簿、省流量、聲音）。主機收到版本不同的 Hello 會直接斷線，所以改了訊息格式（例如 v2 在影格加了 `probeId`）就要遞增版本，**手機與 Mac 兩端都要重新安裝**，否則表現是「點了主機馬上連線中斷」。

## 輸入事件的設計取捨

- 文字是「輸入法選字完成後的整串」，主機用 Unicode 直接注入（見 `host.md`），不送逐鍵。
- 按鍵碼用 macOS 虛擬鍵碼（Carbon `kVK_*`），手機只送少數非文字鍵（Return、Tab、Delete、Esc、方向鍵）。
- 捲動量的正負號：正值＝內容往下／往右移，與 CGEvent wheel 正值同向，主機不需反轉。
