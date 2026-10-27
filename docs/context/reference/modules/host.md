# Mac 主機模組（DeskPilotHost）

> **何時讀**：改 `DeskPilot/DeskPilotHost/` 任何檔（擷取、編碼、輸入注入、主機 UI），或遇到「連上就斷」「畫面不動」「流量異常」「手機操作沒反應」時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是主機端的單一事實源；協定細節見 `protocol.md`，建置測試見 `../operations.md`。

## 模組定位

macOS App，非沙箱（`ENABLE_APP_SANDBOX = NO`，CGEvent 注入需要）。同一時間只服務一支手機，新連線會取代舊的。流程：`HostController` 發 Bonjour → `HostSession` 收 Hello → `ScreenCapturer`（ScreenCaptureKit）→ `VideoEncoder`（VideoToolbox）→ TCP；反向 `InputInjector` 把事件轉成 CGEvent。

## 選單列 App 與權限引導

- `LSUIElement`（Info.plist）：沒有 Dock 圖示，只有選單列圖示（正常 `display`、已連線 `display.and.arrow.down`、缺權限 `exclamationmark.triangle`）。主機在選單列圖示的 `.task` 啟動，主視窗 `defaultLaunchBehavior(.suppressed)` 平常不開。
- 主視窗自動跳出的時機：缺任一權限、手機要求配對（要看確認碼）、環境變數 `DESKPILOT_SHOW_WINDOW` 有設（量測用，`host-bench.sh start` 已帶，探針標記在視窗上要看得到）。
- 權限清單每秒輪詢更新，使用者在系統設定打開開關後視窗自動打勾。螢幕錄製在授權後**要重開 App 才生效**（`needsRelaunch`＝啟動時沒權限、現在有），視窗提供「立即重新啟動」：交給 shell 延遲 1 秒再 `open -n`，讓舊程序先放掉監聽埠。
- 選單有「開機時自動啟動」（`SMAppService.mainApp`，預設關）。
- 選單也有外網相關項目（自動開埠開關、通道元件安裝、配對手機）：整套機制見 `external-access.md`。

## 擷取與編碼的關鍵設計

- **閒置不編碼**：ScreenCaptureKit 在畫面沒變時送 `.idle` 狀態的影格，直接丟棄 → 閒置 0 影像流量。只有 `.complete` 才送去編碼。
- **擷取格式**：直接要 420v（硬體編碼器原生格式，省一次色彩轉換），`showsCursor = false`（游標由手機本地畫），`minimumFrameInterval` 1/60 秒，`queueDepth = 4`（靜止補強會長期持有一張 buffer，比最低值 3 多留一格）。
- **編碼解析度**：平常 `min(1, 手機像素 / Mac 原生像素)` 等比縮小，不傳手機顯示不了的像素；手機放大時（`setDetail` = 1）改整個桌面原生解析度，小字才清楚。換解析度時重建編碼器（世代計數丟掉舊輸出）、`updateConfiguration` 改擷取大小，過渡期尺寸不符的畫面直接丟。
- **不要只擷取可見範圍**：2026-10-26 試過用 `sourceRect` 只傳手機看得到的那塊，縮小或平移時超出範圍的地方會黑一下、很不流暢，使用者否決，改成上面的整桌面升解析度。
- **編碼器選擇順序**：HEVC 低延遲 → H.264 低延遲 → HEVC 一般。低延遲模式不重排（無 B-frame）；關鍵幀只在手機要求時產生（`MaxKeyFrameInterval` 設很大）。
- **背壓**：在途影格 ≥ 2 就丟掉新擷取的畫面，寧可少一幀也不讓 socket 佇列越積越長。
- **色彩標記**：擷取設 `colorSpaceName = sRGB`、`colorMatrix = ITU_R_709_2`，編碼器明確標 BT.709 原色／轉換函數／矩陣。沒標的話解碼端自己猜，廣色域螢幕（內建 XDR 是 P3）的顏色會偏淡或偏色（2026-10-25 加入，效果尚未經使用者明確確認）。
- **靜止畫質補強**：畫面停止變化 120 ms 後，把最後一張再編碼 3 次。編碼器比對的是「原圖」與「上一張解碼後的模糊結果」，所以重複送同一張會逐步補回細節。這讓移動中可以用很低的位元率，停下後文字又清楚；每次停頓只多花幾十 KB。

## 省流量、聲音、剪貼簿（v6）

