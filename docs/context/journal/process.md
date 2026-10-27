# 流水帳（倒序，最新在最上方）

> 放「特定 commit／當下」的變更紀錄（變更 + 為什麼 + 下一步）。永久結論進 reference/，不進這裡。超 300 筆提醒搬 process-archive.md。
>
> **process-archive.md 的讀法**：預設不讀。要回溯時先 Grep 關鍵字（日期、功能名、表名）定位，再用 offset/limit 只讀那一筆，不得整份讀進來。

### 2026-10-28 — 外網加 Cloudflare 固定網域（DDNS）

- **變更**：新增 `CloudflareDDNS.swift`（API 更新 A 記錄、Token 存鑰匙圈）與 `DDNSSettingsView.swift`（選單「設定固定網域」視窗）；`ExternalAccessController` 每輪檢查順便更新 DNS，並提供 `endpointHost`；`PairingView` 的 Endpoint 改用它。
- **為什麼**：QR 內記公網 IP，IP 一變手機就斷，外網對一般用戶不實用。選用戶自備 Cloudflare 網域的做法（A），不自架服務。
- **驗證**：`xcodebuild` DeskPilotHost build 成功；**尚未用真實帳號與手機實測**。
- **下一步**：自己填網域與 Token 實測；確認手機換 IP 後重開通道會重新解析；之後處理 helper 簽章要求（自簽下外網仍被擋）。

### 2026-10-28 — 整理對外發布現況與待辦（`5aacc4d`）

- **變更**：新增 `reference/release.md`（只談 Mac 主機），根 `CLAUDE.md` 索引補一列。
- **為什麼**：使用者問「發新版後用戶下載安裝能否馬上用」，並指出 Liftoff 沒這問題、且 iPhone 端不用管。結論：Mac 端可比照 Liftoff 用自簽憑證＋zip＋cask＋Open Anyway 發布，不需付費帳號；唯一卡點是外網 helper 的簽章要求寫死 Apple Team ID，自簽下會被拒。
- **下一步**：先發區網版（外網預設關）；外網端到端實測後，把 helper 簽章要求改成憑證雜湊並驗證 `SMAppService.daemon` 可註冊。

### 2026-10-28 — 照 Liftoff 的做法重寫 GitHub 門面（`06f0729`）

- **變更**：`README.md` 改寫為英文主版（置中標題＋標語＋徽章＋語言切換列＋「目前沒有下載版」提醒框，依序 Why／Features／Status／Build from source／Remote access／Security model／FAQ 折疊區／Project layout／Contributing／License），新增 `translations/README.zh-Hant.md` 繁中對應版；新增 `CONTRIBUTING.md`（回報 bug／建議功能／送 PR 三條路，指向 `boundaries.md`、`protocol.md`）；新增 `.github/ISSUE_TEMPLATE/`（`bug_report.yml`、`feature_request.yml` 中英雙語，`config.yml` 關閉空白 issue）。授權標示維持 MIT（不是 Liftoff 的 GPLv3）。
- **為什麼**：使用者要求「github 照 liftoff 的做法重新全寫過」，套用 Liftoff repo 既有的 README／CONTRIBUTING／issue 範本結構與語氣，取代舊版較簡短的中文 README。
- **影響檔案**：`README.md`、`translations/README.zh-Hant.md`、`CONTRIBUTING.md`、`.github/ISSUE_TEMPLATE/*.yml`。
- **下一步**：補截圖／操作錄影（hero gif、手勢示意圖）放進 README 對應段落；其餘語言翻譯視需求再補；待外網端到端實測完成後更新「目前狀態」表格。

### 2026-10-27 — 手機專屬操控：觸覺回饋、四指系統手勢、大按鈕（`27df569`）

