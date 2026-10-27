#!/bin/zsh
# 從上游原始碼編譯 wireguard-go（通用 arm64 + x86_64），輸出到 DeskPilot/DeskPilotHost/Vendor/wireguard-go。
# 釘死版本與 commit，避免供應鏈漂移；二進位檔不進 repo，要用時跑這支腳本。
set -euo pipefail

TAG="0.0.20250522"
COMMIT="f333402bd9cbe0f3eeb02507bd14e23d7d639280"
OUT="$(cd "$(dirname "$0")/.." && pwd)/DeskPilot/DeskPilotHost/Vendor"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone -q https://git.zx2c4.com/wireguard-go "$WORK/src"
cd "$WORK/src"
git checkout -q "$TAG"
[[ "$(git rev-parse HEAD)" == "$COMMIT" ]] || { echo "commit 與釘死值不符，中止" >&2; exit 1; }

for arch in arm64 amd64; do
  CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "$WORK/wg-$arch" .
done
mkdir -p "$OUT"
lipo -create "$WORK/wg-arm64" "$WORK/wg-amd64" -output "$OUT/wireguard-go"
cp LICENSE "$OUT/wireguard-go.LICENSE"
echo "完成：$OUT/wireguard-go"
shasum -a 256 "$OUT/wireguard-go"
