# 建置、執行與測試

> **何時讀**：要 build／執行主機或手機 App、跑量測、或用模擬器驗證功能前。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。

## 建置

- 專案：`DeskPilot/DeskPilot.xcodeproj`，scheme `DeskPilot`（iOS）與 `DeskPilotHost`（macOS）。用 Xcode MCP 開啟、build、run。
- 開發簽章 Team：`WY468E45SJ`。
- 主機 build 產物：`~/Library/Developer/Xcode/DerivedData/DeskPilot-falljhyhqgfaxvektnwjdczkiuli/Build/Products/Debug/DeskPilotHost.app`。

## 執行主機

- **建議用 `open` 直接啟動 build 產物**，不要用 Xcode 的 RunProject：
  - RunProject 重跑時舊主機程序不會結束，Bonjour 名稱會變成「…(2)」「…(3)」，手機清單出現多個主機、點到舊的就連不上。
  - Xcode 的 StopProject 停的是「目前 scheme 的 App」，切到 iOS scheme 後按停止會把手機端 App 停掉，而不是主機。
- 每次重開前先 `pkill -f DeskPilotHost.app`。
- 量測腳本 `scripts/host-bench.sh`：
  - `start [hevc|h264] [位元率 bps]`：重開主機（預設 HEVC、1 Mbps），並排除 Device Hub 視窗。
  - `report`：等待並印出最新一次手機量測回報與編碼器資訊。
- 主機可用的環境變數：`DESKPILOT_CODEC`、`DESKPILOT_BITRATE`、`DESKPILOT_EXCLUDE_BUNDLES`（逗號分隔的 bundle id，不擷取這些 App）。

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
