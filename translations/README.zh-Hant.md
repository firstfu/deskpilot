<div align="center">

# DeskPilot

**用 iPhone 操控 Mac——為辦公情境設計，不是遊戲。**

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](../LICENSE)
![macOS 27+](https://img.shields.io/badge/macOS-27%2B-black?logo=apple)
![iOS 27+](https://img.shields.io/badge/iOS-27%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-orange?logo=swift)

[功能](#功能) · [目前狀態](#目前狀態) · [從原始碼建置](#從原始碼建置) · [外網連線](#外網連線選用) · [安全模型](#安全模型) · [常見問題](#常見問題)

[English](../README.md) · 繁體中文

</div>

> [!NOTE]
> **目前沒有可下載的版本。** DeskPilot 是需要自己建置的專案：沒有公證過的 `.app`，也不在 App Store 或 TestFlight。你要用 Xcode 建置兩端，並以自己的 Apple ID 簽章。詳見[目前狀態](#目前狀態)。

## 為什麼做 DeskPilot

多數遠端桌面為影片調校：不管畫面有沒有變，都持續編碼、傳送。辦公桌面大多是靜止的文字，DeskPilot 就是照這個前提設計：

- **沒變就不傳。** 畫面沒變化時完全不編碼、不送資料。
- **不傳手機顯示不了的像素。** 編碼解析度上限＝iPhone 螢幕。
- **手指不等網路。** 游標在手機上繪製，捏合縮放也在手機本地處理。
- **中文輸入可用。** 文字以 Unicode 直接注入，不經 Mac 上的輸入法。

## 功能

### 觸控板式操控

| 手勢 | 動作 |
|---|---|
| 單指滑 | 移動游標（有加速度） |
| 單指點／連點 | 左鍵／雙擊 |
| 雙指點 | 右鍵 |
| 雙指捏合 | 放大縮小 1～6 倍，只在手機本地 |
| 雙指滑 | 放大時平移檢視，未放大時捲動 |
| 長按後拖 | 按住拖曳 |
| 三指滑 | 捲動 Mac |
| 四指滑 | Mission Control、App Exposé、切換桌面 |

點擊與拖曳有觸覺回饋。四指手勢送的是標準 <kbd>⌃</kbd> 組合鍵，需要 Mac「鍵盤快速鍵」裡對應項目維持開啟。

### 快捷鍵列

四個大按鈕——Mission Control、Spotlight、切換 App、截圖——加上可橫向捲動的黏滯修飾鍵（<kbd>⇧</kbd> <kbd>⌃</kbd> <kbd>⌥</kbd> <kbd>⌘</kbd>）、方向鍵、Esc／Tab／Return、拷貝與貼上。

### 輸入與剪貼簿

注音、倉頡等組字輸入法，會等你選字確認後才送出，Mac 不會收到打到一半的注音符號。拷貝、貼上是明確的按鈕，而非背景同步，避免 iOS 的「允許貼上」提示。

### 穩定的連線

同一個 Wi-Fi 下 Bonjour 自動找到 Mac。斷線時手機停在最後一張畫面，依退避時間自動重連並重送設定。省流量模式（自動／開／關）在行動網路降低位元率。支援多螢幕切換與聲音。

## 目前狀態

| 項目 | 狀態 |
|---|---|
| 區網（LAN）連線 | 已在實機測試 |
| 外網（行動網路 → 通道 → Mac） | **端到端尚待實測** |
| 公證版本／App Store／TestFlight | 無 |

文件中的數字（例如捲動約 1 Mbps）來自模擬器量測與 App 內建量測，不是受控實驗室的結果。

## 從原始碼建置

需要 Mac 與 iPhone（符合專案部署目標：macOS 27、iOS 27）、對應版本的 Xcode，以及一個 Apple ID。免費 Apple ID 即可 build，但**免費帳號簽的 App 約 7 天後過期**，需重新安裝。只有外網功能才需要 Go。

```sh
git clone https://github.com/firstfu/deskpilot.git && cd deskpilot
scripts/build-wireguard-go.sh   # 只有要用外網功能時
open DeskPilot/DeskPilot.xcodeproj
```

1. 在 Xcode 的每個 target 的 Signing 選你自己的 Team，必要時改掉 bundle identifier（`tw.firstfu.*`）。
2. 把 [`DeskPilot/Shared/HelperProtocol.swift`](../DeskPilot/Shared/HelperProtocol.swift) 的 `teamID` 改成你的 Team ID。特權 helper 只接受同 Team 簽出的主機 App，沒改的話外網通道連不上 helper。
3. 建置 Mac 的 **DeskPilotHost** 與 iPhone 的 **DeskPilot**。
   Mac 的 build 產物請放在 Xcode 預設的 DerivedData，不要放 `/private/tmp` 之類的暫存路徑，否則螢幕錄製權限不會生效。
4. 在 Mac 的「系統設定 › 隱私權與安全性」授予**螢幕與系統錄音**與**輔助使用**，改完要重開主機 App。

### 區網連線

1. Mac 開啟主機 App，iPhone 開啟 DeskPilot，會自動找到 Mac。
2. 首次連線在 Mac 上核對 6 位數並按允許；之後以 Keychain 金鑰自動驗證，每次連線前手機需要 Face ID。

## 外網連線（選用）

在外面時，DeskPilot 經 WireGuard 通道連回家，Mac 當伺服器，全部內建於 Mac App：

1. 在選單列開啟「外網連線（自動開埠）」。路由器需支援 NAT-PMP 或 UPnP，否則要自己轉發 UDP 51820。
2. 點「安裝外網通道元件…」，到「系統設定 › 登入項目」核准一次。
3. 點「配對手機（外網）…」顯示 QR code，用 iPhone 上的**官方 WireGuard App** 掃描匯入。
4. 手機關掉 Wi-Fi、開啟通道，DeskPilot 選「在外面」並輸入 `10.66.0.1`。

首次配對請人在 Mac 旁邊。QR code 內的位址是當下的公網 IP，IP 變動後要重新產生。若路由器之後還有一層 NAT（例如營運商 CGNAT），無法直連。

## 安全模型

- 所有連線加密且需配對（見[協定說明](../docs/context/reference/modules/protocol.md)）。
- 外網通道只開放給 WireGuard，主機只接受私有網段來源，DeskPilot 本身不直接暴露在公網。
- 特權 helper 以 root 執行，但只開放固定方法，不接收路徑、指令字串或設定檔；呼叫者以程式碼簽章驗證。手機私鑰只存在 QR code 裡，Mac 不保存。
- 每次連線前需要 Face ID（或手機密碼），手機遺失時撿到的人拿不到 Mac 控制權。

> [!WARNING]
> 免費的 Apple Development 憑證不經 Apple 公證，簽章驗證的保護力弱於 Developer ID，目前只適合自用。

## 常見問題

<details>
<summary><b>連上後畫面是黑的</b></summary>

確認主機 App 已取得「螢幕與系統錄音」權限，且授權後重開過主機 App；也確認主機 App 是建置在 Xcode 預設的 DerivedData，而不是暫存路徑。
</details>

<details>
<summary><b>iPhone App 用了一週就打不開</b></summary>

免費 Apple ID 簽的 App 約 7 天後過期。重新建置安裝，或改用付費開發者帳號。
</details>

<details>
<summary><b>四指滑沒反應</b></summary>

它送的是 <kbd>⌃</kbd>＋方向鍵。到「系統設定 › 鍵盤 › 鍵盤快速鍵」，保持 Mission Control 與空間相關項目開啟。
</details>

<details>
<summary><b>外網連不上</b></summary>

確認路由器支援 NAT-PMP 或 UPnP（或自己轉發 UDP 51820）、不在 CGNAT 後面、QR code 是用當下的公網 IP 產生的。另外這條路徑還沒做過端到端驗證。
</details>

## 專案結構

| 位置 | 內容 |
|---|---|
| `DeskPilot/DeskPilot/` | iPhone 端：顯示、手勢、中文輸入 |
| `DeskPilot/DeskPilotHost/` | Mac 主機：螢幕擷取、編碼、輸入注入、外網控制 |
| `DeskPilot/DeskPilotHelper/` | 特權 helper（root LaunchDaemon），啟停 WireGuard |
| `DeskPilot/Shared/` | 兩端共用的協定與加密 |
| `docs/context/` | 架構、協定、維運與踩雷紀錄，從 [`overview.md`](../docs/context/reference/overview.md) 開始讀 |

## 參與貢獻

一個人開發，歡迎 issue 與 pull request，見 [CONTRIBUTING.md](../CONTRIBUTING.md)。最有用的回報會附上 macOS 與 iOS 版本、走區網還是外網，以及畫面上看到什麼。

## 第三方元件

外網通道使用 [wireguard-go](https://git.zx2c4.com/wireguard-go)（MIT），由釘死版本的上游原始碼編譯。為避免 GPL 義務，刻意不打包 `wireguard-tools`。

## 授權

[MIT](../LICENSE)。
