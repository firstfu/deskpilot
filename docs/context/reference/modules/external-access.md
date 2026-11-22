# 外網連線模組（Cloudflare Tunnel）

> **何時讀**：改外網路徑（手機端 WebSocket 傳輸、主機端「經 Tunnel 不准配對」）、或遇到「從外面連不上」時。
>
> 來源索引：根 `CLAUDE.md` 文件索引表。本檔是外網機制的單一事實源；協定細節見 `protocol.md`，主機本體見 `host.md`，Mac 端 cloudflared 設定與維運見 `../operations.md`「Cloudflare Tunnel」。

## 架構（2026-11-20 起；2026-11-23 起是唯一外網路徑）

```
手機 DeskPilot（wss://<網域>，WebSocket 二進位訊息）⇄ Cloudflare 邊緣 ⇄ Mac 的 cloudflared（主動外連）
  → ingress `tcp://127.0.0.1:52830` 把 WebSocket 還原成 TCP 位元組流 → 主機本體（協定、配對加密都不變）
```

- **為什麼用 Tunnel**：Mac 主動外連，路由器不用開埠、不怕公網 IP 變動、手機不用另裝 App。之前的 WireGuard 路徑（見下方「已移除」）就是栽在這三點。
- **為什麼要包 WebSocket**：iPhone 跑不了 `cloudflared`，Cloudflare 邊緣只收 HTTPS／WebSocket。cloudflared 的 `tcp://` 入口本來就是「用戶端 WebSocket ⇄ 源站 TCP」，所以**只有手機端加 WebSocket 傳輸，主機的傳輸層不用改**。
- 手機端：`FramedConnection.webSocketParameters()`（TLS＋`NWProtocolWebSocket`），每個訊息框送成一則二進位訊息；收的那端把資料當位元組流重新切框（`receiveStream`／`drainBuffer`），**不能假設一則 WebSocket 訊息＝一個訊息框**，cloudflared 轉 TCP 時不保留邊界。「在外面」輸入框：網域走 `wss://`，純 IP 走 TCP 52830（區網 Bonjour 找不到時手動用）。
- Mac 端設定（不在 repo、也不在 App 內）：見 `../operations.md`「Cloudflare Tunnel」。

## 安全模型

- **主機協定直接暴露在公網**：經 Tunnel 的連線在主機看來來自 `127.0.0.1`，任何人知道網域（DNS、憑證公開紀錄都查得到）就能發起交握。保護全靠協定本身：驗證模式要第一則加密訊息解得開才算通過（交握細節見 `protocol.md`）。內層是端到端加密，Cloudflare 雖然解開 TLS，看到的仍是密文；它看得到連線時間與流量。
- **經 Tunnel 不准首次配對**（2026-11-23 起，`HostController.allowsPairing`）：來源是回送位址（`127.0.0.1`／`::1`）的連線只能走驗證模式。不擋的話陌生人能讓 Mac 跳出配對視窗，誤按一次允許就拿到整台 Mac 的控制權；而且原本「只接受私有網段」的檢查對 Tunnel 無效（`127.0.0.1` 算私有）。被擋時主機回加密的 `pairResult`=2、等 1 秒再斷線（立刻斷的話回覆可能送不到），手機顯示「外網不能做首次配對」。**新手機要先在區網配對**。已驗（Python 用戶端）：經 `wss://` 網域與直連 `127.0.0.1` 都收到 2、沒跳視窗；區網 IP 照常等待允許。
- 手機遺失：Mac 主視窗可移除已配對裝置（`removePairedDevice`），連線中的會立刻斷開。
- **還沒做**：Cloudflare Access Service Token（手機帶標頭，沒帶的在邊緣就擋掉，連交握都送不進來）、交握頻率限制。

## ⚠️ 會中招的點

### 手機開著其他 VPN 時走 Tunnel 會連不上
2026-11-23 實測：手機 5G、WireGuard 通道開著，輸入網域連線，主機完全沒收到連線；關掉後就連上、畫面正常串流。VPN 開著時手機流量（含 DNS）會先導進 VPN，VPN 沒通就整個卡住。

### 剛建好的 Tunnel 網域，本機一時解析不到
建 DNS 記錄前查過一次（NXDOMAIN）的話，Mac 的系統 DNS 快取會記住「不存在」，`getaddrinfo` 回 `nodename nor servname provided`，但 `dig @1.1.1.1` 已有記錄。等快取過期或 `sudo dscacheutil -flushcache` 即可，不是 Tunnel 壞了。

### 主機回 `authFailed` 後立刻斷線，回覆可能送不到用戶端
2026-11-20 經 Tunnel 測 resume 交握：主機 log 有「回 authFailed」，但用戶端只收到連線關閉、沒收到 0x88。研判是主機送完就 `cancel()` 連線，資料還沒送出就被丟掉；區網理論上也會發生。影響是手機收不到 `authFailed` 就不會設 `forcePairNext`。**未修**（`pairResult`=2 那條已改成延遲 1 秒斷線，可照做）。

### zsh 的 `log` 要用 `/usr/bin/log`
查主機 log 時，zsh 的內建 `log` 會蓋掉系統指令，報 `too many arguments`。用 `/usr/bin/log show --last 10m --info --debug --predicate 'subsystem == "tw.firstfu.DeskPilotHost"' --style compact`。

## 現況限制

- 尚未驗證：長時間串流的延遲、流量與穩定度；Cloudflare 對經 Tunnel 長時間串流影像的用量限制。
- Tunnel 由開發者在 Mac 上手動設定；要給其他用戶用，得把建立 Tunnel 與啟動 cloudflared 做進 App（填 Tunnel Token），尚未實作。

## 已移除：WireGuard 通道（2026-11-23）

2026-10 到 2026-11 曾內建 WireGuard 路徑：Mac 自動向路由器開 UDP 51820（NAT-PMP／UPnP）、特權 helper（root LaunchDaemon）啟停 `wireguard-go`、選單產生 QR 給手機官方 WireGuard App、`TunnelRelay` 把 utun 上的連線轉到本機、Cloudflare DDNS。**為什麼拿掉**：UPnP 對映會掉、QR 記公網 IP 一變就失效、helper 註冊會無故消失、手機要另開 App 且開著會擋住 Tunnel，反覆造成「從外面連不進來」；Tunnel 上線並實測成功後就不再需要，留著只是多一個 root 常駐程式和路由器上的開放埠。程式碼與雷的紀錄在 git 歷史（移除前最後版本見 `journal/process.md` 2026-11-23 那筆）。