- **省流量模式**（`setSaver`）：位元率文字 ≤ 1 Mbps、影片 3 Mbps、靜止補強 4 Mbps 且只補 3 次、擷取降到 30 fps，並且不升原生解析度（手機放大的需求先記著，關掉省流量再還原）。狀態存在鎖保護的旗標裡，擷取佇列與工作階段佇列都會讀。
- **聲音**（`setAudio`）：`SCStreamConfiguration.capturesAudio` 預設關，手機要求時才用 `updateConfiguration` 打開，排除本 App 自己的聲音；`AudioEncoder` 把 48 kHz 立體聲 PCM 累積成 1024 frames 一塊壓成 AAC-LC 64 kbps。**連續靜音超過約 0.5 秒就不再輸出**，沒聲音就沒流量。
- **剪貼簿**：`NSPasteboard.general` 讀寫在主執行緒，送回手機再回工作階段佇列；文字上限 1 MB。手機端先送剪貼簿、再延遲 200 ms 才送 ⌘V，因為主機寫剪貼簿是非同步的。
- **移除已配對裝置會立即斷線**：交握時記下手機回報的裝置 ID（明文，授權前不可信，只用來比對），移除時關掉該 ID 的連線（包含未授權的）。

## 多螢幕切換

- 螢幕序號＝`CGGetActiveDisplayList` 排序後的位置：主螢幕排第一，其餘依 `CGDisplayBounds.minX` 由左到右。手機只送序號（`selectDisplay`），主機每次開始或切換串流後回 `displayInfo`。
- 切換**不斷線**：等舊擷取確實停下（`stopAndWait`，避免舊螢幕影格混進新解析度的編碼器）→ 換 `InputInjector.displayID` 並把實體游標移到新螢幕中央 → 依新螢幕重建編碼器與擷取 → 重送 `helloAck`（手機據此更新桌面大小）。游標回報與補強計時器沿用，不重建。
- 座標換算、游標回報都以「操控中的螢幕」為準，不再寫死 `CGMainDisplayID()`。

## 位元率與 codec 的決策依據

- **移動中預設 2 Mbps**（`DESKPILOT_BITRATE` 可覆寫），畫面停下後靜止補強期間暫時拉到 8 Mbps、補 5 次，下一張真實影格還原；影片模式 6 Mbps。2026-10-25 實機（內建 3024×1964 Retina 縮到約 1986×1290）固定 1 Mbps 小字明顯糊、固定 6 Mbps 清楚，因而改成「移動省、停下補」。下面的 1 Mbps 數據是模擬器掃描，只代表流量下限，不代表清晰度夠用。2026-10-24 模擬器掃描（HEVC、1080p、每秒捲 720 px）：6 Mbps → 捲動 3.58 Mbps；2 Mbps → 1.82 Mbps；1 Mbps → **0.96 Mbps**，延遲中位數三者都在 22～25 ms，差異在誤差內。1 Mbps 對齊微軟 RDP AVC444 官方數字（1080p 網頁瀏覽 0.9～1 Mbps），停下後與 6 Mbps 截圖看不出差別。
- **已知取捨**：看影片或大面積動畫時 1 Mbps 會偏糊；捲動「進行中」的清晰度只在模擬器看過，尚未實機確認。之後計畫依內容自動調整。
- **HEVC 為預設**（`DESKPILOT_CODEC=h264` 可切）。2026-10-23 A/B：延遲差約 3 ms（誤差內），但捲動流量 HEVC 比 H.264 省約 18%。

## 輸入注入

- 需要「輔助使用」權限；沒權限時 CGEvent 會被系統默默丟掉，不報錯。主機 log 的 `ax=` 欄位可確認。
- **雙擊**：macOS 靠事件上的 `mouseEventClickState` 判斷雙擊，主機自己依時間（系統雙擊間隔）和距離（< 8 pt）計算，手機端連點兩下就好，不用等待。
- **文字**：用 `CGEventKeyboardSetUnicodeString` 直接注入 Unicode，單次上限約 20 個 UTF-16 單位，長字串要分段。電腦端目前是中文還是英文輸入模式都不影響。
- **捲動**：像素單位，並明確設定事件位置為目前游標位置。
- **座標上限是最後一個像素**（`maxX - 1`／`maxY - 1`）：正規化 1.0 若直接換成 `maxX/maxY`，位置在螢幕外一格，系統不認為游標「頂到邊」，自動隱藏的 Dock 叫不出來。
- **⚠️ 按鍵放開事件旗標必須清空**：`.key` 的 down 帶修飾旗標、up 一律 `flags = []`。up 若也帶 ⌃，macOS 的修飾鍵狀態（`CGEventSourceFlagsState`）會卡住，之後所有滑鼠點擊變成 ⌃＋點擊＝右鍵選單，症狀是「單指點一下就跳選單」。2026-10-27 由手機四指手勢（⌃＋方向鍵）觸發；診斷用 `python3 -c "import Quartz as Q;print(hex(Q.CGEventSourceFlagsState(1)))"`，正常為 `0x20000000`，含 `0x40000` 就是 ⌃ 卡住。
- **游標回報**：每 33 ms 檢查實體游標，有變才送；收到手機滑鼠事件後 0.5 秒內不回報，避免主機回報和手機本地游標互相拉扯。