- **變更**：`RemoteSurfaceView` 加觸覺回饋（左／右鍵、邊緣）與四指滑動（⌃←／→／↑／↓）；`ShortcutBar` 上方加四個大按鈕（Mission Control、Spotlight、切換 App、截圖），原本列中的 ⌘Tab／Spotlight 小按鈕移除避免重複。只用既有 `tapKey` 協定，沒動 `Shared/`。
- **為什麼**：遠端操作沒有實體按鍵的手感，且切換桌面等高頻動作要翻快捷列；手勢對應 macOS 觸控板，不需重新學。
- **事後修正**：實機測發現單指點變右鍵選單，真因是主機送「⌃＋方向鍵」的放開事件也帶 ⌃ 旗標，Mac 修飾鍵狀態卡住；改成放開時旗標清空（`InputInjector.swift`），腳本實測舊寫法卡住、新寫法不卡。曾誤判是雙指點誤觸並改過手機端判定，已還原。
- **驗證**：iOS 模擬器 build 成功；實機修正 ⌃ 卡住後單指點恢復正常。**四指方向、震動手感、與三指捲動／捏合是否互相干擾，使用者尚未逐項回報**。
- **下一步**：實機測四指方向與誤觸門檻（60 pt）；確認截圖 ⌘⇧5 的工具列在遠端操作順手；之後再評估直接觸控模式與放大鏡。

### 2026-10-27 — 通道啟停、QR 配對、區網連線排障與文件歸檔（`4bcd535`、`98e0dc6`、`9ade0b6`、`2cbafb0`）

- **變更**：
  - helper 加 `startTunnel`／`stopTunnel`／`tunnelStatus`／`setPeer`／`removePeer`（`4bcd535`、`98e0dc6`）：root 啟動 `wireguard-go`、自己產 Mac 金鑰、設 utun 位址 10.66.0.1⇄10.66.0.2（/32）、只放一個 peer；`wireguard-go` 驗簽後複製到 `/var/db/deskpilot/bin/` 再驗一次才執行。主機端 `PairingView` 產手機金鑰對與 QR code（手機私鑰不落地）；外網開關連動通道啟停。Host target 加「Sign wireguard-go」build phase。
  - 修選單勾選不更新（`isEnabled` 改 `@Observable` 儲存屬性），加「重新安裝通道元件」（`9ade0b6`）。
  - 手機端手動輸入 IP 被 `authFailed` 後改記「下次走配對」（`2cbafb0`）。
  - 歸檔：新增 `modules/external-access.md`，並更新 `operations.md`（外網段改寫為內建流程）、`host.md`、`protocol.md`、`client.md`、`boundaries.md`、`overview.md`、根 `CLAUDE.md` 索引。
- **為什麼**：把外網連線包進 Mac App（Mac 端全自動，手機一次性掃 QR）。排障起因：實機外網測試手機只顯示「連線中斷」。
- **實測**：通道啟停無殘留（介面、行程、路由都清）、UDP 51820 確認被佔用（對照組可綁定）；`setPeer` 壞輸入全被拒；通道上收到手機封包、主機收到交握。區網連線一開始中斷是主機缺螢幕錄製權限（App 放在 `/private/tmp`，權限不生效）；改回 DerivedData、清授權、重新開啟後預檢 `true`，使用者回報區網可以連上。
- **尚未驗證**：手機行動網路經通道連上 DeskPilot 的端到端；`2cbafb0` 的實際效果；通道內防火牆（只放行 TCP 52830）尚未做；helper 仍註冊在舊路徑，需按「重新安裝通道元件」。
- **下一步**：用行動網路實測外網；做通道內防火牆；公網 IP 變動的處理（自訂主機名稱或重新掃 QR）；`process.md` 驗證狀態確認後更新 `external-access.md` 的「現況限制」。

### 2026-10-27 — 特權 helper 骨架（`80340fb`）與註冊實測

