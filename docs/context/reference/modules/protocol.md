# 共用協定模組（Shared）

> **何時讀**：改 `DeskPilot/Shared/Protocol.swift`／`FramedConnection.swift`、新增訊息類型、或兩端連不上／版本不合時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是線上協定的單一事實源。

## 模組定位

`DeskPilot/Shared/` 是一個 Xcode synchronized folder，同時加進 iOS 與 macOS 兩個 target 的 `fileSystemSynchronizedGroups`（Xcode MCP 沒有設定 target membership 的工具，當初是手改 pbxproj 加的）。目前全部走一條 TCP 連線（`noDelay`、`serviceClass = .interactiveVideo`），Bonjour 服務類型 `_deskpilot._tcp`。

## 訊息框與編碼規則

- 每則訊息：`[type: UInt8][length: UInt32 big-endian][payload]`，標頭固定 5 bytes；payload 上限 16 MB，超過視為協定錯誤直接斷線。
- 多位元組數值一律 big-endian。
- 座標一律正規化成 0…65535 的 `UInt16`：與兩端解析度無關、只佔 2 bytes。
- 滑鼠移動送**絕對座標**而非相對位移：掉一個封包也不會累積誤差。
- 未知的訊息類型直接略過，讓舊版能忽略新版多送的訊息。

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

## ⚠️ 版本要完全相同

`ProtocolConstants.version` 目前是 **2**。主機收到版本不同的 Hello 會直接斷線，所以改了訊息格式（例如 v2 在影格加了 `probeId`）就要遞增版本，**手機與 Mac 兩端都要重新安裝**，否則表現是「點了主機馬上連線中斷」。

## 輸入事件的設計取捨

- 文字是「輸入法選字完成後的整串」，主機用 Unicode 直接注入（見 `host.md`），不送逐鍵。
- 按鍵碼用 macOS 虛擬鍵碼（Carbon `kVK_*`），手機只送少數非文字鍵（Return、Tab、Delete、Esc、方向鍵）。
- 捲動量的正負號：正值＝內容往下／往右移，與 CGEvent wheel 正值同向，主機不需反轉。
