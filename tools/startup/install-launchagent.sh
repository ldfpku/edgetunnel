#!/bin/bash
# 把 ensure-proxy.sh 注册为 macOS 登录后静默运行的 LaunchAgent（无窗口）。不需要管理员。
# 用法：bash install-launchagent.sh [--interval 1800] [--uninstall]
#   --interval N   之后每 N 秒复查一次（不加则只在登录时运行一次）
set -e
LABEL=com.smj.ensure-proxy
DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$DIR/ensure-proxy.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
INTERVAL=0
UNINSTALL=0
while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift ;;
    --uninstall) UNINSTALL=1 ;;
  esac
  shift
done
UID_NUM=$(id -u)
if [ "$UNINSTALL" = 1 ]; then
  launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "已移除 $LABEL"
  exit 0
fi
[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT"; exit 1; }
chmod +x "$SCRIPT"
xattr -d com.apple.quarantine "$SCRIPT" 2>/dev/null || true
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
{
  cat <<PLIST_HEAD
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SCRIPT</string></array>
  <key>RunAtLoad</key><true/>
PLIST_HEAD
  if [ "$INTERVAL" -gt 0 ]; then echo "  <key>StartInterval</key><integer>$INTERVAL</integer>"; fi
  cat <<PLIST_TAIL
  <key>StandardOutPath</key><string>$HOME/Library/Logs/smj-proxy.launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/smj-proxy.launchd.log</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
</dict></plist>
PLIST_TAIL
} > "$PLIST"
launchctl bootout "gui/$UID_NUM" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
REPEAT=""
if [ "$INTERVAL" -gt 0 ]; then REPEAT="，之后每 $INTERVAL 秒复查"; fi
echo "已注册 $LABEL：登录后自动运行$REPEAT，无窗口。"
echo "立即试运行：launchctl kickstart -k gui/$UID_NUM/$LABEL"
echo "日志：$HOME/Library/Logs/smj-proxy.log"
