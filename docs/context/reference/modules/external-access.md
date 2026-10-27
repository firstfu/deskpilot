# 外網連線模組（ExternalAccess、DeskPilotHelper）

> **何時讀**：改 `DeskPilotHost/ExternalAccess/`、`DeskPilotHelper/`、`Shared/HelperProtocol.swift`，或遇到「外網連不上」「通道元件裝不起來」「QR 配對失敗」「自動開埠沒反應」時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是外網機制的單一事實源；協定細節見 `protocol.md`，主機本體見 `host.md`，建置與裝機見 `../operations.md`。

## 模組定位

讓手機在外面（行動網路）連回這台 Mac，全部內建在 Mac App 裡，不需要手動設定 WireGuard、LaunchDaemon 或路由器。**Mac 端全自動，手機端是一次性掃 QR code 匯入官方 WireGuard App**（手機端沒有內建通道，原因見下方決策）。

```
手機 WireGuard App ⇄ 路由器 UDP 51820 ⇄ Mac 的 wireguard-go（utun，10.66.0.1 ⇄ 10.66.0.2）
  → TunnelRelay 在 10.66.0.1:52830 監聽 → 主機本體（協定照舊，配對加密不變）
```

| 層 | 檔案 | 職責 |
|---|---|---|
| 開埠 | `ExternalAccess/PortMapper.swift` | 向路由器登記 UDP 51820：先 NAT-PMP，不行退回 UPnP-IGD（SSDP 找路由器 → SOAP `AddPortMapping`），租約 3600 秒 |
| 可達性 | `ExternalAccess/Reachability.swift` | 比對「路由器自己的 WAN 位址」與「外部服務看到的公網位址」，判斷直連可不可行 |
| 協調 | `ExternalAccess/ExternalAccessController.swift` | 開關狀態機；每 10 分鐘續約開埠＋重檢＋確保通道在跑；公網 IP 變動時提示；關閉時取消對映並停通道 |
| helper 客戶端 | `ExternalAccess/HelperClient.swift` | `SMAppService.daemon` 註冊、XPC 呼叫、重新安裝 |
| 固定網域 | `ExternalAccess/CloudflareDDNS.swift`、`DDNSSettingsView.swift` | 使用者填自己的 Cloudflare 主機名稱＋API Token（Token 存鑰匙圈），每輪檢查把 A 記錄（僅 DNS、TTL 60）更新成目前公網 IP；成功時 QR 的 Endpoint 改放名稱 |
| 配對 | `ExternalAccess/PairingView.swift` | 產生手機金鑰對與 QR code |
| helper 本體 | `DeskPilotHelper/main.swift`、`TunnelManager.swift` | 以 root 啟停 `wireguard-go`、管金鑰與 peer |
| XPC 介面 | `Shared/HelperProtocol.swift` | 方法清單與簽章要求字串 |
| launchd plist | `HelperSupport/tw.firstfu.DeskPilotHost.helper.plist` | 嵌進 App 的 `Contents/Library/LaunchDaemons/` |

`Reachability` 的結果：`direct`（可直連）、`behindNAT`（WAN 位址是私有／CGNAT 100.64.0.0/10，或與公網位址不同，直連不可能）、`offline`。選單據此顯示「可從外網連入」「請手動轉發」「沒有公網 IP」。

## 設計決策與「為什麼」

- **為什麼手機端沒有內建通道、也不用 CloudKit 交換 IP／金鑰**：使用者沒有付費 Apple Developer 帳號，拿不到 CloudKit 與 Network Extension entitlement。要做到手機端也全自動，需要付費帳號後補做 iPhone 的 Network Extension（WireGuardKit）與 CloudKit，現有設計不衝突。
- **為什麼不打包 `wg`**：`wireguard-tools` 是 GPLv2。金鑰用 CryptoKit（Curve25519）產生，通道設定由 helper 直接寫進 `wireguard-go` 的 UAPI socket（`/var/run/wireguard/<utunN>.sock`），不需要 `wg`。`wireguard-go` 本身是 MIT。
- **為什麼用特權 helper 而不是每次 sudo**：建立 utun 需要 root；helper 讓使用者只需在系統設定「登入項目」核准一次。
- **為什麼外網功能預設關閉**：區網直連不依賴它；開啟才會對路由器開埠、啟動 root 常駐元件。

## helper 的安全模型

- **只開放固定方法**：`version`、`startTunnel`、`stopTunnel`、`setPeer(publicKey)`、`removePeer`、`tunnelStatus`。**沒有任何接收路徑、指令字串或整份設定檔的參數**——`wg` 設定檔的 `PostUp` 可以執行任意指令，讓呼叫者傳設定等於提權後門。
- **呼叫者驗證**：XPC 連線用 `setCodeSigningRequirement`，只接受 `identifier "tw.firstfu.DeskPilotHost" and anchor apple generic and certificate leaf[subject.OU] = "<Team ID>"`；主機端也反過來只信任同 Team 簽出的 helper。免費 Apple Development 簽章下這套寫法可用（已驗：簽章相符的呼叫端可連、未簽章的程式被拒）。**限制**：憑證不經 Apple 公證，保護力弱於 Developer ID，只適合自用 Mac，不適合發布。
- **位址與埠寫死**：通道 10.66.0.1（Mac）⇄ 10.66.0.2（手機）、UDP 51820、MTU 1420；只允許一個 peer，且該 peer 的 AllowedIPs 固定為 `10.66.0.2/32`。唯一的外部輸入是手機公鑰，必須是 32 bytes 的 base64。
- **私鑰**：Mac 私鑰由 helper 產生，存 `/var/db/deskpilot/mac.key`（root、0600，`O_EXCL` 建立，沒有「先建後改權限」的空窗）；主機 App 只拿得到公鑰。**手機私鑰由主機 App 當場產生，只存在 QR code 裡，Mac 不保存**，helper 只收到它的公鑰；重新產生 QR 會讓前一支手機失效。
- **`wireguard-go` 的信任鏈**：App 內的二進位檔先驗簽章 → 複製到 `/var/db/deskpilot/bin/`（root 專屬）→ **對副本再驗一次**才執行，避免「驗完被使用者換掉」。簽章要求固定為 identifier `tw.firstfu.DeskPilotHost.wireguard-go` 加同 Team。
- 狀態目錄 `/var/db/deskpilot/`（root、0700）：`mac.key`、`peer.pub`、`bin/wireguard-go`、`tun.name`。

