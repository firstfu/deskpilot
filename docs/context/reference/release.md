# 對外發布（Mac 主機）

> **何時讀**：要發新版 Mac 主機給別人用、評估「用戶下載後能不能直接用」、或動簽章前。
>
> 範圍主要談 Mac 主機；iPhone 端只記下方「iPhone 端：免費帳號裝不到遠端」這條限制。來源索引：根 `CLAUDE.md` 文件索引表。建置見 `operations.md`，外網機制見 `modules/external-access.md`。

## 結論（2026-10-28）

**不需要付費 Apple Developer 帳號也能發 Mac 主機**，做法比照同作者的 Liftoff 專案（`~/Desktop/liftoff/scripts/package.sh`）：

- 打包成 zip 放 GitHub Releases，另提供 `brew install --cask` 與安裝腳本。
- 用鑰匙圈裡的**自簽憑證**簽章（Liftoff 的 `release` 模式）。系統以「bundle id + 憑證雜湊」辨識 App，更新後輔助使用與螢幕錄製權限會保留；換憑證等於換身分，所有用戶要重新授權，所以私鑰務必保留同一把。
- 不公證：用戶第一次開啟要到「系統設定 › 隱私權與安全性」按一次 **Open Anyway**，README 要明講。
- 區網直連只需主機 App 加上兩項權限，這條路徑沿用上述做法即可。

## 外網功能的卡點

外網目前只有 Cloudflare Tunnel，由開發者在自己的 Mac 上手動設定 cloudflared（見 `operations.md`）。要給用戶用，得把建立 Tunnel、啟動 cloudflared 做進 App（用戶自備 Cloudflare 帳號與網域，填 Tunnel Token），尚未實作。2026-11-23 移除 WireGuard 後，原本「特權 helper 簽章要求綁 Team ID、自簽發布不能用」這個卡點已不存在。

## iPhone 端：免費帳號裝不到遠端

免費開發者帳號沒有 TestFlight，也不能做 ad hoc／下載連結安裝；新版只能由 Mac 用 `devicectl` 推到手機，手機必須跟 Mac 同一個 Wi-Fi 或接線（不可達時回 `error 4016`）。**人在外面時裝不到新版**，只能用手機上已裝的舊版。要遠端分發得升級付費帳號（US$99／年）走 TestFlight。2026-11-20 改完 Tunnel 版手機端時就卡在這裡。

## 用戶仍須手動做的事

- 「隱私權與安全性」開**螢幕與系統錄音**、**輔助使用**（無法腳本授權，開完要重開主機）。
- macOS 防火牆開著時可能要放行連入。
- 首次配對人要在 Mac 旁邊，核對 6 位數並按允許。
- 外網另需：自己的 Cloudflare 帳號與網域、設定 Tunnel；新手機要先在區網配對。

## 待辦（建議順序）

1. 先發**區網版**：自簽憑證 + zip + cask，外網預設關閉，README 註明外網測試中。
2. 補首次使用引導（兩項權限、配對）。
3. 把 Cloudflare Tunnel 設定做進 App，長時間外網使用實測通過後再開放外網。
