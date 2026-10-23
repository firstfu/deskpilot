# DeskPilot 進度／時間線

> 手機（iPhone）在區網內操作電腦（Mac）的遠端控制 App。目標：在「用手機操作電腦」情境下，延遲、流量、清晰度、中文輸入全面勝過現有競品。
> 開發方式：儘量用 Xcode MCP（建專案、寫檔、build、run、模擬器互動）。

## 架構（v0）

- `DeskPilot/Shared/`：兩端共用的線上協定（`Protocol.swift`）與 TCP 訊息框（`FramedConnection.swift`）
- `DeskPilot/DeskPilotHost/`（macOS）：ScreenCaptureKit 擷取 → VideoToolbox 硬體 HEVC（低延遲模式）→ TCP；CGEvent 注入輸入
- `DeskPilot/DeskPilot/`（iOS）：Bonjour 探索 → 收影格 → AVSampleBufferDisplayLayer 硬體解碼顯示；觸控板手勢、本地游標、本地縮放、IME 安全的中文輸入

已實作的省流量／低延遲手段：
- 畫面靜止時不編碼（ScreenCaptureKit `.idle` 影格直接丟棄）→ 閒置 0 影像流量
- 編碼解析度上限 = 手機螢幕像素，不傳手機顯示不了的像素
- 關鍵幀只在需要時產生（新連線／解碼失敗）
- 背壓：在途影格 ≥ 2 就丟新影格，延遲不累積
- 游標不進影像，手機本地繪製；捏合縮放在手機本地完成
- 輸入事件 3～7 bytes；中文以 Unicode 直接注入，不經電腦端輸入法

## 時間線

### 2026-10-23 — v0 骨架，實機跑通（`bd2a3dd`）

- 用 Xcode MCP 建立專案 `DeskPilot.xcodeproj`：iOS target `DeskPilot`、macOS target `DeskPilotHost`、共用資料夾 `Shared/`（MCP 沒有設定 target membership 的工具，這一步手動改了 pbxproj 加 synchronized group）
- 模擬器實測：Bonjour 探索、TCP 連線、Hello 交握成功
- 踩雷：主機缺「螢幕與系統錄音」權限時 ScreenCaptureKit 回 `使用者拒絕…擷取的TCC`；加了啟動時 `CGPreflightScreenCaptureAccess`／`CGRequestScreenCaptureAccess`，使用者在系統設定開啟後預檢為 true
- iPhone 15 實機端到端跑通，使用者回饋「速度很快」（尚未正式量測延遲）

## 下一步

1. 量測：觸控→畫面的端到端延遲、靜止／捲動／拖視窗三情境的流量，對比 Parsec、Jump Desktop、RDP
2. 手感調校（游標靈敏度、捲動倍率）依實機回饋
3. v0.2：底圖＋可視範圍兩層編碼、配對加密（目前區網明文、無驗證，僅限自家網路）
4. 遷移到 iOS 27 新的 `AVSampleBufferVideoRenderer.Receiver` API（舊 enqueue/flush 已 deprecated，仍可用）
5. 正式 benchmark：對比 RDP、Parsec、Jump Desktop、RustDesk
