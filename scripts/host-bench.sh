#!/bin/zsh
# host-bench.sh — 量測用：重開 DeskPilot 主機，或讀取最近一次量測回報。
# 用法：
#   scripts/host-bench.sh start [hevc|h264] [bitrate]   以指定 codec／位元率(bps) 重開主機（排除 Device Hub 視窗，避免模擬器迴圈）
#   scripts/host-bench.sh report              等待並印出最新一次量測回報與編碼器資訊
set -e
APP=~/Library/Developer/Xcode/DerivedData/DeskPilot-falljhyhqgfaxvektnwjdczkiuli/Build/Products/Debug/DeskPilotHost.app
PRED='process == "DeskPilotHost"'

case "$1" in
  start)
    pkill -f DeskPilotHost.app || true
    sleep 1
    open --env DESKPILOT_EXCLUDE_BUNDLES=com.apple.dt.Devices --env DESKPILOT_CODEC="${2:-hevc}" --env DESKPILOT_BITRATE="${3:-1000000}" "$APP"
    date +%s > /tmp/deskpilot-bench-start
    echo "主機已以 ${2:-hevc}、${3:-1000000} bps 啟動"
    ;;
  report)
    since=$(cat /tmp/deskpilot-bench-start)
    # 等到啟動後出現第一筆量測回報
    until /usr/bin/log show --start "$(date -r $since '+%Y-%m-%d %H:%M:%S')" --predicate "$PRED AND eventMessage CONTAINS \"量測回報\"" --info 2>/dev/null | grep -q 量測回報; do sleep 2; done
    /usr/bin/log show --start "$(date -r $since '+%Y-%m-%d %H:%M:%S')" --predicate "$PRED AND (eventMessage CONTAINS \"量測回報\" OR eventMessage CONTAINS \"編碼器\")" --style json 2>/dev/null \
      | grep -o '"eventMessage" : "[^"]*' | sed 's/"eventMessage" : "//; s/\\n/\n/g; s/\\\//\//g'
    ;;
esac