- **變更**：新增 `DeskPilotHelper` target（root LaunchDaemon，`SMAppService.daemon` 註冊，plist 放 `Contents/Library/LaunchDaemons/`，`BundleProgram` 指向 `Contents/MacOS/DeskPilotHelper`）；`Shared/HelperProtocol.swift` 定義 XPC 介面（目前只有 `version`）；主機端 `HelperClient`；`scripts/build-wireguard-go.sh` 從上游原始碼編 `wireguard-go`（釘死 tag 與 commit，兩次編出相同 SHA-256），二進位檔放 `DeskPilotHost/Vendor/` 且不進 repo，會自動進 App 的 `Resources`。
- **為什麼**：外網通道要 root 才能建 utun；採 helper 而非每次 sudo，使用者只需在系統設定核准一次。
- **實測（免費 Apple Development 簽章）**：註冊成功 → 狀態 `requiresApproval` → 使用者核准後 launchd 載入、按需啟動，行程以 **root** 執行；用**未簽章**的程式連 Mach 服務被拒（`Couldn't communicate with a helper application`），簽章要求字串（`identifier` + `anchor apple generic` + `leaf[subject.OU]`）兩端都用 `codesign -R` 驗過。
- **工具坑**：Xcode MCP 對這個專案沒有 scheme、沒有 target template，改用 `xcodeproj` gem 改 pbxproj（專案格式 110 比 gem 支援的新，先確認讀寫一輪只多空陣列與註解差異）。
- **尚未驗證**：主機端透過 XPC 取得 `version` 的選單顯示；helper 開通道、金鑰、QR code；`wireguard-go` 在 `Resources` 內的簽章；免費簽章在 macOS 是否會過期（需放數日觀察）。
- **下一步**：helper 加 `startTunnel`／`stopTunnel`（固定埠與位址、helper 自己產金鑰並用 UAPI 設定）、QR code。

### 2026-10-27 — 自動開埠實測與 ATS 修正（`e4fa9ce`）

- **實測結果**：路由器支援 UPnP-IGD（WANIPConnection:1）、不回應 NAT-PMP。App 開埠成功，另以 SOAP `GetSpecificPortMappingEntry` 查到 UDP 51820 → 本機、租約 3600；路由器 WAN 位址與公網位址一致（無額外 NAT）。
- **踩到的雷**：第一次一律「找不到路由器」。真因是 App Transport Security 預設擋明文 HTTP，路由器的裝置描述檔是 `http://`，URLSession 失敗被吞成 `unsupported`。修法是 Info.plist 加 `NSAppTransportSecurity > NSAllowsLocalNetworking`。獨立用 python／curl 先確認路由器本身有回應，才排除了「路由器不支援」。
- **尚未驗證**：關閉開關後對映是否被取消（unmap）；從外網（手機行動網路）實際打到 UDP 51820。
- **下一步**：特權 helper。

### 2026-10-27 — 外網連線內建化第一步：自動開埠與 CGNAT 偵測（`50c4384`）

- **變更**：新增 `DeskPilotHost/ExternalAccess/`：`PortMapper`（NAT-PMP 優先、退回 UPnP-IGD，登記 UDP 51820）、`Reachability`（比對路由器 WAN 位址與公網位址，判斷私有／CGNAT／雙層 NAT）、`ExternalAccessController`（每 10 分鐘續約並重檢、公網位址變動時提示）。選單列加「外網連線（自動開埠）」開關與狀態。先前的音訊／省流量／剪貼簿／快捷列也一併 commit（`e0062d7`）。
- **為什麼**：使用者要把外網功能包進 Mac App 並全自動。沒有付費開發者帳號，所以做不到 CloudKit 交換 IP／金鑰與 iPhone 內建 Network Extension；範圍定為「Mac 端全自動、手機一次性掃 QR 匯入官方 WireGuard」。
- **驗證**：兩端 build 成功；**自動開埠、CGNAT 判斷尚未實測**（會動到路由器設定，等使用者同意再開）。
- **下一步**：①特權 helper（`SMAppService.daemon`，白名單操作、helper 自己組 wg 設定）管 wireguard-go 啟停；②自動產生金鑰與 QR code；③公網 IP 變動的手機端處理（hostname 或重新匯入）。
- **限制**：免費簽章下 helper 無法用 Team ID 驗證呼叫者，只適合自用 Mac。

