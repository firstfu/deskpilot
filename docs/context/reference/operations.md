# 建置、執行與測試

> **何時讀**：要 build／執行主機或手機 App、跑量測、或用模擬器驗證功能前。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。

## 建置

- 專案：`DeskPilot/DeskPilot.xcodeproj`，scheme `DeskPilot`（iOS）與 `DeskPilotHost`（macOS）。
- **Xcode MCP 對這個專案不可用**（2026-10-27）：它回報 workspace 沒有 scheme、也列不出 target template，無法 build 或新增 target。改用 `xcodebuild -project … -scheme … build`；新增 target／build phase 用 `xcodeproj` gem 寫腳本改（專案格式版本 110 比 gem 支援的新，改之前先備份 `project.pbxproj`，並確認讀寫一輪只多空陣列與註解差異）。
- **第一次 build 主機前**要先跑 `scripts/build-wireguard-go.sh`（`wireguard-go` 二進位檔不進 repo，見 `modules/external-access.md`）。
- **build 產物不要放 `/private/tmp` 這類暫存路徑**：Launch Services 不認得，螢幕錄製權限會不生效、`tccutil reset` 回 -10814、helper 的註冊路徑也會在重開機後消失。用 Xcode 預設的 DerivedData（下一條）。
- 開發簽章 Team：見 Xcode 專案的 Signing 設定。
- 主機 build 產物：`~/Library/Developer/Xcode/DerivedData/DeskPilot-falljhyhqgfaxvektnwjdczkiuli/Build/Products/Debug/DeskPilotHost.app`。

## 裝到實機與即時看手機 log

- 列裝置與 UDID：`xcrun devicectl list devices`。
- build＋安裝：`xcodebuild -project DeskPilot/DeskPilot.xcodeproj -scheme DeskPilot -configuration Debug -destination 'id=<UDID>' -derivedDataPath <目錄> -allowProvisioningUpdates build`，再 `xcrun devicectl device install app --device <UDID> <目錄>/Build/Products/Debug-iphoneos/DeskPilot.app`。安裝偶爾回 `Connection invalid`，重跑一次通常就好。
- **即時看手機端輸出**：`xcrun devicectl device process launch --console --terminate-existing --device <UDID> tw.firstfu.DeskPilot`，App 的 stdout 會串回終端機。手機鎖定時會失敗（`Locked`），要先解鎖。2026-10-26 排查「兩端都說對方先斷線」就是靠這個確認手機端沒有主動斷。
- 免費開發者帳號簽的 App 約 7 天後簽章過期、App 打不開，要重新安裝。
- 有多支實體 iPhone 都配對過時，`devicectl list devices` 會全列出來，**先跟使用者確認要裝哪一支**，別猜。
- **手機在行動網路（對 Mac 不可達）時**，`devicectl` 顯示 `unavailable`，`process launch --console` 回 `error 4016`，看不到手機端 log；要看手機 log 得讓手機連回同一個 Wi-Fi（鎖屏另外會回 `Locked`）。測外網時因此只能靠 Mac 端 log 與 `netstat -I utun<N> -b` 的封包計數。

## 執行主機

- **建議用 `open` 直接啟動 build 產物**，不要用 Xcode 的 RunProject：
  - RunProject 重跑時舊主機程序不會結束，Bonjour 名稱會變成「…(2)」「…(3)」，手機清單出現多個主機、點到舊的就連不上。
  - Xcode 的 StopProject 停的是「目前 scheme 的 App」，切到 iOS scheme 後按停止會把手機端 App 停掉，而不是主機。
- 每次重開前先 `pkill -f DeskPilotHost.app`。
- macOS 防火牆開著時，**重 build 主機後可能被改成阻擋連入**，區網與外網都會連不上，處理方式見 `modules/host.md`「重 build 主機後被防火牆擋」。
- 量測腳本 `scripts/host-bench.sh`：
  - `start [hevc|h264] [位元率 bps]`：重開主機（預設 HEVC、2 Mbps），並排除 Device Hub 視窗。
  - `report`：等待並印出最新一次手機量測回報與編碼器資訊。
