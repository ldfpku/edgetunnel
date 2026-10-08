#!/bin/bash
# 登录后静默自检并修正代理环境（macOS）。目标：浏览器出口在美国、入口延迟低于阈值、无弹窗。
# 依次检查并修正：
#   1. v2rayN 在运行（没有就在后台启动；已有实例或端口已被监听时不重复启动）
#   2. Cloudflare One / WARP 不接管系统流量（默认切到代理模式；--warp=disconnect 断开；--warp=keep 不动）
#   3. 系统代理是否指向 127.0.0.1:<端口>（macOS 改系统代理需要管理员授权，脚本只检查不修改，由 v2rayN 自己设置）
#   4. 经代理访问 ip.sb：出口国家必须是 US
#   5. 直连各入口 IP 的 TCP 建连时间：低于阈值的入口数量达标
# 结果写入 ~/Library/Logs/smj-proxy.log。加 --dry-run 只检查不改动。脚本不含任何凭据。
# 可用环境变量覆盖：PROXY_PORT NODE_HOST ENTRY_IPS MAX_LATENCY_MS MIN_FAST WARP_POLICY V2RAYN_APP
# 兼容 macOS 自带的 bash 3.2。

PROXY_PORT="${PROXY_PORT:-10808}"
NODE_HOST="${NODE_HOST:-dfvpn.smjtools.com}"
ENTRY_IPS="${ENTRY_IPS:-104.17.157.1 104.17.152.1 104.17.150.1 104.17.151.1 104.17.143.1 104.17.138.1 104.17.148.1 104.17.149.1 104.17.133.1 104.17.135.1 172.64.79.1 162.159.237.1}"
MAX_LATENCY_MS="${MAX_LATENCY_MS:-250}"
MIN_FAST="${MIN_FAST:-3}"
WARP_POLICY="${WARP_POLICY:-proxy}"
V2RAYN_APP="${V2RAYN_APP:-/Applications/v2rayN.app}"
START_GRACE="${START_GRACE:-30}"
NETWORK_WAIT="${NETWORK_WAIT:-120}"
DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY_RUN=1 ;;
    --warp=*) WARP_POLICY="${a#--warp=}" ;;
    --port=*) PROXY_PORT="${a#--port=}" ;;
  esac
done

LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/smj-proxy.log"
PROBLEMS=""
PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
  mkdir -p "$LOG_DIR"
  if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG" 2>/dev/null || echo 0)" -gt 1048576 ]; then mv -f "$LOG" "$LOG.1"; fi
  echo "$line" >> "$LOG"
  echo "$line"
}
info() { log INFO "$1"; }
problem() { PROBLEMS="${PROBLEMS:+$PROBLEMS；}$1"; log WARN "$1"; }

port_open() { nc -z -G 1 127.0.0.1 "$PROXY_PORT" >/dev/null 2>&1; }

# 直连某入口 IP（显式绕过环境代理），输出 "毫秒 http状态码"；失败无输出
tcp_connect_ms() {
  local out
  out=$(curl --noproxy '*' -sS -o /dev/null --max-time 6 --resolve "$NODE_HOST:443:$1" -w '%{http_code} %{time_connect}' "https://$NODE_HOST/" 2>/dev/null) || return 1
  echo "$out" | awk '{ if ($1 ~ /^[0-9][0-9][0-9]$/) printf "%d %s\n", $2 * 1000, $1 }'
}

wait_network() {
  local waited=0 ip
  while [ "$waited" -lt "$NETWORK_WAIT" ]; do
    for ip in $(echo $ENTRY_IPS | awk '{print $1, $2, $3}'); do
      if [ -n "$(tcp_connect_ms "$ip")" ]; then return 0; fi
    done
    sleep 5; waited=$((waited + 5))
  done
  return 1
}

v2rayn_running() { pgrep -x v2rayN >/dev/null 2>&1 || pgrep -f 'v2rayN\.app/Contents/MacOS' >/dev/null 2>&1; }

