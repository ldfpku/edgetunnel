#!/bin/bash
# 同事一键配置（macOS）：在你自己的网络里挑出到 Cloudflare 入口延迟最低、落点在美国的地址，
# 生成 v2rayN 节点链接，并验证出口在美国。只依赖 macOS 自带的 bash 3.2、perl、curl。
#
# 流程与 Windows 版 Setup-Nodes.ps1 相同：
#   1 环境检查 → 2 WARP 适配（只在「全隧道且已连接」时切代理模式；切不动则测量期间临时断开）
#   → 3 全量 TCP 扫描（每个 /24 一个 IP）→ 4 最快 150 个各 6 次复测 → 5 分批（每批 40 个，最多 120 个）做真实 SNI 的
#   TLS/落点验证（必须 HTTP 200、落点在美国）直到找够 TOP 个 + 入选入口的 WebSocket 握手（必须 101）→ 6 选取中位延迟低于阈值的入口（不足则取最快的并标记 PARTIAL），
#   生成链接到剪贴板与文件
#   → 7 你在 v2rayN 导入并启用后，经 127.0.0.1:10808 验证出口国家为 US 并测真连接延迟。
# 结果写入 ~/Library/Logs/smj-proxy-nodes.log，最后一行是 RESULT: OK / PARTIAL / FAIL。脚本不含任何凭据。
#
# 用法：bash setup-nodes.sh [--prefix B] [--top 12] [--max-ms 200] [--min-nodes 3]
#                           [--warp=proxy|disconnect|keep] [--report-only] [--no-verify] [--no-clipboard]
#                           [--out 文件] [--uuid UUID] [--port 10808] [--host 域名] [--path /?ed=2560]
# UUID 的来源依次：--uuid、环境变量 SMJ_NODE_UUID、脚本同目录的 uuid.txt、交互输入（不回显）。

HOST_NAME="${HOST_NAME:-dfvpn.smjtools.com}"
WS_PATH="${WS_PATH:-/?ed=2560}"
PREFIX="${PREFIX:-CF}"
TOP="${TOP:-12}"
MAX_MS="${MAX_MS:-200}"
MIN_NODES="${MIN_NODES:-3}"
PROXY_PORT="${PROXY_PORT:-10808}"
WARP_POLICY="${WARP_POLICY:-proxy}"
SCAN_TIMEOUT="${SCAN_TIMEOUT:-1.5}"
UUID_IN="${SMJ_NODE_UUID:-}"
REPORT_ONLY=0; NO_VERIFY=0; NO_CLIP=0; OUT_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) PREFIX="$2"; shift ;;
    --top) TOP="$2"; shift ;;
    --max-ms) MAX_MS="$2"; shift ;;
    --min-nodes) MIN_NODES="$2"; shift ;;
    --warp=*) WARP_POLICY="${1#--warp=}" ;;
    --report-only) REPORT_ONLY=1 ;;
    --no-verify) NO_VERIFY=1 ;;
    --no-clipboard) NO_CLIP=1 ;;
    --out) OUT_FILE="$2"; shift ;;
    --uuid) UUID_IN="$2"; shift ;;
    --port) PROXY_PORT="$2"; shift ;;
    --host) HOST_NAME="$2"; shift ;;
    --path) WS_PATH="$2"; shift ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "未知参数：$1（用 --help 查看用法）"; exit 1 ;;
  esac
  shift
done

DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$HOME/Library/Logs"
LOG="$LOG_DIR/smj-proxy-nodes.log"
DATA_DIR="$HOME/Library/Application Support/smj-proxy"
PATH="/usr/local/bin:/opt/homebrew/bin:$PATH"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
START=$(date +%s)
PROBLEMS=""; WARNINGS=""; RESULT_LEVEL=FAIL
WARP_CLI=""; WARP_RECONNECT=0; WARP_NEED_EXCLUDE=0
CHOSEN_IPS=""
# Cloudflare 在美国的机房代码（cdn-cgi/trace 的 colo）；不在表内的落点一律不选
US_COLOS=" ABQ ALB ANC ATL AUS BGR BNA BOS BUF CLE CLT CMH DEN DFW DTW ELP EWR FSD GEG HNL IAD IAH IND JAX LAS LAX LBB MCI MEM MFE MIA MSP OKC OMA ORD ORF PDX PHL PHX PIT RDU RIC RNO SAN SAT SEA SFO SJC SLC SMF STL TLH TPA "

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t smjnodes)
trap 'rm -rf "$TMP"' EXIT

log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$1] $2"
  mkdir -p "$LOG_DIR" 2>/dev/null
  if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null | tr -d ' ')" -gt 1048576 ] 2>/dev/null; then mv -f "$LOG" "$LOG.1"; fi
  echo "$line" >> "$LOG" 2>/dev/null
  echo "$line"
}
info() { log INFO "$1"; }
warn() { WARNINGS="${WARNINGS:+$WARNINGS；}$1"; log WARN "$1"; }
fail() { PROBLEMS="${PROBLEMS:+$PROBLEMS；}$1"; log FAIL "$1"; }
step() { echo; echo "==== [$(printf '%02d:%02d' $(( ($(date +%s) - START) / 60 )) $(( ($(date +%s) - START) % 60 )))] $1 ===="; log INFO "---- $1"; }

