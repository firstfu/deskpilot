# 編碼規範 / 不可踩越的邊界 / 踩過的雷

> **何時讀**：每個 session 開場必讀。只放**跨全站**、一句話就能擋坑的東西；只屬某模組或某技術層的雷放 modules/ 或 `<主題>-pitfalls.md`，長機制放 modules/ 或 data-model.md。

## 編碼規範

- 開發 Xcode／Apple 平台專案原則上優先用 Xcode MCP（`mcp__xcode__*`），**但先確認它對這個專案真的可用**：本專案的 MCP 回報沒有 scheme、也沒有 target template（2026-10-27），build 改用 `xcodebuild`、改專案結構用 `xcodeproj` gem 腳本，細節見 `operations.md`。

## 不可踩越的邊界

<待補>

## 踩過的雷

<只放換到任何模組都會踩的雷。格式：現象 → 真相 → 連帶影響 → 指向深度檔。之後用 archive-to-context 累積。>
