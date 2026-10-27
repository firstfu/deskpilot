# 對外發布（Mac 主機）

> **何時讀**：要發新版 Mac 主機給別人用、評估「用戶下載後能不能直接用」、或動簽章／helper 驗證邏輯前。
>
> 範圍只談 Mac 主機；iPhone 端的發布不在此討論範圍。來源索引：根 `CLAUDE.md` 文件索引表。建置見 `operations.md`，helper 安全模型見 `modules/external-access.md`。

## 結論（2026-10-28）

**不需要付費 Apple Developer 帳號也能發 Mac 主機**，做法比照同作者的 Liftoff 專案（`~/Desktop/liftoff/scripts/package.sh`）：

- 打包成 zip 放 GitHub Releases，另提供 `brew install --cask` 與安裝腳本。
- 用鑰匙圈裡的**自簽憑證**簽章（Liftoff 的 `release` 模式）。系統以「bundle id + 憑證雜湊」辨識 App，更新後輔助使用與螢幕錄製權限會保留；換憑證等於換身分，所有用戶要重新授權，所以私鑰務必保留同一把。
- 不公證：用戶第一次開啟要到「系統設定 › 隱私權與安全性」按一次 **Open Anyway**，README 要明講。
- 區網直連只需主機 App 加上兩項權限，這條路徑沿用上述做法即可。

## 外網功能的卡點（Liftoff 沒有的）

`DeskPilot/Shared/HelperProtocol.swift` 的三條簽章要求（約 22、26、29 行）都是 `anchor apple generic and certificate leaf[subject.OU] = "<Team ID>"`：

- 要求憑證由 Apple 簽發且帶 Team ID。自簽憑證與 ad-hoc 簽章都不符合，XPC 呼叫會被拒，外網功能不能用。
- `SMAppService.daemon` 註冊自簽簽章的 helper 是否成功，**尚未驗證**。
- 要支援自簽發布，須把要求改成比對憑證雜湊（如 `certificate leaf = H"<憑證 SHA1>"`）。代價：保護力較弱，取得同一張憑證的人就能冒充呼叫端，私鑰要保管好。`wireguard-go` 的重簽 build phase 與信任鏈驗證也要一併調整。

## 公網 IP 會變：固定網域

已內建 Cloudflare DDNS（用戶自備網域與 API Token，見 `modules/external-access.md`），尚未實測。沒設定時 QR 記的是當下 IP，IP 一變手機就斷，對外網版不實用，所以外網開放前要先實測通過。

## 用戶仍須手動做的事

- 「隱私權與安全性」開**螢幕與系統錄音**、**輔助使用**（無法腳本授權，開完要重開主機）。
- macOS 防火牆開著時可能要放行連入。
- 首次配對人要在 Mac 旁邊，核對 6 位數並按允許。
- 外網另需：安裝通道元件並到「登入項目」核准、手機裝官方 WireGuard App 掃 QR；公網 IP 變動要重產 QR；CGNAT／雙層 NAT 不可用。

## 待辦（建議順序）

1. 先發**區網版**：自簽憑證 + zip + cask，外網預設關閉，README 註明外網測試中。
2. 補首次使用引導（兩項權限、配對）。
3. 固定網域（Cloudflare）與外網端到端（手機行動網路 → 通道 → DeskPilot 連線成功）實測通過。
4. 改 helper 簽章要求為憑證雜湊版本、驗證 `SMAppService.daemon` 可註冊，再開放外網。