### 2026-10-26 — Mac 主機改成選單列 App（權限引導、開機啟動）

- **變更**：`LSUIElement` 無 Dock 圖示，改以 `MenuBarExtra` 常駐，圖示反映正常／連線中／缺權限；主視窗預設不開，缺權限、有配對請求、設 `DESKPILOT_SHOW_WINDOW` 時才自動跳出。權限區改成兩項清單（每秒輪詢、打勾、直達系統設定頁），螢幕錄製授權後提供「立即重新啟動」；選單新增「開機時自動啟動」（`SMAppService`，預設關）。`host-bench.sh start` 帶 `DESKPILOT_SHOW_WINDOW=1`。
- **為什麼**：簡化主機安裝與日常使用，不用每次開視窗、手動找權限設定。
- **影響檔案**：`DeskPilotHost/{DeskPilotHostApp,ContentView,HostController}.swift`、`Info.plist`、`scripts/host-bench.sh`、`reference/modules/host.md`。
- **驗證**：build 成功、主機重開後監聽與通道轉接正常；**配對時視窗自動跳出、缺權限清單、重新啟動、開機啟動都尚未實測**。
- **下一步**：實機測配對流程；之後可做外網「一鍵啟用」，並視是否買付費開發者帳號決定通道要不要內建手機 App。

### 2026-10-26 — 放大時改用雙指平移檢視、三指捲動（`9ede512`）

- **變更**：雙指拖曳在放大時平移手機端檢視（不動 Mac 游標），沒放大時維持捲動；三指拖曳改為一律捲動 Mac。雙指手勢在開始那一刻決定平移或捲動，中途捏合也不換。單指移動手勢開始後前 80 毫秒不送出游標位移，只累積。
- **為什麼**：使用者要改用雙指滑動畫面（原本是三指平移）。實測雙指滑動偶爾變成滑鼠移動：兩根手指不會同時落下，第一根先動時單指移動手勢已啟動，空檔位移被當成游標移動。
- **影響檔案**：`DeskPilot/DeskPilot/RemoteSurfaceView.swift`、`reference/modules/client.md`（手勢表）。
- **驗證**：iOS build 成功並裝到實機；**80 毫秒門檻是否剛好、單指起手是否變遲鈍，尚待使用者實測**。
- **下一步**：依實測調整門檻；v5 放大清晰度的實機測試仍未回報。

### 2026-10-26 — 放大時改傳原生解析度（協定 v5，`6c1692e`）

- **變更**：新增 `setDetail`(0x09，UInt8：0 = 縮到手機像素、1 = 原生解析度)。手機放大超過 1.4 倍要原生、縮回 1.15 倍以下改回手機像素（中間不動，避免在門檻來回切）。主機換解析度時重建編碼器（世代計數丟掉舊編碼器輸出）、`updateConfiguration` 改擷取輸出大小，尺寸不符的擷取畫面直接丟。影像永遠是整個桌面。
- **為什麼**：內建 Retina 縮到手機像素約縮 34%，放大後小字仍糊。先試過「只擷取可見範圍」（`sourceRect`），使用者實測縮小／平移時會出現黑邊、很不流暢，當天改掉：改成整個桌面升原生解析度，平移縮放全在手機本地，只有跨門檻時換一次解析度。
- **取捨**：放大時每張畫面像素變多，同位元率下捲動中會稍糊，停下後由靜止補強補清楚；外接 1080p 螢幕本來就是原生，不受影響。
- **驗證**：兩端 build 成功並部署；**實機清晰度與切換時的頓挫尚未測**。

### 2026-10-26 — 外網連線：自架 WireGuard（`d63d794`）

