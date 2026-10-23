# Mac 主機模組（DeskPilotHost）

> **何時讀**：改 `DeskPilot/DeskPilotHost/` 任何檔（擷取、編碼、輸入注入、主機 UI），或遇到「連上就斷」「畫面不動」「流量異常」「手機操作沒反應」時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是主機端的單一事實源；協定細節見 `protocol.md`，建置測試見 `../operations.md`。

## 模組定位

macOS App，非沙箱（`ENABLE_APP_SANDBOX = NO`，CGEvent 注入需要）。同一時間只服務一支手機，新連線會取代舊的。流程：`HostController` 發 Bonjour → `HostSession` 收 Hello → `ScreenCapturer`（ScreenCaptureKit）→ `VideoEncoder`（VideoToolbox）→ TCP；反向 `InputInjector` 把事件轉成 CGEvent。

## 擷取與編碼的關鍵設計

- **閒置不編碼**：ScreenCaptureKit 在畫面沒變時送 `.idle` 狀態的影格，直接丟棄 → 閒置 0 影像流量。只有 `.complete` 才送去編碼。
- **擷取格式**：直接要 420v（硬體編碼器原生格式，省一次色彩轉換），`showsCursor = false`（游標由手機本地畫），`minimumFrameInterval` 1/60 秒，`queueDepth = 4`（靜止補強會長期持有一張 buffer，比最低值 3 多留一格）。
- **編碼解析度**：`min(1, 手機像素 / Mac 原生像素)` 等比縮小，不傳手機顯示不了的像素。
- **編碼器選擇順序**：HEVC 低延遲 → H.264 低延遲 → HEVC 一般。低延遲模式不重排（無 B-frame）；關鍵幀只在手機要求時產生（`MaxKeyFrameInterval` 設很大）。
- **背壓**：在途影格 ≥ 2 就丟掉新擷取的畫面，寧可少一幀也不讓 socket 佇列越積越長。
- **靜止畫質補強**：畫面停止變化 120 ms 後，把最後一張再編碼 3 次。編碼器比對的是「原圖」與「上一張解碼後的模糊結果」，所以重複送同一張會逐步補回細節。這讓移動中可以用很低的位元率，停下後文字又清楚；每次停頓只多花幾十 KB。

## 位元率與 codec 的決策依據

- **預設 1 Mbps**（環境變數 `DESKPILOT_BITRATE` 可覆寫）。2026-10-24 模擬器掃描（HEVC、1080p、每秒捲 720 px）：6 Mbps → 捲動 3.58 Mbps；2 Mbps → 1.82 Mbps；1 Mbps → **0.96 Mbps**，延遲中位數三者都在 22～25 ms，差異在誤差內。1 Mbps 對齊微軟 RDP AVC444 官方數字（1080p 網頁瀏覽 0.9～1 Mbps），停下後與 6 Mbps 截圖看不出差別。
- **已知取捨**：看影片或大面積動畫時 1 Mbps 會偏糊；捲動「進行中」的清晰度只在模擬器看過，尚未實機確認。之後計畫依內容自動調整。
- **HEVC 為預設**（`DESKPILOT_CODEC=h264` 可切）。2026-10-23 A/B：延遲差約 3 ms（誤差內），但捲動流量 HEVC 比 H.264 省約 18%。

## 輸入注入

- 需要「輔助使用」權限；沒權限時 CGEvent 會被系統默默丟掉，不報錯。主機 log 的 `ax=` 欄位可確認。
- **雙擊**：macOS 靠事件上的 `mouseEventClickState` 判斷雙擊，主機自己依時間（系統雙擊間隔）和距離（< 8 pt）計算，手機端連點兩下就好，不用等待。
- **文字**：用 `CGEventKeyboardSetUnicodeString` 直接注入 Unicode，單次上限約 20 個 UTF-16 單位，長字串要分段。電腦端目前是中文還是英文輸入模式都不影響。
- **捲動**：像素單位，並明確設定事件位置為目前游標位置。
- **游標回報**：每 33 ms 檢查實體游標，有變才送；收到手機滑鼠事件後 0.5 秒內不回報，避免主機回報和手機本地游標互相拉扯。

## ⚠️ 會中招的點

### 缺螢幕錄製權限時，表現是「連上就斷」
ScreenCaptureKit 會回 `使用者拒絕應用程式、視窗、顯示器擷取的TCC`，主機隨即關掉連線，手機只看到「連線中斷」。**實際上**權限綁在 App 的程式碼簽章上，使用者以為開了、實際上開的可能是別的版本。主機啟動時會跑 `CGPreflightScreenCaptureAccess()` 並寫進 log（`螢幕錄製權限預檢：true/false`），以這個為準；false 時再呼叫 `CGRequestScreenCaptureAccess()` 讓系統把 App 加進設定清單。

### 低延遲模式下編碼器回報屬性「不支援」是正常的
log 會出現 `編碼器不支援 MaxFrameDelayCount（-12900）`、`PrioritizeEncodingSpeedOverQuality（-12900）`。**實際上**低延遲 rate control 本來就是收一幀出一幀，這兩個設定沒有空間，不是 bug。編碼一幀約 9～10 ms，是延遲中最大的單一來源，但已經是硬體本身的速度。

### 捲動事件送到了但畫面不動
游標停在網頁的內嵌媒體區（影片／iframe）時，捲動被那個元件吃掉。log 的 `scrolls=` 計數會增加但流量不變。量測時要把游標放在正文上。

## 觀察用 log

subsystem `tw.firstfu.DeskPilotHost`、category `host`。連線期間每秒一行 `stats fps= kbps= encodeMs= ax= scrolls=`；連線時印實際使用的編碼器與解析度；手機量測結果以 `量測回報：` 開頭。讀法見 `../operations.md`。
