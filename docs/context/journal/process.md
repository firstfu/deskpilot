# 流水帳（倒序，最新在最上方）

> 放「特定 commit／當下」的變更紀錄（變更 + 為什麼 + 下一步）。永久結論進 reference/，不進這裡。超 300 筆提醒搬 process-archive.md。
>
> **process-archive.md 的讀法**：預設不讀。要回溯時先 Grep 關鍵字（日期、功能名、表名）定位，再用 offset/limit 只讀那一筆，不得整份讀進來。

### 2026-10-24 — 公開到 GitHub、建立 docs/context 文件體系；手機尺寸虛擬螢幕試做後全數撤回（`940e8ab`）

- **變更**：
  - repo 推上 GitHub 公開：https://github.com/firstfu/deskpilot（`main`）
  - 用 init-context 建 `docs/context/`（reference/ + journal/）與根 `CLAUDE.md` 索引；archive-to-context 歸檔出 `overview.md`、`operations.md`、`modules/{protocol,host,client}.md`；舊 `docs/process.md` 原文搬進本檔後刪除
  - 試做「手機尺寸虛擬螢幕」（CGVirtualDisplay 私有 API）→ 使用者要求整個刪除，程式回到 `f13d22f`，實驗檔一併刪除，淨程式變更為 0
- **為什麼**：程式只存本機有遺失風險；讓下個 session 開場有固定入口；虛擬螢幕 Retina 被系統拒絕、Swift 建立的不上線，價值不足以承擔私有 API 風險（細節見 `reference/overview.md`「已評估並否決的方向」）
- **影響檔案**：`CLAUDE.md`、`docs/context/**`、刪除 `docs/process.md`
- **下一步**：照下方「下一步」清單

<!-- 以下 2026-10-23～24 的紀錄原寫在 docs/process.md，2026-10-24 建立 docs/context/ 時原文搬入，僅改為最新在上 -->

## 下一步

1. iPhone 實機確認 1 Mbps 捲動中文字可讀性與停下後清晰度
2. 依內容自動調位元率（文字捲動低、影片高）；捲動搬移（只補新露出區域）
3. 在乾淨桌面驗證閒置 0 流量
4. 量測：觸控→畫面的端到端延遲（慢動作錄影），與競品同法比較
5. 手感調校（游標靈敏度、捲動倍率）依實機回饋
6. v0.2：底圖＋可視範圍兩層編碼、配對加密（目前區網明文、無驗證，僅限自家網路）
7. 遷移到 iOS 27 新的 `AVSampleBufferVideoRenderer.Receiver` API（舊 enqueue/flush 已 deprecated，仍可用）

### 2026-10-24 — 位元率降到 1 Mbps＋靜止畫質補強（`0800cda`）

- 靜止畫質補強：畫面停 120 ms 後把最後一張重編 3 次（編碼器比對原圖與上一張解碼結果，重複送會補回細節）；擷取 queueDepth 3→4（補強會長期持有一張 buffer）
- 位元率掃描（模擬器、HEVC、1080p、捲動 720 px/s）：
  - 6 Mbps：捲動 3.58 Mbps，延遲中位 23.7 ms
  - 2 Mbps：捲動 1.82 Mbps，延遲中位 21.9 ms
  - 1 Mbps：捲動 **0.96 Mbps**，延遲中位 25.1 ms（與 RDP AVC444 的 0.9～1 Mbps 相當）
- 停下後截圖比對 6 vs 1 Mbps 文字無明顯差異（截圖僅 402pt 寬，細節有限；捲動「進行中」的畫質未驗證）→ 預設改 1 Mbps
- 已知取捨：影片／大面積動畫在 1 Mbps 會較糊，之後依內容自動調整位元率

### 2026-10-23 — 編碼器 A/B 與官方數據對照（`ac01a47`）

- `scripts/host-bench.sh start [hevc|h264]`／`report`：重開主機（排除 Device Hub）並收量測結果；`DESKPILOT_CODEC` 切 codec
- 實際編碼解析度 1920×1080（模擬器螢幕像素再被桌面大小限制）
- 低延遲模式下 `MaxFrameDelayCount`、`PrioritizeEncodingSpeedOverQuality` 都回 -12900（不支援，低延遲模式本來就零延遲出幀）
- 模擬器各跑一次：
  - HEVC：延遲中位 23.0 ms／P90 32.0 ms，編碼 ≈ 9.7 ms，捲動 3.43 Mbps
  - H.264：延遲中位 19.9 ms／P90 28.4 ms，編碼 ≈ 9.3 ms，捲動 4.17 Mbps（+22%）
  - 延遲差在單次量測誤差內，流量 HEVC 明顯省 → 維持 HEVC 預設
- 官方數據對照（1080p）：微軟 RDP 網頁瀏覽 default 6～6.5 Mbps、AVC444 0.9～1 Mbps，idle 0.3 kbps；Parsec 預設位元率上限 10 Mbps；Jump Fluid 上限 20～30 Mbps。**捲動流量我們（3.4 Mbps）比 RDP AVC444 高約 3 倍，是要追的目標**

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

### 2026-10-23 — v0 骨架，實機跑通（`bd2a3dd`）

- 用 Xcode MCP 建立專案 `DeskPilot.xcodeproj`：iOS target `DeskPilot`、macOS target `DeskPilotHost`、共用資料夾 `Shared/`（MCP 沒有設定 target membership 的工具，這一步手動改了 pbxproj 加 synchronized group）
- 模擬器實測：Bonjour 探索、TCP 連線、Hello 交握成功
- 踩雷：主機缺「螢幕與系統錄音」權限時 ScreenCaptureKit 回 `使用者拒絕…擷取的TCC`；加了啟動時 `CGPreflightScreenCaptureAccess`／`CGRequestScreenCaptureAccess`，使用者在系統設定開啟後預檢為 true
- iPhone 15 實機端到端跑通，使用者回饋「速度很快」（尚未正式量測延遲）