- **變更**：Mac 以 Homebrew 裝 `wireguard-tools`，設定檔 `/opt/homebrew/etc/wireguard/wg0.conf`（Mac 10.66.0.1、手機 10.66.0.2、UDP 51820；金鑰只在本機，不進 repo）。手機用官方 WireGuard App 掃 QR 匯入，只把連 Mac 的流量走通道。主機改固定監聽 TCP 52830，只接受私有網段來源；手機新增「用 IP 連線」入口，沒有 Bonjour 主機 ID 時有配對紀錄就走驗證。
- **為什麼**：使用者要在外面連回家，不用 Tailscale、免費開發者帳號不能內建 Network Extension。查過家裡網路：WAN 為公網 IPv4（非 CGNAT）、無 IPv6、路由器 UPnP 開啟 → WireGuard 直連可行，外面只看得到一個不回應未授權封包的 UDP 埠。
- **驗證**：兩端 build 成功並部署；**WireGuard 尚未啟動（需 sudo）、路由器尚未開埠、外網連線未測**。
- **後續補強（同日）**：
  - DDNS 改由 Mac 直接打 Cloudflare API 更新自有網域下的一筆 A 紀錄（純 DNS、不代理），LaunchAgent `tw.firstfu.deskpilot.net` 每 10 分鐘執行；手機 Endpoint 改用網域。
  - WireGuard 開機啟動用 LaunchDaemon，設定檔搬到 root 專用的 `/etc/wireguard/`（避免一般使用者改 PostUp 提權）；同一支 sudo 腳本開啟 macOS 防火牆並只放行 wireguard-go 與 DeskPilotHost。
  - 開埠最後用 UPnP 自動（使用者選省事）：LaunchAgent 每 10 分鐘重新登記，Mac 的區網 IP 變了也會跟上。從外部主機測試確認路由器的 UPnP／管理頁沒有暴露到公網；取捨是區網內已被入侵的裝置也能自己開埠（此風險原本就存在）。
  - 手機連線前要 Face ID（失敗可改手機密碼）。
  - 腳本與設定在 `~/Library/Application Support/DeskPilot/`，不進 repo。
- **已知取捨**：root 執行的 wg-quick 仍在 Homebrew 目錄；重建 DeskPilotHost 後防火牆可能要重新放行。
- **除錯過程（同日）**：①Network.framework 看不到 wireguard-go 的 utun → 新增 `TunnelRelay`（BSD socket 轉接到 127.0.0.1）；②轉接器搶先綁埠讓主監聽器 `Address already in use` → 改成主監聽器 ready 後才開；③accept 的 socket 繼承 O_NONBLOCK 導致轉送立刻斷 → 清掉；④重 build 主機被防火牆改成阻擋。另修 Mac 上配對請求在連線斷後不消失。
- **驗證**：2026-10-26 使用者實機配對成功，並從外面（行動網路＋WireGuard）連進來，反映速度快。QR 與手機設定檔已刪除。
- **下一步**：防火牆每次重 build 都可能擋主機，考慮固定簽章或改用 release 安裝位置；在 Mac 上移除連線中的手機應立即斷線；確認路由器韌體是否最新；之後可做省流量模式（行動網路）。

### 2026-10-26 — 配對與加密（協定 v4，`d63d794`）

- **變更**：新增 `Shared/SecureChannel.swift`。每次連線 X25519 臨時金鑰交換 → HKDF 導出雙向金鑰 → ChaChaPoly 加密每則訊息（內層 type 也加密，nonce 為遞增計數器）。首次配對兩端顯示同一組 6 位數，使用者在 Mac 上按允許；之後用存在 Keychain 的 32 bytes PSK 混入金鑰導出。主機 Bonjour TXT 公告主機 ID。新連線通過驗證才取代現有連線；已配對裝置要等第一則訊息成功解密才算通過（手機 ID 是明文，防冒用踢線）。主機視窗可看／移除已配對手機。
- **為什麼**：之後要開放外網連線，原本明文、無驗證，任何連得到的人都能操控 Mac。
- **驗證**：兩端 build 成功；scratchpad 小程式驗過金鑰／確認碼兩端一致、竄改與錯誤 PSK 會被拒；**實機配對流程尚未測**。
- **已知未做**：在 Mac 上移除「目前連線中」的手機不會立即斷線，要等下次連線才擋。
- **下一步**：實機測配對、重連、移除後重配；通過後更新 `reference/modules/protocol.md`（v4、新訊息類型）並歸檔安全設計；再做手動輸入 IP／外網連線。