ensure_v2rayn() {
  if v2rayn_running; then info "v2rayN 已在运行"; return; fi
  if port_open; then info "端口 $PROXY_PORT 已有服务在监听，不再启动 v2rayN"; return; fi
  local waited=0
  while [ "$waited" -lt "$START_GRACE" ]; do
    sleep 5; waited=$((waited + 5))
    if v2rayn_running; then info "v2rayN 已由其它方式启动"; return; fi
  done
  if [ ! -d "$V2RAYN_APP" ]; then problem "找不到 $V2RAYN_APP，请用环境变量 V2RAYN_APP 指定"; return; fi
  if [ "$DRY_RUN" = 1 ]; then info "[DryRun] 将启动 $V2RAYN_APP"; return; fi
  open -g -a "$V2RAYN_APP" && info "已启动 $V2RAYN_APP"
}

entry_route_iface() { route -n get "${ENTRY_IPS%% *}" 2>/dev/null | awk '/interface:/ {print $2}'; }

ensure_warp() {
  local cli settings status mode managed=0 connected=0 r iface hijack=0
  cli=$(command -v warp-cli 2>/dev/null)
  if [ -z "$cli" ]; then info "未安装 Cloudflare One 客户端，跳过"; return; fi
  settings=$("$cli" settings 2>/dev/null)
  status=$("$cli" status 2>/dev/null)
  mode=$(printf '%s\n' "$settings" | sed -n 's/.*Mode:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -1)
  printf '%s\n' "$status" | grep -q 'Status update: Connected' && connected=1
  if printf '%s\n' "$settings" | grep -q 'Daemon Teams Auth: true' || "$cli" registration show 2>/dev/null | grep -Eq 'Organization|Account type: *Team'; then managed=1; fi
  iface=$(entry_route_iface)
  info "WARP 模式 ${mode:-unknown}，$([ "$connected" = 1 ] && echo 已连接 || echo 未连接)$([ "$managed" = 1 ] && echo '，由组织策略管理')；节点入口当前经 ${iface:-?} 路由"
  if [ "$connected" = 1 ] && ! printf '%s' "$mode" | grep -qi 'proxy\|dns\|doh\|dot'; then hijack=1; fi
  if [ "$hijack" = 0 ]; then info "WARP 未接管系统流量"; return; fi
  if [ "$WARP_POLICY" = keep ]; then problem "WARP 正在接管系统流量（WARP_POLICY=keep，未改动）；节点延迟会增加 100 ms 以上"; return; fi
  if [ "$managed" = 1 ]; then problem "此 WARP 由组织策略管理，脚本不能修改；请管理员在 Zero Trust 的 Split Tunnels 中排除节点入口网段"; return; fi
  if [ "$DRY_RUN" = 1 ]; then info "[DryRun] 将执行 warp-cli $([ "$WARP_POLICY" = proxy ] && echo 'mode proxy' || echo disconnect)"; return; fi
  if [ "$WARP_POLICY" = proxy ]; then r=$("$cli" mode proxy 2>&1); else r=$("$cli" disconnect 2>&1); fi
  info "已执行 warp-cli $WARP_POLICY: $(printf '%s' "$r" | tr '\n' ' ')"
  sleep 5
  iface=$(entry_route_iface)
  case "$iface" in
    utun*) problem "节点入口仍经隧道接口 $iface 路由，请检查 Cloudflare One 客户端的模式" ;;
    *) info "节点入口现经 ${iface:-?} 直连" ;;
  esac
}

check_system_proxy() {
  local hits
  hits=$(networksetup -listallnetworkservices 2>/dev/null | tail -n +2 | sed 's/^\*//' | while IFS= read -r svc; do
    if networksetup -getwebproxy "$svc" 2>/dev/null | grep -q 'Enabled: Yes' && networksetup -getwebproxy "$svc" 2>/dev/null | grep -q "Port: $PROXY_PORT"; then echo "$svc"; continue; fi
    if networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | grep -q 'Enabled: Yes' && networksetup -getsocksfirewallproxy "$svc" 2>/dev/null | grep -q "Port: $PROXY_PORT"; then echo "$svc"; fi
  done)
  if [ -n "$hits" ]; then info "系统代理已指向 127.0.0.1:$PROXY_PORT（$(echo $hits | tr '\n' ' ')）"
  else problem "系统代理未指向 127.0.0.1:$PROXY_PORT：请在 v2rayN 中把系统代理设为「自动配置系统代理」（macOS 改系统代理需管理员授权，脚本不代为修改）"; fi
}

