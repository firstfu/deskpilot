#!/bin/bash
# 產生 App 圖示（iOS 與 Mac 主機共用同一個圖案）並寫進兩個 asset catalog。
# 需要 rsvg-convert（brew install librsvg）。改圖案只要改下面的 ART，再重跑。
#
# 設計參考（只借鏡構圖與氛圍，沒有取用素材）：
#   - Dribbble「macos app icon display」搜尋結果中深色圓角底＋單一發光圖形的作法
#   - Edovia Screens 官網的圖示：素底上放一塊漸層色的螢幕色塊
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_SET="$ROOT/DeskPilot/DeskPilot/Assets.xcassets/AppIcon.appiconset"
MAC_SET="$ROOT/DeskPilot/DeskPilotHost/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

DEFS='
  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#1D2747"/>
    <stop offset="1" stop-color="#090C18"/>
  </linearGradient>
  <radialGradient id="glow" cx="512" cy="470" r="520" gradientUnits="userSpaceOnUse">
    <stop offset="0" stop-color="#3B82F6" stop-opacity="0.55"/>
    <stop offset="1" stop-color="#3B82F6" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="screen" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#67D4FF"/>
    <stop offset="0.5" stop-color="#3B82F6"/>
    <stop offset="1" stop-color="#7C5CFA"/>
  </linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.38"/>
    <stop offset="0.55" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
  <filter id="drop" x="-40%" y="-40%" width="180%" height="180%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="16"/>
    <feOffset dy="14"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.45"/></feComponentTransfer>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
'

# 1024×1024 座標：螢幕色塊＋底座＋游標。
ART='
  <rect width="1024" height="1024" fill="url(#bg)"/>
  <rect width="1024" height="1024" fill="url(#glow)"/>
  <rect x="192" y="252" width="640" height="420" rx="64" fill="url(#screen)"/>
  <rect x="192" y="252" width="640" height="420" rx="64" fill="url(#sheen)"/>
  <rect x="194" y="254" width="636" height="416" rx="62" fill="none" stroke="#FFFFFF" stroke-opacity="0.35" stroke-width="4"/>
  <rect x="392" y="724" width="240" height="30" rx="15" fill="#FFFFFF" fill-opacity="0.32"/>
  <g transform="translate(536 420) scale(1.28)" filter="url(#drop)">
    <path d="M0 0 L0 230 L60 172 L102 266 L146 247 L104 154 L186 154 Z"
          fill="#FFFFFF" stroke="#FFFFFF" stroke-width="18" stroke-linejoin="round"/>
  </g>
'

# iOS：滿版方形，圓角由系統裁。
cat > "$TMP/ios.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>$DEFS</defs>
$ART
</svg>
EOF

# macOS：1024 畫布內 824 的圓角方形，四周留白並帶陰影。
cat > "$TMP/mac.svg" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>$DEFS
  <clipPath id="plate"><rect x="100" y="100" width="824" height="824" rx="185"/></clipPath>
  <filter id="plateShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/>
    <feOffset dy="10"/>
    <feComponentTransfer><feFuncA type="linear" slope="0.35"/></feComponentTransfer>
  </filter>
</defs>
<rect x="100" y="100" width="824" height="824" rx="185" filter="url(#plateShadow)"/>
<g clip-path="url(#plate)">
  <g transform="translate(100 100) scale(0.8046875)">
$ART
  </g>
</g>
</svg>
EOF

rm -f "$IOS_SET"/*.png "$MAC_SET"/*.png
rsvg-convert -w 1024 -h 1024 "$TMP/ios.svg" -o "$TMP/ios-alpha.png"
# App Store 圖示不能有透明色版。
sips -s format jpeg "$TMP/ios-alpha.png" --out "$TMP/ios.jpg" >/dev/null
sips -s format png "$TMP/ios.jpg" --out "$IOS_SET/icon-1024.png" >/dev/null

for px in 16 32 64 128 256 512 1024; do
  rsvg-convert -w "$px" -h "$px" "$TMP/mac.svg" -o "$MAC_SET/icon-$px.png"
done

cat > "$IOS_SET/Contents.json" <<'EOF'
{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

cat > "$MAC_SET/Contents.json" <<'EOF'
{
  "images" : [
    { "filename" : "icon-16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon-32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon-64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon-128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon-256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon-512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon-1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

echo "圖示已寫入：${IOS_SET} 與 ${MAC_SET}"