### 2026-10-26 — 停下後補強位元率、三指平移（`88343fb`）

- **變更**：移動中預設 2 Mbps，靜止補強期間暫時拉到 8 Mbps、補強次數 3→5，下一張真實影格還原；手機端新增三指拖曳平移放大後的檢視（不動 Mac 游標）。
- **為什麼**：固定 6 Mbps 清楚但流量比 RDP 高好幾倍；改成移動省流量、停下補清楚。放大後原本只能靠游標頂邊平移。
- **驗證**：兩端 build 成功；**清晰度與三指手感尚未經使用者實測確認**。
- **下一步**：實測小字清晰度與捲動糊度，不理想就改回固定 6 Mbps；確認色彩（`fad4ddb`）是否正常。

### 2026-10-25 — 預設位元率 1→6 Mbps、色彩標記（`fad4ddb`）

- **變更**：預設位元率改 6 Mbps（`host-bench.sh` 預設同步）；擷取與編碼明確標 sRGB／BT.709。
- **為什麼**：使用者實機反映手機看字不清楚，用 6 Mbps 重開後確認變清楚，原因是位元率；色彩標記是針對「影片怪」的推測修正，**尚未確認有效**。
- **下一步**：6 Mbps 後自動位元率切換（文字／影片）等於無作用，之後決定移除或改成文字 6／影片更高；確認色彩是否正常。

### 2026-10-25 — 多螢幕切換與 Dock 自動隱藏修正（`fad4ddb`）

- **變更**：協定升到 v3，新增 `selectDisplay`(0x07)／`displayInfo`(0x86)。主機 `HostSession` 可在不斷線下換擷取螢幕（停舊擷取 → 重建編碼器 → 重送 `helloAck`），`InputInjector` 依操控中的螢幕換算座標，切換後游標移到該螢幕中央。手機工具列多一顆 `display.2` 按鈕（螢幕數 > 1 才出現），每按一次切到下一台。游標座標上限改為螢幕最後一個像素（`maxX/maxY - 1`）。
- **為什麼**：原本固定擷取 `CGMainDisplayID()`，使用者有 3 台螢幕完全切不到另外兩台；使用者 Dock 設為自動隱藏（`defaults read com.apple.dock autohide` = 1），游標原本會落在螢幕外一格，頂不到邊就叫不出 Dock。
- **驗證**：主機與 iOS 兩個 target build 成功；**尚未實機驗證**（切換螢幕、Dock 是否真能叫出）。
- **下一步**：重開主機（`scripts/host-bench.sh start`）與手機 App 實測；若 Dock 仍叫不出，要查是否需要在底邊停留或 Dock 在別台螢幕；通過後把螢幕切換寫進 `reference/modules/host.md`、`protocol.md`。

### 2026-10-25 — 依畫面內容自動切換位元率（`b589ca9`）

- **變更**：新增 `BitrateController`。ScreenCaptureKit 的 `dirtyRects` 算出變動面積；手機沒有任何輸入、且每秒 ≥ 15 張影格、平均變動面積 ≥ 20%，連續 4 秒 → 升到 6 Mbps（影片模式）；不忙連續 2 秒 → 降回 1 Mbps。`VideoEncoder.setBitrate` 執行中改位元率。stats log 多 `dirty=`、`mode=`。
- **為什麼**：1 Mbps 對捲動文字夠用，但影片／大面積動畫會糊。只看 fps 不行（靜止時轉圈動畫就有約 56 fps），所以要搭配變動面積。
- **模擬器驗證結果（只完成一部分）**：
  - `dirty` 座標空間合理：靜止約 0.01，全畫面變動 0.77～1.00
  - 切換流程正確（升 6000 → 約 2 秒後降回 1000）
  - 原門檻 1.5 秒會被視窗切換這類 2～3 秒的全畫面變動誤觸發 → 改成 4 秒；改完**尚未用新版重測**
  - 子代理送的捲動手勢 `scrolls=0`，沒送到主機，「捲動不會誤切」**未驗證**
  - 測試內容太簡單，升到 6 Mbps 後流量仍只有 500～770 kbps，真影片的流量與清晰度**未量到**
