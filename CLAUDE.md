# DeskPilot

用 iPhone 操控 Mac 的遠端桌面 App（區網直連，外網經內建的 WireGuard 通道）。詳見 `docs/context/reference/overview.md`。

## Session 開始順序

1. `docs/context/reference/overview.md`（系統架構大圖，**必讀**）
2. `docs/context/reference/boundaries.md`（編碼規範 + 邊界 + 跨全站的雷，**必讀**）
3. `docs/context/journal/process.md` 最近數筆（流水帳）
4. 其餘 reference 檔按需從下方索引讀

## 文件索引（需要時才讀）

| 文件 | 涵蓋 | 何時讀 |
|------|------|--------|
| `reference/overview.md` | 系統架構大圖 | **必讀** |
| `reference/boundaries.md` | 編碼規範、邊界、跨全站的雷 | **必讀** |
| `reference/operations.md` | 建置、裝到實機與看手機 log、執行主機、外網 WireGuard 維運、權限、讀 log、模擬器測試與量測腳本 | 要 build／裝實機／執行／跑量測／用模擬器驗證前，或外網連不上時 |
| `reference/release.md` | 對外發布的現況、簽章／公證／用戶端手動步驟與發布前待辦 | 要發新版給別人用、評估用戶能否直接使用前 |
| `reference/modules/protocol.md` | 線上協定：訊息框、訊息類型、配對與加密、座標編碼、版本規則 | 改 `Shared/`、加訊息類型、動配對／加密、兩端連不上時 |
| `reference/modules/host.md` | Mac 主機：擷取、編碼、多螢幕切換、位元率／codec 決策、輸入注入、通道轉接、權限 | 改 `DeskPilotHost/`、連上就斷、流量或畫面異常、從通道連不進來時 |
| `reference/modules/external-access.md` | 外網連線：自動開埠、特權 helper、WireGuard 通道、手機 QR 配對與其安全模型 | 改 `ExternalAccess/`、`DeskPilotHelper/`，或外網連不上、通道元件裝不起來、QR 配對失敗時 |
| `reference/modules/client.md` | iPhone 端：顯示、手勢、連線前驗證、中文輸入、內建量測 | 改 `DeskPilot/`（iOS）、黑畫面、手感或輸入問題時 |

> 新增任何 reference 檔（data-model / api-spec / modules/xxx …）時，archive-to-context 會在此表補一行。
> 本表每列只寫「涵蓋什麼、何時讀」各一兩句，**不寫雷或結論的摘要**（那些寫在各檔本身）——本檔每個 session 都自動載入，摘要會讓它只增不減。

## 共通規範

- 重要結論用 archive-to-context 歸檔進 `reference/`；只屬單一模組／技術層的雷寫到對應主題檔，跨全站的才進 `boundaries.md`；時間線變更記 `journal/process.md` 最上方（寫「為什麼」與「下一步」）。
