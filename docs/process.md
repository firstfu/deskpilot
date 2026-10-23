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

### 2026-10-23 — 內建量測（模擬器，`4648162`）

- 協定 v2：新增延遲探針（probe）與量測回報（report）；影格帶 probeId。手機按 ⏲ 自動跑「靜止 → 40 個探針 → 8 秒捲動」，結果回寫主機 log
- 主機每秒 log `stats fps/kbps/encodeMs/ax/scrolls`；環境變數 `DESKPILOT_EXCLUDE_BUNDLES` 可排除指定 App 不擷取
- 踩雷：模擬器視窗屬於 Xcode 的 **Device Hub（`com.apple.dt.Devices`）**，不是 Simulator；不排除它會形成「擷取自己的串流」無限迴圈
- 踩雷：游標停在網頁內嵌媒體區時捲動事件被吃掉，畫面不動；移到正文才正常
- 模擬器結果（loopback，RTT 0.7 ms，不含 Wi-Fi、不含手機解碼上屏）：
  - 延遲：中位 21～24 ms、P90 ≈ 47 ms、最佳 12 ms
  - 編碼耗時 ≈ 10 ms／幀，是延遲最大單一來源
  - 捲動（720 px/s）：平均 3.4 Mbps（0.43 MB/s），56 fps
  - 「靜止」≈ 220 kbps、約 50 fps：Mac 上有東西一直在動（推測是終端機 spinner），不是真正靜止，閒置 0 流量尚未在乾淨桌面上驗證

### 2026-10-23 — 編碼器 A/B 與官方數據對照（尚未 commit）

- `scripts/host-bench.sh start [hevc|h264]`／`report`：重開主機（排除 Device Hub）並收量測結果；`DESKPILOT_CODEC` 切 codec
- 實際編碼解析度 1920×1080（模擬器螢幕像素再被桌面大小限制）
- 低延遲模式下 `MaxFrameDelayCount`、`PrioritizeEncodingSpeedOverQuality` 都回 -12900（不支援，低延遲模式本來就零延遲出幀）
- 模擬器各跑一次：
  - HEVC：延遲中位 23.0 ms／P90 32.0 ms，編碼 ≈ 9.7 ms，捲動 3.43 Mbps
  - H.264：延遲中位 19.9 ms／P90 28.4 ms，編碼 ≈ 9.3 ms，捲動 4.17 Mbps（+22%）
  - 延遲差在單次量測誤差內，流量 HEVC 明顯省 → 維持 HEVC 預設
- 官方數據對照（1080p）：微軟 RDP 網頁瀏覽 default 6～6.5 Mbps、AVC444 0.9～1 Mbps，idle 0.3 kbps；Parsec 預設位元率上限 10 Mbps；Jump Fluid 上限 20～30 Mbps。**捲動流量我們（3.4 Mbps）比 RDP AVC444 高約 3 倍，是要追的目標**

## 下一步

1. 降捲動流量（目標 ≤ 1 Mbps）：調低位元率／品質上限、捲動搬移（只補新露出區域）；在乾淨桌面驗證閒置 0 流量
2. 量測：觸控→畫面的端到端延遲（慢動作錄影），與競品同法比較
2. 手感調校（游標靈敏度、捲動倍率）依實機回饋
3. v0.2：底圖＋可視範圍兩層編碼、配對加密（目前區網明文、無驗證，僅限自家網路）
4. 遷移到 iOS 27 新的 `AVSampleBufferVideoRenderer.Receiver` API（舊 enqueue/flush 已 deprecated，仍可用）
5. 正式 benchmark：對比 RDP、Parsec、Jump Desktop、RustDesk