- **影響檔案**：`BitrateController.swift`（新）、`HostController.swift`、`ScreenCapturer.swift`、`VideoEncoder.swift`
- **下一步**：
  1. 用 `scripts/host-bench.sh start` 重開新版主機，實機先捲網頁、再播真影片，讀 log 確認 `mode` 切換
  2. 依真影片流量決定 6 Mbps 是否合適
  3. 確認後再把 reference/modules/host.md 的「已知取捨」改成已實作

### 2026-10-24 — 公開到 GitHub、建立 docs/context 文件體系；手機尺寸虛擬螢幕試做後全數撤回（`940e8ab`）

- **變更**：
  - repo 推上 GitHub 公開：https://github.com/firstfu/deskpilot（`main`）
  - 用 init-context 建 `docs/context/`（reference/ + journal/）與根 `CLAUDE.md` 索引；archive-to-context 歸檔出 `overview.md`、`operations.md`、`modules/{protocol,host,client}.md`；舊 `docs/process.md` 原文搬進本檔後刪除
  - 試做「手機尺寸虛擬螢幕」（CGVirtualDisplay 私有 API）→ 使用者要求整個刪除，程式回到 `f13d22f`，實驗檔一併刪除，淨程式變更為 0
- **為什麼**：程式只存本機有遺失風險；讓下個 session 開場有固定入口；虛擬螢幕 Retina 被系統拒絕、Swift 建立的不上線，價值不足以承擔私有 API 風險（細節見 `reference/overview.md`「已評估並否決的方向」）
- **影響檔案**：`CLAUDE.md`、`docs/context/**`、刪除 `docs/process.md`
- **下一步**：照下方「下一步」清單

<!-- 以下 2026-10-23～24 的紀錄原寫在 docs/process.md，2026-10-24 建立 docs/context/ 時原文搬入，僅改為最新在上 -->

## 下一步

1. iPhone 實機確認 1 Mbps 捲動中文字可讀性與停下後清晰度
2. 依內容自動調位元率（文字捲動低、影片高）；捲動搬移（只補新露出區域）
3. 在乾淨桌面驗證閒置 0 流量
4. 量測：觸控→畫面的端到端延遲（慢動作錄影），與競品同法比較
5. 手感調校（游標靈敏度、捲動倍率）依實機回饋
6. v0.2：底圖＋可視範圍兩層編碼、配對加密（目前區網明文、無驗證，僅限自家網路）
7. 遷移到 iOS 27 新的 `AVSampleBufferVideoRenderer.Receiver` API（舊 enqueue/flush 已 deprecated，仍可用）

### 2026-10-24 — 位元率降到 1 Mbps＋靜止畫質補強（`0800cda`）

- 靜止畫質補強：畫面停 120 ms 後把最後一張重編 3 次（編碼器比對原圖與上一張解碼結果，重複送會補回細節）；擷取 queueDepth 3→4（補強會長期持有一張 buffer）
- 位元率掃描（模擬器、HEVC、1080p、捲動 720 px/s）：
  - 6 Mbps：捲動 3.58 Mbps，延遲中位 23.7 ms
  - 2 Mbps：捲動 1.82 Mbps，延遲中位 21.9 ms
  - 1 Mbps：捲動 **0.96 Mbps**，延遲中位 25.1 ms（與 RDP AVC444 的 0.9～1 Mbps 相當）