# ---------- 内置 Perl：Cloudflare /24 目标列表、并发 TCP 建连扫描与复测 ----------
PL="$TMP/cfscan.pl"
cat > "$PL" <<'PERL'
use strict; use warnings;
use IO::Socket::INET; use Time::HiRes qw(time sleep);
$| = 1;
my ($mode, $forks, $timeout, $probes) = @ARGV;
$forks ||= 64; $timeout ||= 1.5; $probes ||= 6;
if ($mode eq 'targets') {
  my @ranges = qw(173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18
    190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14
    172.64.0.0/13 131.0.72.0/22);
  for my $r (@ranges) {
    my ($ip, $bits) = split m{/}, $r; my @o = split /\./, $ip;
    my $start = ($o[0] << 24) | ($o[1] << 16) | ($o[2] << 8) | $o[3];
    my $n = 2 ** (32 - $bits) / 256;
    for my $i (0 .. $n - 1) { my $v = $start + $i * 256 + 1; printf "%d.%d.%d.%d\n", ($v >> 24) & 255, ($v >> 16) & 255, ($v >> 8) & 255, $v & 255; }
  }
  exit 0;
}
sub probe { my ($ip, $t) = @_; my $t0 = time; my $s = IO::Socket::INET->new(PeerAddr => $ip, PeerPort => 443, Proto => 'tcp', Timeout => $t); return undef unless $s; my $dt = (time - $t0) * 1000; close $s; return $dt; }
my @ips = grep { length } map { chomp; s/\s+//g; $_ } <STDIN>;
exit 0 unless @ips;
my $per = int((@ips + $forks - 1) / $forks);
my @kids;
for my $k (0 .. $forks - 1) {
  my $lo = $k * $per; last if $lo > $#ips;
  my $hi = $lo + $per - 1; $hi = $#ips if $hi > $#ips;
  my $pid = fork(); die "fork: $!" unless defined $pid;
  if ($pid == 0) {
    for my $ip (@ips[$lo .. $hi]) {
      if ($mode eq 'scan') { my $ms = probe($ip, $timeout); print "$ip ", (defined $ms ? sprintf('%.0f', $ms) : '-'), "\n"; }
      else {
        my (@s, $loss); $loss = 0;
        for (1 .. $probes) { my $ms = probe($ip, $timeout); if (defined $ms) { push @s, $ms } else { $loss++ } sleep 0.15; }
        if (@s) { my @o = sort { $a <=> $b } @s; my $med = @o % 2 ? $o[$#o / 2] : ($o[@o / 2 - 1] + $o[@o / 2]) / 2; printf "%s %.0f %.0f %d\n", $ip, $med, $o[-1], $loss; }
        else { print "$ip - - $loss\n"; }
      }
    }
    exit 0;
  }
  push @kids, $pid;
}
waitpid($_, 0) for @kids;
PERL

# ---------- 真实 SNI 的 TLS 连接：输出 "tcp秒 tls秒 http状态 colo" ----------
tls_probe() {
  local out last colo
  out=$(curl -s --noproxy '*' -m 6 --resolve "$HOST_NAME:443:$1" -w "\n%{time_connect} %{time_appconnect} %{http_code}" "https://$HOST_NAME/cdn-cgi/trace" 2>/dev/null)
  last=$(printf '%s\n' "$out" | tail -n 1)
  colo=$(printf '%s\n' "$out" | sed -n 's/^colo=\([A-Z]*\).*/\1/p' | head -n 1)
  echo "${last:-0 0 000} ${colo:--}"
}
# ---------- WebSocket 升级握手：输出 "状态码 cf-mitigated值" ----------
ws_probe() {
  local hdr st mit
  hdr=$(curl --http1.1 --noproxy '*' --max-time 3 -s -o /dev/null -D - --resolve "$HOST_NAME:443:$1" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://$HOST_NAME/" 2>/dev/null)
  st=$(printf '%s\n' "$hdr" | head -n 1 | tr -d '\r' | awk '{print $2}')
  mit=$(printf '%s\n' "$hdr" | tr -d '\r' | awk 'tolower($1)=="cf-mitigated:" {print $2}' | head -n 1)
  echo "${st:-000} ${mit:--}"
}
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------- WARP ----------
find_warp_cli() {
  local c
  c=$(command -v warp-cli 2>/dev/null); [ -n "$c" ] && { echo "$c"; return; }
  for c in "/Applications/Cloudflare WARP.app/Contents/Resources/warp-cli" "/Applications/Cloudflare One.app/Contents/Resources/warp-cli"; do
    [ -x "$c" ] && { echo "$c"; return; }
  done
}
warp_mode() { "$WARP_CLI" settings 2>/dev/null | sed -n 's/.*Mode:[[:space:]]*\([^[:space:]]*\).*/\1/p' | head -n 1; }
warp_connected() { "$WARP_CLI" status 2>/dev/null | grep -q 'Status update: Connected'; }
warp_managed() { "$WARP_CLI" settings 2>/dev/null | grep -q 'Daemon Teams Auth: true' || "$WARP_CLI" registration show 2>/dev/null | grep -Eq 'Organization|Account type: *Team'; }
route_iface() { route -n get "$1" 2>/dev/null | awk '/interface:/ {print $2}'; }

step_warp() {
  WARP_CLI=$(find_warp_cli)
  if [ -z "$WARP_CLI" ]; then info "未安装 Cloudflare One / WARP 客户端：无需处理"; return; fi
  local mode connected=0 managed=0 iface hijack=0 r
  mode=$(warp_mode); warp_connected && connected=1; warp_managed && managed=1
  iface=$(route_iface 104.16.0.1)
  info "WARP 模式 ${mode:-unknown}，$([ "$connected" = 1 ] && echo 已连接 || echo 未连接)$([ "$managed" = 1 ] && echo '，由组织策略管理')；到 Cloudflare 入口的路由接口：${iface:-?}"
  if [ "$connected" = 1 ] && ! printf '%s' "$mode" | grep -qi 'proxy\|dns\|doh\|dot'; then hijack=1; fi
  case "$iface" in utun*) hijack=1 ;; esac
  if [ "$hijack" = 0 ]; then info "WARP 没有接管直连流量（未连接或代理/DNS 模式），测量与节点都不受影响"; return; fi
  if [ "$WARP_POLICY" = keep ]; then fail "WARP 正在以全隧道模式接管流量（--warp=keep 未改动）：测出来的是 WARP 隧道延迟。请改用 warp-cli mode proxy 或断开后重跑"; return; fi
  if [ "$managed" = 0 ] && [ "$WARP_POLICY" = proxy ]; then
    r=$("$WARP_CLI" mode proxy 2>&1 | tr '\n' ' '); info "执行 warp-cli mode proxy：$r"
    sleep 4; iface=$(route_iface 104.16.0.1)
    case "$iface" in
      utun*) warn "切换代理模式后路由仍经 $iface，改为测量期间临时断开" ;;
      *) info "WARP 已切到代理模式（持久生效，warp-cli mode warp 可改回）；直连现经 ${iface:-?}"; return ;;
    esac
  fi
  r=$("$WARP_CLI" disconnect 2>&1 | tr '\n' ' '); info "执行 warp-cli disconnect：$r"
  local i=0; while [ $i -lt 15 ]; do sleep 1; warp_connected || break; i=$((i + 1)); done
  if warp_connected; then fail "WARP 无法断开（受组织策略锁定）：请管理员在 Zero Trust 的 Split Tunnels 中排除 Cloudflare 入口网段，或使用 v2rayN 时手动关闭 WARP 后重跑"; return; fi
  WARP_RECONNECT=1; WARP_NEED_EXCLUDE=1
  info "WARP 已临时断开，脚本结束时会重连，并把选中入口的 /24 加入 WARP 排除列表"
}

restore_warp() {
  [ -n "$WARP_CLI" ] && [ "$WARP_RECONNECT" = 1 ] || return
  local ip cidr r ok=1
  if [ "$WARP_NEED_EXCLUDE" = 1 ] && [ -n "$CHOSEN_IPS" ]; then
    for cidr in $(for ip in $CHOSEN_IPS; do echo "${ip%.*}.0/24"; done | sort -u); do
      r=$("$WARP_CLI" tunnel ip add-range "$cidr" 2>&1 | tr '\n' ' ')
      if printf '%s' "$r" | grep -q Success; then info "WARP 排除 $cidr：已添加"; else ok=0; log WARN "WARP 排除 $cidr 失败：$r"; fi
    done
    [ "$ok" = 1 ] || warn "WARP 排除列表添加失败（通常是组织策略）：使用 v2rayN 期间请断开 WARP，或请管理员在 Split Tunnels 中排除上述网段"
  fi
  "$WARP_CLI" connect >/dev/null 2>&1
  local i=0; while [ $i -lt 20 ]; do sleep 1; warp_connected && break; i=$((i + 1)); done
  info "WARP 已重连：$("$WARP_CLI" status 2>/dev/null | head -n 1)"
}

# ---------- 导入后：经 v2rayN 本地代理检查出口国家与真连接延迟 ----------
verify_via_proxy() {
  local proxy="http://127.0.0.1:$PROXY_PORT" json country desc trace colo t times="" i
  if ! port_open "$PROXY_PORT"; then fail "127.0.0.1:$PROXY_PORT 没有在监听：v2rayN 未运行，或本地端口不是 $PROXY_PORT（可用 --port 指定）"; return 1; fi
  json=$(curl --proxy "$proxy" -sS --max-time 20 -A 'Mozilla/5.0' https://api.ip.sb/geoip 2>/dev/null)
  country=$(printf '%s' "$json" | sed -n 's/.*"country_code":"\([A-Z][A-Z]\)".*/\1/p')
  if [ -n "$country" ]; then
    desc="$(printf '%s' "$json" | sed -n 's/.*"ip":"\([^"]*\)".*/\1/p') $(printf '%s' "$json" | sed -n 's/.*"city":"\([^"]*\)".*/\1/p'), $(printf '%s' "$json" | sed -n 's/.*"country":"\([^"]*\)".*/\1/p') (ip.sb)"
  else
    trace=$(curl --proxy "$proxy" -sS --max-time 20 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
    country=$(printf '%s\n' "$trace" | sed -n 's/^loc=//p'); colo=$(printf '%s\n' "$trace" | sed -n 's/^colo=//p')
    desc="colo ${colo:-?} (cloudflare trace)"
  fi
  if [ -z "$country" ]; then fail "经 v2rayN 代理无法访问外网：节点未启用、不可用，或系统代理端口不对"; return 1; fi
  if [ "$country" != US ]; then fail "出口不在美国：$country $desc。请在 v2rayN 里启用刚导入的节点（备注 $PREFIX-…）"; return 1; fi
  info "出口 US：$desc"
  i=0
  while [ $i -lt 3 ]; do
    t=$(curl --proxy "$proxy" -sS -o /dev/null --max-time 15 -w '%{http_code} %{time_total}' https://www.google.com/generate_204 2>/dev/null)
    case "$t" in 204\ *) times="$times ${t#204 }" ;; esac
    i=$((i + 1))
  done
  if [ -n "$times" ]; then info "真连接延迟（经 v2rayN，3 次）：$(echo $times | tr ' ' '/') s；受线路往返限制，正常 0.8–1.2 s"; else warn "真连接延迟测试失败（google generate_204 经代理不可达）"; fi
}

# ================= 主流程 =================
info "==== setup-nodes 开始（用户 ${USER:-$(id -un 2>/dev/null)}，主机 $(hostname -s 2>/dev/null || hostname 2>/dev/null)，bash $BASH_VERSION）===="
main() {
  step "1/6 环境检查"
  command -v curl >/dev/null 2>&1 || { fail "缺少 curl"; return 1; }
  command -v perl >/dev/null 2>&1 || { fail "缺少 perl（macOS 自带；若被删除请安装 Xcode 命令行工具）"; return 1; }
  perl -MIO::Socket::INET -MTime::HiRes -e 1 2>/dev/null || { fail "perl 缺少 IO::Socket::INET / Time::HiRes 模块"; return 1; }
  info "curl $(curl --version 2>/dev/null | head -n 1 | awk '{print $2}')，perl $(perl -e 'print $^V')"
  if pgrep -x v2rayN >/dev/null 2>&1 || pgrep -f 'v2rayN\.app/Contents/MacOS' >/dev/null 2>&1; then info "v2rayN 正在运行"; else warn "v2rayN 未运行：脚本仍会生成链接，导入后验证前请先启动 v2rayN"; fi

  step "2/6 Cloudflare One / WARP 适配"
  step_warp
  [ -z "$PROBLEMS" ] || return 1

  step "3/6 扫描 Cloudflare 入口（每个 /24 一个 IP，TCP 443，约 1 分钟）"
  perl "$PL" targets > "$TMP/targets.txt"
  local total; total=$(wc -l < "$TMP/targets.txt" | tr -d ' ')
  info "目标 $total 个 /24 段，超时 ${SCAN_TIMEOUT} s，128 路并发"
  perl "$PL" scan 128 "$SCAN_TIMEOUT" < "$TMP/targets.txt" | cat > "$TMP/scan.txt"
  awk '$2 != "-"' "$TMP/scan.txt" | sort -n -k2 > "$TMP/reach.txt"
  local reach; reach=$(wc -l < "$TMP/reach.txt" | tr -d ' ')
  [ "$reach" -gt 0 ] || { fail "没有任何入口可达：请检查网络，或 443 端口是否被 WARP / 防火墙拦截"; return 1; }
  info "可达 $reach 段；TCP 建连分布 → $(awk '{b=int($2/25)*25; c[b]++} END {for (k in c) printf "%sms:%d ", k, c[k]}' "$TMP/reach.txt" | tr ' ' '\n' | sort -n | tr '\n' ' ')"

  step "4/6 稳定性复测（最快 150 个，各 6 次）"
  head -n 150 "$TMP/reach.txt" | awk '{print $1}' > "$TMP/top150.txt"
  perl "$PL" stab 32 2.0 6 < "$TMP/top150.txt" | cat > "$TMP/stab.txt"
  # 保留 0 丢包且最大值不超过中位数×1.5+30（无重传）的入口，按中位数排序
  awk '$2 != "-" && $4 == 0 && $3 <= $2 * 1.5 + 30' "$TMP/stab.txt" | sort -n -k2 > "$TMP/stable.txt"
  local nstable; nstable=$(wc -l < "$TMP/stable.txt" | tr -d ' ')
  [ "$nstable" -gt 0 ] || { fail "复测后没有稳定（0 丢包、无重传）的入口：当前线路丢包严重，请稍后再试"; return 1; }
  info "0 丢包且无重传的入口 $nstable 个；最低 TCP 中位数 $(head -n 1 "$TMP/stable.txt" | awk '{print $2}') ms"

  step "5/6 落点 / TLS / WebSocket 验证"
  # 分批验证：每批 40 个，直到找够 TOP 个美国落点入口或验证满 120 个（香港等亚洲落点常常占满最快的前几十个）
  : > "$TMP/verified.txt"
  local ip med max a b tcp1 tls1 code1 colo1 tcp2 tls2 code2 colo2 ok200 tls colo reason offset=0 ngood=0 nc
  while [ "$offset" -lt 120 ] && [ "$ngood" -lt "$TOP" ]; do
    tail -n +$((offset + 1)) "$TMP/stable.txt" | head -n 40 > "$TMP/cands.txt"
    nc=$(wc -l < "$TMP/cands.txt" | tr -d ' ')
    [ "$nc" -gt 0 ] || break
    info "对第 $((offset + 1))–$((offset + nc)) 个入口各做 2 次真实 SNI 的 TLS 连接…"
    while read -r ip med max _; do
      a=$(tls_probe "$ip"); b=$(tls_probe "$ip")
      set -- $a; tcp1=$1; tls1=$2; code1=$3; colo1=$4
      set -- $b; tcp2=$1; tls2=$2; code2=$3; colo2=$4
      ok200=0; [ "$code1" = 200 ] && ok200=$((ok200 + 1)); [ "$code2" = 200 ] && ok200=$((ok200 + 1))
      tls=$(printf '%s
%s
' "$tls1" "$tls2" | sort -n | tail -n 1)
      colo=$colo1; [ "$colo" = - ] && colo=$colo2
      reason=""
      if [ "$ok200" = 0 ]; then reason="HTTP $code1/$code2，不为本域名服务或连不上"
      elif ! printf '%s' "$US_COLOS" | grep -q " $colo "; then reason="落点 $colo 不在美国"
      elif awk -v t="$tls" -v m="$med" 'BEGIN { exit !(t > 2.6 * m / 1000 + 0.08) }'; then reason="TLS 耗时远超 2×RTT，落点不稳定"
      fi
      printf '%s %s %s %s %s %s/%s %s
' "$ip" "$colo" "$med" "$max" "$tls" "$code1" "$code2" "${reason:--}" >> "$TMP/verified.txt"
    done < "$TMP/cands.txt"
    ngood=$(awk '$7 == "-"' "$TMP/verified.txt" | wc -l | tr -d ' ')
    offset=$((offset + 40))
  done
  echo
  echo "验证结果（按 TCP 中位数排序；最后一列为 - 的是可用入口）："
  printf '%-16s %-5s %6s %6s %8s %-8s %s\n' IP 落点 中位ms 最大ms TLS秒 HTTP 剔除原因
  sort -n -k3 "$TMP/verified.txt" | while read -r ip colo med max tls code reason; do
    printf '%-16s %-5s %6s %6s %8s %-8s %s\n' "$ip" "$colo" "$med" "$max" "$tls" "$code" "$reason"
    log INFO "  $ip $colo tcp $med/$max ms tls $tls s http $code $reason"
  done
  awk '$7 == "-"' "$TMP/verified.txt" | sort -n -k3 > "$TMP/good.txt"
  local ngood; ngood=$(wc -l < "$TMP/good.txt" | tr -d ' ')
  info "通过验证 $ngood 个；落点分布 $(awk '{c[$2]++} END {for (k in c) printf "%s×%d ", k, c[k]}' "$TMP/verified.txt")"
  [ "$ngood" -gt 0 ] || { fail "没有落点在美国且稳定的入口通过验证。看上表剔除原因：若全是非美国落点，这条线路当前只能到亚洲机房；稍后或换网络再试"; return 1; }
  local nfast
  nfast=$(awk -v m="$MAX_MS" '$3 < m' "$TMP/good.txt" | wc -l | tr -d ' ')
  if [ "$nfast" -ge "$MIN_NODES" ]; then awk -v m="$MAX_MS" '$3 < m' "$TMP/good.txt" > "$TMP/pool.txt"; RESULT_LEVEL=OK
  else cp "$TMP/good.txt" "$TMP/pool.txt"; RESULT_LEVEL=PARTIAL; warn "低于 $MAX_MS ms 的入口只有 $nfast 个（目标至少 $MIN_NODES 个），改为生成最快的美国落点入口（最低 $(head -n 1 "$TMP/good.txt" | awk '{print $3}') ms）。这是你当前线路到美国机房的延迟，换入口无法更低；白天拥塞时常见，晚间通常 160–190 ms，建议晚间重跑一次"; fi

  info "对候选入口做 WebSocket 握手（需 101 且无安全质询）…"
  : > "$TMP/chosen.txt"
  local n=0 st mit
  while read -r ip colo med max tls code reason; do
    [ "$n" -ge "$TOP" ] && break
    set -- $(ws_probe "$ip"); st=$1; mit=$2
    if [ "$st" = 101 ] && [ "$mit" = - ]; then
      n=$((n + 1)); printf '%s %s %s %s %s %s-%s-%02d\n' "$ip" "$colo" "$med" "$max" "$tls" "$PREFIX" "$colo" "$n" >> "$TMP/chosen.txt"; info "  $ip $colo 握手 101"
    elif [ "$mit" != - ]; then log WARN "  $ip 被安全质询（cf-mitigated=$mit）：域的 Under Attack 豁免规则可能缺失，请告知管理员"
    else log WARN "  $ip 握手返回 $st，剔除"; fi
  done < <(head -n $((TOP + 6)) "$TMP/pool.txt")
  [ "$n" -gt 0 ] || { fail "WebSocket 握手全部失败：入口能连但 Worker 不可达，可能是域的安全设置（Under Attack）或 Worker 故障，请联系管理员"; return 1; }
  if [ "$n" -lt "$MIN_NODES" ] && [ "$RESULT_LEVEL" = OK ]; then RESULT_LEVEL=PARTIAL; warn "握手通过的入口只有 $n 个"; fi
  CHOSEN_IPS=$(awk '{print $1}' "$TMP/chosen.txt" | tr '\n' ' ')
  echo
  echo "选中 $n 个入口："
  printf '%-12s %-16s %-5s %6s %6s %8s\n' 备注 IP 落点 中位ms 最大ms TLS秒
  awk '{printf "%-12s %-16s %-5s %6s %6s %8s\n", $6, $1, $2, $3, $4, $5}' "$TMP/chosen.txt"
  info "选中 $n 个入口：$(awk '{printf "%s=%sms ", $1, $3}' "$TMP/chosen.txt")"

  if [ "$REPORT_ONLY" = 1 ]; then step "6/6 ReportOnly：不生成链接"; return 0; fi

  step "6/6 生成节点链接"
  local uuid="$UUID_IN"
  if [ -z "$uuid" ] && [ -f "$DIR/uuid.txt" ]; then uuid=$(tr -d '[:space:]' < "$DIR/uuid.txt"); info "UUID 来自 $DIR/uuid.txt"; fi
  if [ -z "$uuid" ]; then read -r -s -p '请输入节点 UUID（不回显；由管理员提供，不是 ADMIN 密码）: ' uuid; echo; fi
  uuid=$(printf '%s' "$uuid" | tr -d '[:space:]' | tr 'A-F' 'a-f')
  if ! printf '%s' "$uuid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then fail "UUID 格式不正确，需要 UUIDv4（形如 xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx）。它不是 ADMIN 密码，也不是 Cloudflare API Token"; return 1; fi
  local epath; epath=$(printf '%s' "$WS_PATH" | perl -pe 's/([^A-Za-z0-9\-_.~])/sprintf("%%%02X", ord($1))/ge')
  local out="$OUT_FILE"
  if [ -z "$out" ]; then mkdir -p "$DATA_DIR" 2>/dev/null; out="$DATA_DIR/nodes.txt"; fi
  awk -v u="$uuid" -v h="$HOST_NAME" -v p="$epath" '{printf "vless://%s@%s:443?security=tls&type=ws&host=%s&fp=chrome&sni=%s&path=%s&encryption=none#%s\n", u, $1, h, h, p, $6}' "$TMP/chosen.txt" > "$out"
  chmod 600 "$out" 2>/dev/null
  info "链接已写入 $out（含凭据，勿公开）"
  if [ "$NO_CLIP" = 1 ]; then cat "$out"
  elif command -v pbcopy >/dev/null 2>&1; then pbcopy < "$out"; echo "已把 $n 条节点链接复制到剪贴板。"
  else warn "没有 pbcopy，链接只写入了文件：$out"; fi
  echo
  echo "现在到 v2rayN："
  echo "  1. 主窗口按 Cmd+V 导入，没反应就用菜单「配置项 → 从剪贴板导入分享链接」（备注形如 $PREFIX-$(head -n 1 "$TMP/chosen.txt" | awk '{print $2}')-01）；可先删除旧的高延迟节点。"
  echo "  2. 全选新节点 → 右键「测试服务器延迟」，双击最快的启用。"
  echo "  3. 节点 Mux 保持关闭；设置 → 参数设置：关闭「TLS 分片」。"
  if [ "$NO_VERIFY" = 0 ]; then
    local ans; read -r -p '导入并启用后按回车开始验证（输入 S 跳过）: ' ans
    case "$ans" in
      [sS]*) warn "已跳过导入后验证，出口国家未经 v2rayN 实际确认" ;;
      *) step "导入后验证（经 127.0.0.1:$PROXY_PORT）"; verify_via_proxy ;;
    esac
  fi
  return 0
}

main
restore_warp
echo
[ -n "$PROBLEMS" ] && RESULT_LEVEL=FAIL
case "$RESULT_LEVEL" in
  OK) info "RESULT: OK — $(awk -v m="$MAX_MS" '$3 < m' "$TMP/chosen.txt" | wc -l | tr -d ' ') 个入口低于 $MAX_MS ms（最低 $(head -n 1 "$TMP/chosen.txt" | awk '{print $3}') ms）${WARNINGS:+；提醒：$WARNINGS}" ;;
  PARTIAL) log WARN "RESULT: PARTIAL — 已生成最快的 $(wc -l < "$TMP/chosen.txt" | tr -d ' ') 个入口（最低 $(head -n 1 "$TMP/chosen.txt" | awk '{print $3}') ms），但未达到 $MAX_MS ms 的目标：$WARNINGS" ;;
  *) log FAIL "RESULT: FAIL — $PROBLEMS" ;;
esac
echo "日志：$LOG"
exit 0