## ⚠️ 會中招的點

### 缺螢幕錄製權限時，表現是「連上就斷」
ScreenCaptureKit 會回 `使用者拒絕應用程式、視窗、顯示器擷取的TCC`，主機隨即關掉連線，手機只看到「連線中斷」。**實際上**權限綁在 App 的程式碼簽章上，使用者以為開了、實際上開的可能是別的版本。主機啟動時會跑 `CGPreflightScreenCaptureAccess()` 並寫進 log（`螢幕錄製權限預檢：true/false`），以這個為準；false 時再呼叫 `CGRequestScreenCaptureAccess()` 讓系統把 App 加進設定清單。

**另一個成因：App 放在 Launch Services 不認得的位置**（例如 build 到 `/private/tmp`）。這時使用者在系統設定開了開關也不生效，預檢一直是 false，`tccutil reset ScreenCapture tw.firstfu.DeskPilotHost` 回 `No such bundle identifier`（-10814）。改回 Xcode 預設的 DerivedData 再 build、`tccutil reset` 清掉舊授權、讓 App 重新登記、使用者重新開啟並「立即重新啟動」後恢復（2026-10-27；當時路徑與舊授權殘留是同時修的，沒有分開驗證各自的貢獻）。症狀完整對應：區網與外網都「連線中斷」、交握已通過、主機 log 有 `無法開始串流：使用者拒絕…TCC`。

### 低延遲模式下編碼器回報屬性「不支援」是正常的
log 會出現 `編碼器不支援 MaxFrameDelayCount（-12900）`、`PrioritizeEncodingSpeedOverQuality（-12900）`。**實際上**低延遲 rate control 本來就是收一幀出一幀，這兩個設定沒有空間，不是 bug。編碼一幀約 9～10 ms，是延遲中最大的單一來源，但已經是硬體本身的速度。

### 捲動事件送到了但畫面不動
游標停在網頁的內嵌媒體區（影片／iframe）時，捲動被那個元件吃掉。log 的 `scrolls=` 計數會增加但流量不變。量測時要把游標放在正文上。

### 從 WireGuard 通道連不進來（Network.framework 看不到 utun）
Homebrew 版 `wireguard-go` 建的 utun 介面不會登記到系統網路設定，`NWPathMonitor` 的可用介面清單裡沒有它，`NWListener` 也不會在上面收連線（手機表現為「連線中斷」，主機 log 完全沒有連線紀錄）。**做法**：`TunnelRelay` 用 BSD socket 監聽 utun 上的 IPv4 位址（每 10 秒重掃），收到後轉到 `127.0.0.1:52830`。兩個雷：①必須等主監聽器 `.ready` 後才開轉接，否則轉接先綁特定位址，主監聽器綁萬用位址會 `Address already in use`；②`accept` 出來的 socket 會繼承監聽 socket 的 `O_NONBLOCK`，要清掉，否則阻塞式轉送迴圈第一次讀不到就當成對方關閉、把兩端一起切斷（兩端 log 都說「對方關閉連線」）。

### 重 build 主機後被防火牆擋
macOS 防火牆開啟時，重新 build 的 DeskPilotHost 可能被改成「阻擋連入」，區網與通道都連不上。用 `socketfilterfw --listapps` 檢查，`sudo socketfilterfw --unblockapp <App 路徑>` 放行。

### 選單的勾選不更新（`@Observable` 不追蹤 `UserDefaults`）
選單的 Toggle 若用 `UserDefaults.standard.bool(...)` 當 getter，SwiftUI 不會追蹤它的變化，點了之後畫面不打勾；使用者以為沒生效又點一次，反而把它關掉。**實際上**設定已寫入。做法：開關狀態存在 `@Observable` 類別的儲存屬性（`ExternalAccessController.isEnabled`），再同步寫進 `UserDefaults`。

### 連線來源限制
主機只接受私有網段（10/8、172.16/12、192.168/16、127/8、169.254/16、IPv6 link-local／ULA）的連線；新連線最多 4 條未驗證、交握 10 秒逾時、配對請求 60 秒沒回應視同拒絕。

## 觀察用 log

subsystem `tw.firstfu.DeskPilotHost`、category `host`。連線期間每秒一行 `stats fps= kbps= encodeMs= ax= scrolls=`；連線時印實際使用的編碼器與解析度；手機量測結果以 `量測回報：` 開頭。讀法見 `../operations.md`。
