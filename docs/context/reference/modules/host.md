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
- 選單有「開機時自動啟動」（`SMAppService.mainApp`）。**預設開**（2026-11-23 起）：每次啟動若沒註冊就補註冊，使用者在選單關掉才記住不要（`UserDefaults` 的 `launchAtLoginOptOut`）。原因是重開機後主機沒起來，區網與外網都連不上，最容易被忘記。
- 同時只跑一份：啟動時發現已有同 bundle id 的主機在跑，新的這份自己結束（舊的 System Events 登入項目與 `SMAppService` 同時帶起來時，不會兩份搶 52830 埠）。

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
- **螢幕會在主機跑著時消失**（闔上筆電、拔掉外接螢幕、螢幕睡著），所以操控中的螢幕不能只在啟動時記一次（2026-11-23 起）：
  - 開始串流時（`beginStreaming`）先叫醒螢幕（`IOPMAssertionDeclareUserActivity`），串流期間持有 `PreventUserIdleDisplaySleep`，斷線時放掉；記住的螢幕不在作用中清單就改用目前的主螢幕；失敗每秒重試，最多 5 次。
  - 擷取中途停掉（`SCStream` 的 `didStopWithError`）或螢幕配置變了（`NSApplication.didChangeScreenParametersNotification`）且操控中的螢幕不見：停掉舊擷取，換到還在的螢幕重開，流程同切換螢幕（重送 `helloAck`，不斷線）。配置變了但螢幕還在，只重送 `displayInfo`。一分鐘內中斷超過 3 次就放棄。
  - 都救不回來時送 `hostError`（UTF-8 原因）再等 1 秒斷線，手機顯示原因而不是「連線中斷」。完全沒有作用中的螢幕（筆電闔上又沒接外接螢幕）時沒有東西可以擷取，只能顯示原因。
  - 已在實機驗證（2026-11-24）：兩次外網連線都是先「沒有作用中的螢幕」，叫醒後擷取中斷，再自動換到另一台螢幕接回。

## 單一視窗與解析度配合手機（2026-11-24 起，尚未實機測）

- **單一視窗**（`selectWindow`）：手機座標 0～1 對應的範圍從「螢幕」換成「視窗」（`InputInjector.targetBounds`＝`windowFrame ?? 螢幕`，游標回報同一個範圍）。擷取**不用** `desktopIndependentWindow`，而是拍視窗所在的整台螢幕、用 `sourceRect` 裁出視窗，這樣蓋在視窗上的右鍵選單、下拉選單才拍得到（代價是視窗被別的視窗蓋住時拍到的是蓋住的東西）。選視窗時用輔助使用介面把該 App 帶到前景、視窗升到最上層（用位置與大小比對視窗），打字才進得到。視窗位置只讀成「裁在所在螢幕內」的範圍。
- 每 0.5 秒檢查視窗（`checkWindow`）：只是移動→更新範圍並 `setCrop`；大小變了且下一次檢查仍相同（拖曳縮放結束）→重開擷取並重送 `helloAck`；移到別台螢幕或關掉→走 `recoverCapture`，視窗不在就改回整個螢幕。
- **解析度配合手機**（`setFitResolution`）：把串流中的螢幕切到同比例、寬度最接近 1280 point 的較小模式，同寬優先 HiDPI（像素是 point 兩倍，字不糊）；這台 Mac 兩台 1920×1080 螢幕都挑到 1280×720（螢幕 2 有 HiDPI，螢幕 3 沒有，會略糊）。用 `CGConfigureDisplayWithDisplayMode` 的 `.forSession` 套用：主機程式結束（含當掉）時系統自動還原；斷線、關掉選項時主機也明確還原。切換螢幕時舊的先還原、新的再改小。實體螢幕會跟著變，Mac 前面有人時看得到。

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

### 手機通過驗證卻「連線中斷」：主機 log 有 `找不到螢幕`
2026-11-23 外網連不上的真正原因：Tunnel、權限、防火牆都正常，手機也通過驗證，但主機 02:32 啟動時記下的螢幕之後不在了（推測是闔上筆電，作用中只剩兩台外接螢幕），每次開始擷取都回 `找不到螢幕`。查法：`/usr/bin/log show … --predicate 'subsystem == "tw.firstfu.DeskPilotHost"'` 看 `交握：驗證` 之後接什麼。已改成自動換到還在的螢幕（見上方「多螢幕切換」）；注意主機 log 的 subsystem 是 `tw.firstfu.DeskPilotHost`，`tw.firstfu.DeskPilot` 只有連線層的訊息。