- 主機可用的環境變數：`DESKPILOT_CODEC`、`DESKPILOT_BITRATE`、`DESKPILOT_EXCLUDE_BUNDLES`（逗號分隔的 bundle id，不擷取這些 App）。

## 外網連線（內建於 Mac App）

機制、安全模型與雷見 `modules/external-access.md`。維運上要知道的：

- 使用者在選單列打開「外網連線（自動開埠）」＋「安裝外網通道元件…」（要到系統設定「登入項目」核准一次）＋「配對手機（外網）…」顯示 QR code，用手機官方 WireGuard App 掃描；手機關 Wi-Fi、開通道、DeskPilot「在外面」輸入 `10.66.0.1`。**首次配對要人在 Mac 旁邊**（Mac 上要核對 6 位數並按允許，也可以直接在通道上配對；或先在區網配對一次）。
- 不再需要手動的 `/etc/wireguard`、LaunchDaemon、`upnp-map.py`、DDNS 腳本。這些在 2026-10-27 查證時，這台 Mac 上已不存在。
- 看通道狀態：helper 的 `tunnelStatus`（要簽章相符的呼叫端）；不需要 root 的方法是 `netstat -I utun<N> -b`（`Ipkts` 是從手機收到的封包，0 代表手機還沒送到）與 `ifconfig`（看有沒有 `10.66.0.1`）。看 `wg show` 之類需要 root。
- Mac 連自己的通道位址會繞進 WireGuard，**無法在本機測外網路徑**，只能用手機行動網路實測。
- 換 helper 版本要 `sudo launchctl kickstart -k system/tw.firstfu.DeskPilotHost.helper`；App 搬位置要選單「重新安裝通道元件」。

## 權限（只能使用者手動開）

主機需要「系統設定 › 隱私權與安全性」裡的**螢幕與系統錄音**和**輔助使用**兩項，無法用腳本授權。改完要重開主機才生效。判斷是否真的有權限，看主機 log 的 `螢幕錄製權限預檢` 與 `stats` 行的 `ax=`。Claude 桌面 App 本身沒有輔助使用／螢幕錄製權限時，Claude 無法操作系統設定或截 Mac 螢幕，只能請使用者截圖。

## 讀主機 log

```sh
/usr/bin/log show --last 2m --predicate 'process == "DeskPilotHost"' --info
```
- 要寫完整路徑 `/usr/bin/log`：zsh 有同名內建指令會報 `too many arguments`。
- 在 Claude Code 的沙箱 Bash 裡讀不到系統 log，要關閉沙箱執行。

## 用模擬器測試（同一台 Mac 當主機和用戶端）

- **必須排除 Device Hub 視窗**：Xcode 的模擬器視窗屬於 **Device Hub（`com.apple.dt.Devices`）**，不是 `com.apple.iphonesimulator`。不排除的話，主機會擷取到模擬器正在顯示的串流畫面，形成無限迴圈（「靜止」時仍有約 50 fps）。`host-bench.sh start` 已自動排除。
- 驗證 Bonjour 要用模擬器：沙箱內的 `dns-sd` 沒有任何輸出，不能拿來判斷主機有沒有公告。
- 模擬器是 loopback（RTT < 1 ms），量到的延遲比實機 Wi-Fi 偏低；流量數字則與實機一致（由主機編碼端決定）。
- Mac 上若有東西一直在動（例如終端機的轉圈動畫），「靜止」流量不會是 0（實測約 220～260 kbps）；要驗證閒置 0 流量必須在完全不動的桌面上量。
- Xcode MCP 模擬器互動指令：點擊 `t x y`；拖曳 `drag x1 y1 x2 y2 按住秒數 移動秒數`（按住秒數設很短如 0.05，才不會觸發 App 的長按拖曳）。App 被切到背景時加 `activationBundleId: tw.firstfu.DeskPilot` 叫回前景。
