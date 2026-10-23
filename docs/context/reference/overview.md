# 系統架構大圖

> **何時讀**：每個 session 開場必讀。

DeskPilot：用 iPhone 在區網（Wi-Fi）內操控 Mac 的遠端桌面 App。目標是在「用手機操作電腦」這個情境下，延遲、流量、清晰度、中文輸入全面勝過市面競品（RDP、Parsec、Jump Desktop、RustDesk），主打辦公情境而非遊戲（遊戲低延遲 Moonlight 已很強，不正面拚）。

- 原始碼：`~/Desktop/deskpilot`；公開 GitHub repo：https://github.com/firstfu/deskpilot（`main`）
- 目前只支援區網，連線**明文、無配對驗證**，僅適合自家網路（加密配對排在 v0.2）。

## 三個組成

| 部分 | 位置 | 角色 | 深度檔 |
|------|------|------|--------|
| 共用協定 | `DeskPilot/Shared/` | 線上訊息格式、TCP 訊息框，兩個 target 都編譯 | `modules/protocol.md` |
| Mac 主機 | `DeskPilot/DeskPilotHost/`（macOS target） | Bonjour 公告、擷取螢幕 → 硬體編碼 → 傳送；把手機輸入注入成 CGEvent | `modules/host.md` |
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