## 建置前置

`wireguard-go` 二進位檔**不進 repo**（6.5 MB）。第一次 build 前要跑 `scripts/build-wireguard-go.sh`：從上游原始碼編通用 arm64＋x86_64，版本與 commit 釘死（核對不符會中止），輸出到 `DeskPilotHost/Vendor/`。它會被同步資料夾自動拷進 App 的 `Resources/`，再由 Host target 的「Sign wireguard-go」build phase 用開發簽章重簽（該 target 的 `ENABLE_USER_SCRIPT_SANDBOXING = NO`，否則腳本無法寫入）。缺檔時 build phase 只印警告、不失敗，執行時 `startTunnel` 會回明確錯誤。

## ⚠️ 會中招的點

### UPnP 一律「找不到路由器」：App Transport Security 擋明文 HTTP
路由器的裝置描述檔是 `http://…`，URLSession 預設會擋，失敗被吞成「路由器不支援」。**實際上**路由器有回應。Info.plist 要加 `NSAppTransportSecurity > NSAllowsLocalNetworking`（只放行區網）。判斷「路由器到底支不支援」要先用獨立工具（`python3` 送 SSDP、`curl` 抓描述檔）排除自己程式的問題。

### 驗證 UDP 埠有沒有開：`nc -z` 與 `netstat` 在這裡都無效
`nc -vzu` 對沒開的埠也回「succeeded」；`netstat -an -p udp` 在此環境什麼都列不出。可靠做法：**自己嘗試綁定該埠**（`socket.bind`），被佔用就報「Address already in use」，並**拿一個確定沒開的埠當對照組**。路由器端的對映則用 SOAP `GetSpecificPortMappingEntry` 直接問（回錯誤碼 714 `NoSuchEntryInArray` 代表已取消）。

### 重 build 後，舊的 helper 行程不會自動換掉
helper 是 root 常駐、按需啟動，重新 build 只換了磁碟上的檔案，記憶體裡跑的還是舊版（`version` 回舊號碼）。換新版要 `sudo launchctl kickstart -k system/tw.firstfu.DeskPilotHost.helper`（需要使用者輸入密碼，Claude 無法代勞）。

### App 搬位置後，launchd 記的還是舊路徑
`SMAppService.daemon` 註冊時記下 App 的位置。把 App 從 A 路徑換到 B 路徑（例如從暫存目錄改回 DerivedData）後，helper 仍指向舊路徑，那邊一消失（例如重開機清掉 `/private/tmp`）helper 就起不來。選單的「重新安裝通道元件」會取消註冊再註冊；可能要再核准一次。**build 產物不要放 `/private/tmp`**（另見 `host.md` 的 TCC 條目）。

### `ifconfig` 點對點介面預設 /8
`ifconfig utunN inet 10.66.0.1 10.66.0.2` 若不指定遮罩，介面會是 255.0.0.0。實測路由沒被劫持（只多一條 `10.66.0.2` 主機路由，其他 `10.x` 與預設路由不變），但仍要明設 `netmask 255.255.255.255`。

### 通道介面可能不會登記到系統網路設定
Homebrew 版 `wireguard-go` 的 utun 介面，Network.framework 看不到、`NWListener` 不會在上面收連線，所以才有 `TunnelRelay`（BSD socket 監聽通道位址再轉到本機），細節見 `host.md`。內建版沿用同一套轉接，**沒有另外驗證**內建版的 utun 是否也有這個行為；已知的是 `TunnelRelay` 在 `10.66.0.1:52830` 監聽成功、手機的交握封包能經它到達主機。

### 外網開關的勾選不更新
見 `host.md`「`@Observable` 不追蹤 `UserDefaults`」。

## 現況限制

- 沒設定固定網域時，QR code 內的 Endpoint 是**當下的公網 IP**；IP 變動後手機就連不上，要重新產生 QR（選單會提示「公網位址已變更」）。
- 固定網域（Cloudflare DDNS，2026-10-28 加入）：選單「設定固定網域」填主機名稱與 Token（權限：區域 › DNS › 編輯，範圍只選該網域）。更新成功後 QR 用名稱，IP 變動不必重掃。**僅 build 通過，尚未用真實 Cloudflare 帳號與手機實測**；待驗：手機官方 WireGuard 換 IP 後重開通道是否重新解析名稱。自簽憑證換掉後鑰匙圈可能讀不到舊 Token，需重填。
- CGNAT 或雙層 NAT 下直連不可能，App 只偵測並告知，不提供中繼。
- 通道內防火牆（只放行 DeskPilot 的 TCP 52830、其他連接埠一律擋）**尚未實作**：目前 peer 的 AllowedIPs 已限制手機只能到 Mac 的通道位址，但綁在 `0.0.0.0` 的其他本機服務仍可能從通道位址被連到。
- 端到端（手機行動網路 → 通道 → DeskPilot 連線成功）**尚待實測**。已驗證的是：Mac 端開埠與取消、helper 以 root 執行與冒充連線被拒、通道啟停無殘留、輸入驗證、通道上收到手機封包並到達主機交握。
