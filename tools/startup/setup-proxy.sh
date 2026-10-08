#!/bin/bash
# 一键设置（macOS）：应用代理环境 → 注册登录后自动运行的 LaunchAgent → 立即验证 → 汇总。
# 通常由 一键设置.command 双击启动；也可在终端运行：
#   bash setup-proxy.sh [--dry-run] [--warp=proxy|disconnect|keep] [--port=10808] [--interval 1800] [--skip-agent]
#   bash setup-proxy.sh --uninstall [--restore-warp]
# 各功能块的含义、手动检验命令和还原方法见 GUIDE.md。兼容 macOS 自带的 bash 3.2。

DIR="$(cd "$(dirname "$0")" && pwd)"
ENSURE="$DIR/ensure-proxy.sh"
INSTALL="$DIR/install-launchagent.sh"
GUIDE="$DIR/GUIDE.md"
LABEL=com.smj.ensure-proxy
LOG="$HOME/Library/Logs/smj-proxy.log"
PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

DRY=0; INTERVAL=0; SKIP=0; UNINSTALL=0; RESTORE=0; WARP_POLICY=proxy
ENSURE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; ENSURE_ARGS+=(--dry-run) ;;
    --warp=*) WARP_POLICY="${1#--warp=}"; ENSURE_ARGS+=("$1") ;;
    --port=*) ENSURE_ARGS+=("$1") ;;
    --interval) INTERVAL="$2"; shift ;;
    --skip-agent) SKIP=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --restore-warp) RESTORE=1 ;;
  esac
  shift
done

step() { echo; echo "==== $1 ===="; }
ok() { echo "  [OK] $1"; }
bad() { echo "  [!!] $1"; }

if [ "$UNINSTALL" = 1 ]; then
  step "卸载"
  bash "$INSTALL" --uninstall
  if [ "$RESTORE" = 1 ] && command -v warp-cli >/dev/null 2>&1; then
    warp-cli mode warp >/dev/null 2>&1 && ok "Cloudflare One 客户端已改回全隧道模式（warp-cli mode warp）"
  fi
  echo "  系统代理与 v2rayN 未改动；要关闭系统代理，在 v2rayN 中选择「清除系统代理」。"
  exit 0
fi

for f in "$ENSURE" "$INSTALL"; do
  [ -f "$f" ] || { bad "缺少 $f，请把整个 tools/startup 目录放在一起"; exit 1; }
done

step "1/4 环境检查"
if [ "$DRY" = 1 ]; then echo "  用户 $USER；DryRun：只检查不改动"; else echo "  用户 $USER；正式运行"; fi
command -v curl >/dev/null 2>&1 && ok "curl 可用" || bad "缺少 curl"
command -v nc >/dev/null 2>&1 && ok "nc 可用" || bad "缺少 nc，端口检查会失败"
if pgrep -x v2rayN >/dev/null 2>&1 || pgrep -f 'v2rayN\.app/Contents/MacOS' >/dev/null 2>&1; then ok "v2rayN 正在运行"; else echo "  v2rayN 未运行，稍后由脚本启动"; fi
if command -v warp-cli >/dev/null 2>&1; then ok "Cloudflare One 客户端已安装，处理策略：$WARP_POLICY"; else echo "  未安装 Cloudflare One 客户端，跳过 WARP 处理"; fi

step "2/4 应用设置并检查（ensure-proxy.sh）"
bash "$ENSURE" "${ENSURE_ARGS[@]}"

step "3/4 注册登录后自动运行（install-launchagent.sh）"
if [ "$SKIP" = 1 ]; then echo "  已跳过（--skip-agent）"
elif [ "$DRY" = 1 ]; then echo "  DryRun，未注册。正式运行时会注册 LaunchAgent $LABEL"
else
  if [ "$INTERVAL" -gt 0 ]; then bash "$INSTALL" --interval "$INTERVAL"; else bash "$INSTALL"; fi
fi

step "4/4 验证登录项能静默运行"
if [ "$SKIP" = 1 ] || [ "$DRY" = 1 ]; then echo "  已跳过"
else
  before=0; [ -f "$LOG" ] && before=$(wc -l < "$LOG" | tr -d ' ')
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null
  echo "  已触发，等待它写出结果（通常 30–60 秒）..."
  result=""; waited=0
  while [ "$waited" -lt 240 ]; do
    sleep 5; waited=$((waited + 5))
    [ -f "$LOG" ] || continue
    result=$(tail -n +"$((before + 1))" "$LOG" | grep 'RESULT:' | tail -n 1)
    [ -n "$result" ] && break
  done
  case "$result" in
    *"RESULT: OK"*) ok "登录项已静默跑完一次：${result#*] }" ;;
    "") bad "240 秒内没有写出结果：查看 $LOG 和 ~/Library/Logs/smj-proxy.launchd.log" ;;
    *) bad "跑完但未达标：${result#*] }" ;;
  esac
fi

step "汇总（取自最近一次检查的日志）"
if [ -f "$LOG" ]; then
  awk '/ensure-proxy 开始/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$LOG" \
    | grep -E 'v2rayN|WARP|warp-cli|Cloudflare|系统代理|出口|真连接延迟|入口延迟：|RESULT' \
    | sed -E 's/^[^ ]+ [^ ]+ //; s/^/  /'
fi
echo
echo "日志：$LOG"
echo "各功能块说明与手动检验命令：$GUIDE"