check_egress() {
  local proxy="http://127.0.0.1:$PROXY_PORT" json country desc trace colo
  json=$(curl --proxy "$proxy" -sS --max-time 20 -A 'Mozilla/5.0' https://api.ip.sb/geoip 2>/dev/null)
  country=$(printf '%s' "$json" | sed -n 's/.*"country_code":"\([A-Z][A-Z]\)".*/\1/p')
  if [ -n "$country" ]; then
    desc="$(printf '%s' "$json" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p') $(printf '%s' "$json" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p'), $(printf '%s' "$json" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p') (ip.sb)"
  else
    trace=$(curl --proxy "$proxy" -sS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    country=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p')
    colo=$(printf '%s\n' "$trace" | sed -n 's/^colo=//p')
    desc="colo ${colo:-?} (cloudflare trace)"
  fi
  if [ -z "$country" ]; then problem "经代理无法访问外网：v2rayN 未运行、节点不可用或端口不对"; return 1; fi
  if [ "$country" != US ]; then problem "出口不在美国：$country $desc。请在 v2rayN 中选择美国出口的节点或策略组"; return 1; fi
  info "出口 US：$desc"
}

check_real_delay() {
  local t
  t=$(curl --proxy "http://127.0.0.1:$PROXY_PORT" -sS -o /dev/null --max-time 15 -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null)
  case "$t" in
    204\ *) info "真连接延迟 ${t#204 } s（经代理访问 google generate_204；受往返次数限制，正常 0.8–1.2 s）" ;;
    *) log WARN "真连接延迟测试失败" ;;
  esac
}

check_latency() {
  local ip out ms code n=0 ok=0 fast=0 min=999999 list="" median
  for ip in $ENTRY_IPS; do
    n=$((n + 1)); out=$(tcp_connect_ms "$ip")
    if [ -n "$out" ]; then
      ms=${out%% *}; code=${out##* }; ok=$((ok + 1)); list="$list $ms"
      [ "$ms" -le "$MAX_LATENCY_MS" ] && fast=$((fast + 1))
      [ "$ms" -lt "$min" ] && min=$ms
      info "入口 $ip ${ms} ms (http $code)"
    else
      info "入口 $ip 连接失败"
    fi
  done
  if [ "$ok" = 0 ]; then problem "所有入口都连不上：网络未就绪，或入口被拦截"; return 1; fi
  median=$(echo $list | tr ' ' '\n' | sort -n | awk '{ a[NR] = $1 } END { print a[int((NR + 1) / 2)] }')
  info "入口延迟：最低 $min ms，中位 $median ms，$fast/$n 个低于 $MAX_LATENCY_MS ms"
  if [ "$fast" -lt "$MIN_FAST" ]; then
    problem "低于 $MAX_LATENCY_MS ms 的入口不足 $MIN_FAST 个。若入口流量仍经 WARP，先处理 WARP；否则在本网络重新选入口（见 tools/latency）"
    return 1
  fi
}

info "==== ensure-proxy 开始（用户 $USER，主机 $(hostname -s)$([ "$DRY_RUN" = 1 ] && echo '，DryRun')）===="
wait_network || problem "等待网络 ${NETWORK_WAIT} 秒仍不可用"
ensure_v2rayn
ensure_warp
waited=0; port_up=0
while [ "$waited" -lt 60 ]; do
  if port_open; then port_up=1; break; fi
  sleep 3; waited=$((waited + 3))
done
[ "$port_up" = 1 ] || problem "代理端口 127.0.0.1:$PROXY_PORT 未监听（v2rayN 未启动，或端口被另一个实例占用）"
check_system_proxy
if [ "$port_up" = 1 ]; then check_egress; check_real_delay; fi
check_latency
if [ -z "$PROBLEMS" ]; then info "RESULT: OK — 出口美国，入口延迟达标"; else log WARN "RESULT: FAIL — $PROBLEMS"; fi
exit 0