### Mac 停在鎖定畫面時，手機打不了字（滑鼠可以）
鎖定畫面的密碼欄位由 `loginwindow` 開啟**安全輸入**（Secure Event Input），只收實體鍵盤，`CGEvent` 注入的鍵盤事件一律進不去；這是 macOS 的保護，`ax=true` 也一樣，只有 Apple 自己有特權的工具（如內建螢幕共享）能打。終端機的「安全鍵盤輸入」、密碼管理程式開著時也會這樣。2026-11-24 的「從手機無法打字」就是這個：Mac 從早上鎖到傍晚，手機連進來時主機叫醒螢幕，看到的是密碼畫面。
- 查法：`/usr/bin/log show … --predicate 'process == "loginwindow" AND eventMessage CONTAINS "LWScreenLock"'`，`enqueueLockScreenRequest`＝鎖、`handleUnlockResult`＝解鎖嘗試結束；目前狀態看 `CGSessionCopyCurrentDictionary()` 的 `CGSSessionScreenIsLocked`（解鎖時這個鍵不存在）。看誰開著安全輸入：`ioreg -l -w 0 | grep kCGSSessionSecureInputPID`。
- 主機會在鎖定／解鎖時送 `hostState`，手機常駐提示「Mac 已鎖定」（2026-11-24 起），所以使用者看得出不是鍵盤壞了；但**解不開**。
- 避免被鎖：關掉「系統設定 › 鎖定畫面 › 螢幕保護程式啟動或螢幕關閉後需要密碼」（改「永不」）。**iPhone 鏡像輸出設成「自動認證」時這項被強制鎖成「立即」**（畫面上是灰的），`sysadminctl -screenLock off -password -` 回 `MKBDeviceSetGracePeriod error -14`；要先到 iPhone 鏡像輸出的設定改成「每次都詢問」。改完用 `sysadminctl -screenLock status` 確認（`screenLock is off`）。重開機、系統更新、手動鎖定仍會鎖，從手機解不開。

### 缺螢幕錄製權限時，表現是「連上就斷」
ScreenCaptureKit 會回 `使用者拒絕應用程式、視窗、顯示器擷取的TCC`，主機隨即關掉連線，手機只看到「連線中斷」。**實際上**權限綁在 App 的程式碼簽章上，使用者以為開了、實際上開的可能是別的版本。主機啟動時會跑 `CGPreflightScreenCaptureAccess()` 並寫進 log（`螢幕錄製權限預檢：true/false`），以這個為準；false 時再呼叫 `CGRequestScreenCaptureAccess()` 讓系統把 App 加進設定清單。

**另一個成因：App 放在 Launch Services 不認得的位置**（例如 build 到 `/private/tmp`）。這時使用者在系統設定開了開關也不生效，預檢一直是 false，`tccutil reset ScreenCapture tw.firstfu.DeskPilotHost` 回 `No such bundle identifier`（-10814）。改回 Xcode 預設的 DerivedData 再 build、`tccutil reset` 清掉舊授權、讓 App 重新登記、使用者重新開啟並「立即重新啟動」後恢復（2026-10-27；當時路徑與舊授權殘留是同時修的，沒有分開驗證各自的貢獻）。症狀完整對應：區網與外網都「連線中斷」、交握已通過、主機 log 有 `無法開始串流：使用者拒絕…TCC`。

### 低延遲模式下編碼器回報屬性「不支援」是正常的
log 會出現 `編碼器不支援 MaxFrameDelayCount（-12900）`、`PrioritizeEncodingSpeedOverQuality（-12900）`。**實際上**低延遲 rate control 本來就是收一幀出一幀，這兩個設定沒有空間，不是 bug。編碼一幀約 9～10 ms，是延遲中最大的單一來源，但已經是硬體本身的速度。

### 捲動事件送到了但畫面不動
游標停在網頁的內嵌媒體區（影片／iframe）時，捲動被那個元件吃掉。log 的 `scrolls=` 計數會增加但流量不變。量測時要把游標放在正文上。

### 重 build 主機後被防火牆擋
macOS 防火牆開啟時，重新 build 的 DeskPilotHost 可能被改成「阻擋連入」，區網連不上（cloudflared 走本機回送位址，不受影響）。用 `socketfilterfw --listapps` 檢查，`sudo socketfilterfw --unblockapp <App 路徑>` 放行。

### 選單的勾選不更新（`@Observable` 不追蹤 `UserDefaults`）
選單的 Toggle 若用 `UserDefaults.standard.bool(...)` 當 getter，SwiftUI 不會追蹤它的變化，點了之後畫面不打勾；使用者以為沒生效又點一次，反而把它關掉。**實際上**設定已寫入。做法：開關狀態存在 `@Observable` 類別的儲存屬性（例如已移除的外網開關 `ExternalAccessController.isEnabled`；現存的「開機時自動啟動」改讀 `SMAppService.mainApp.status`），再同步寫進 `UserDefaults`。

### 連線來源限制
主機只接受私有網段（10/8、172.16/12、192.168/16、127/8、169.254/16、IPv6 link-local／ULA）的連線；新連線最多 4 條未驗證、交握 10 秒逾時、配對請求 60 秒沒回應視同拒絕。

## 觀察用 log

subsystem `tw.firstfu.DeskPilotHost`、category `host`。連線期間每秒一行 `stats fps= kbps= encodeMs= ax= scrolls=`；連線時印實際使用的編碼器與解析度；手機量測結果以 `量測回報：` 開頭。讀法見 `../operations.md`。
