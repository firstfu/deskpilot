# 系統架構大圖

> **何時讀**：每個 session 開場必讀。

DeskPilot：用 iPhone 在區網（Wi-Fi）內操控 Mac 的遠端桌面 App。目標是在「用手機操作電腦」這個情境下，延遲、流量、清晰度、中文輸入全面勝過市面競品（RDP、Parsec、Jump Desktop、RustDesk），主打辦公情境而非遊戲（遊戲低延遲 Moonlight 已很強，不正面拚）。

- 原始碼：`~/Desktop/deskpilot`；公開 GitHub repo：https://github.com/firstfu/deskpilot（`main`）
- 連線一律加密並需配對（協定 v4，2026-10-26）：首次在 Mac 上核對 6 位數並允許，之後以 Keychain 金鑰自動驗證；手機連線前要 Face ID。細節見 `modules/protocol.md`。
- 區網靠 Bonjour 自動找主機；**外網**透過 WireGuard 通道（Mac 當伺服器），**內建於 Mac App**：自動向路由器開埠（NAT-PMP／UPnP）、以特權 helper（root LaunchDaemon）啟停 `wireguard-go`、選單顯示 QR code 給手機的官方 WireGuard App 一次性匯入，手機再手動輸入通道位址 `10.66.0.1` 連線。主機只接受私有網段來源，DeskPilot 本身不直接暴露在公網。機制見 `modules/external-access.md`，維運見 `operations.md`。

## 組成

| 部分 | 位置 | 角色 | 深度檔 |
|------|------|------|--------|
| 共用協定 | `DeskPilot/Shared/` | 線上訊息格式、TCP 訊息框，兩個 target 都編譯 | `modules/protocol.md` |
| Mac 主機 | `DeskPilot/DeskPilotHost/`（macOS target） | Bonjour 公告、擷取螢幕 → 硬體編碼 → 傳送；把手機輸入注入成 CGEvent | `modules/host.md` |
| 外網通道 | `DeskPilot/DeskPilotHost/ExternalAccess/`、`DeskPilot/DeskPilotHelper/`（macOS 命令列 target，嵌進主機 App） | 自動開埠、可達性判斷、特權 helper 啟停 WireGuard、手機 QR 配對 | `modules/external-access.md` |
| iPhone 用戶端 | `DeskPilot/DeskPilot/`（iOS target） | 找主機、硬體解碼顯示、觸控板手勢、本地游標／縮放、中文輸入、內建量測 | `modules/client.md` |

資料流：iPhone 送 Hello（手機像素大小）→ 主機決定編碼解析度並開始擷取 → 影格經 TCP 推給 iPhone 顯示；反方向是 3～7 bytes 的輸入事件。建置、執行、測試方法見 `operations.md`。

## 省流量／低延遲的核心手段

設計原則是「桌面大多是靜止文字，不要當影片一直送」：

- 畫面沒變就不編碼，閒置時影像流量為 0。
- 編碼解析度上限＝手機螢幕像素，不傳手機顯示不了的像素。
- 關鍵幀只在需要時產生（新連線、解碼失敗）。
- 背壓：在途影格太多就丟新幀，延遲不會越積越長。
- 游標不進影像、捏合縮放在手機本地做 → 手指下的反應不等網路。
- 低位元率（1 Mbps）＋停下後重編補清晰：移動中省流量、停下後文字清楚。
- 中文以 Unicode 直接注入，不經電腦端輸入法。

追趕基準：微軟官方公布 RDP AVC444 模式在 1080p 網頁瀏覽約 0.9～1 Mbps；DeskPilot 調到 1 Mbps 後模擬器實測捲動約 0.96 Mbps（細節見 `modules/host.md`）。

## 已評估並否決的方向

- **手機尺寸虛擬螢幕**（2026-10-24）：想用 macOS 私有 API `CGVirtualDisplay` 在 Mac 上建一台手機比例的螢幕，讓 App 照手機大小排版。實測 Retina（@2x）只接受系統內建的 800×600，手機比例一律被拒（連系統設定也只列非 Retina 版）；從 Swift 建立的虛擬螢幕不會進入作用中螢幕清單；連續建立多台後 WindowServer 會卡住，連原本可行的程式也失敗。使用者決定整個刪除、程式未保留。要重啟這個方向前先跟使用者確認。