- 停下後截圖比對 6 vs 1 Mbps 文字無明顯差異（截圖僅 402pt 寬，細節有限；捲動「進行中」的畫質未驗證）→ 預設改 1 Mbps
- 已知取捨：影片／大面積動畫在 1 Mbps 會較糊，之後依內容自動調整位元率

### 2026-10-23 — 編碼器 A/B 與官方數據對照（`ac01a47`）

- `scripts/host-bench.sh start [hevc|h264]`／`report`：重開主機（排除 Device Hub）並收量測結果；`DESKPILOT_CODEC` 切 codec
- 實際編碼解析度 1920×1080（模擬器螢幕像素再被桌面大小限制）
- 低延遲模式下 `MaxFrameDelayCount`、`PrioritizeEncodingSpeedOverQuality` 都回 -12900（不支援，低延遲模式本來就零延遲出幀）
- 模擬器各跑一次：
  - HEVC：延遲中位 23.0 ms／P90 32.0 ms，編碼 ≈ 9.7 ms，捲動 3.43 Mbps
  - H.264：延遲中位 19.9 ms／P90 28.4 ms，編碼 ≈ 9.3 ms，捲動 4.17 Mbps（+22%）
  - 延遲差在單次量測誤差內，流量 HEVC 明顯省 → 維持 HEVC 預設
- 官方數據對照（1080p）：微軟 RDP 網頁瀏覽 default 6～6.5 Mbps、AVC444 0.9～1 Mbps，idle 0.3 kbps；Parsec 預設位元率上限 10 Mbps；Jump Fluid 上限 20～30 Mbps。**捲動流量我們（3.4 Mbps）比 RDP AVC444 高約 3 倍，是要追的目標**

### 2026-10-23 — 內建量測（模擬器，`4648162`）

- 協定 v2：新增延遲探針（probe）與量測回報（report）；影格帶 probeId。手機按 ⏲ 自動跑「靜止 → 40 個探針 → 8 秒捲動」，結果回寫主機 log
- 主機每秒 log `stats fps/kbps/encodeMs/ax/scrolls`；環境變數 `DESKPILOT_EXCLUDE_BUNDLES` 可排除指定 App 不擷取
- 踩雷：模擬器視窗屬於 Xcode 的 **Device Hub（`com.apple.dt.Devices`）**，不是 Simulator；不排除它會形成「擷取自己的串流」無限迴圈
- 踩雷：游標停在網頁內嵌媒體區時捲動事件被吃掉，畫面不動；移到正文才正常
- 模擬器結果（loopback，RTT 0.7 ms，不含 Wi-Fi、不含手機解碼上屏）：
  - 延遲：中位 21～24 ms、P90 ≈ 47 ms、最佳 12 ms
  - 編碼耗時 ≈ 10 ms／幀，是延遲最大單一來源
  - 捲動（720 px/s）：平均 3.4 Mbps（0.43 MB/s），56 fps
  - 「靜止」≈ 220 kbps、約 50 fps：Mac 上有東西一直在動（推測是終端機 spinner），不是真正靜止，閒置 0 流量尚未在乾淨桌面上驗證

### 2026-10-23 — v0 骨架，實機跑通（`bd2a3dd`）

- 用 Xcode MCP 建立專案 `DeskPilot.xcodeproj`：iOS target `DeskPilot`、macOS target `DeskPilotHost`、共用資料夾 `Shared/`（MCP 沒有設定 target membership 的工具，這一步手動改了 pbxproj 加 synchronized group）
- 模擬器實測：Bonjour 探索、TCP 連線、Hello 交握成功
- 踩雷：主機缺「螢幕與系統錄音」權限時 ScreenCaptureKit 回 `使用者拒絕…擷取的TCC`；加了啟動時 `CGPreflightScreenCaptureAccess`／`CGRequestScreenCaptureAccess`，使用者在系統設定開啟後預檢為 true
- 實機端到端跑通，使用者回饋「速度很快」（尚未正式量測延遲）
