#!/bin/bash
# Reproduce v2rayN's "真连接延迟": start a throw-away xray with one VLESS/WS/TLS node and time 4 fresh
# HTTPS requests to www.google.com/generate_204 through it, then print the exit location.
# The UUID is read at runtime from the git-ignored V2RAYN-PRIVATE.md and never printed.
# Usage: bash tools/latency/xray_realdelay.sh <entry-ip> [path=/?ed=2560] [local-port=10905]
# Run with WARP disconnected (or the IP excluded from WARP).
set -u
IP="$1"
P="${2:-/?ed=2560}"
PORT="${3:-10905}"
HOST="${HOST:-dfvpn.smjtools.com}"
XRAY="${XRAY:-/c/tools/v2rayN-windows-64/bin/xray/xray.exe}"
PRIV="$(dirname "$0")/../../V2RAYN-PRIVATE.md"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
uuid=$(grep -oE -m1 '[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}' "$PRIV") || { echo "UUID not found in $PRIV"; exit 1; }
cfg=$(mktemp)
log=$(mktemp)
python - "$cfg" "$IP" "$P" "$PORT" "$uuid" "$HOST" <<'PY'
import json, sys
f, ip, path, port, uuid, host = sys.argv[1:]
json.dump({"log": {"loglevel": "error"},
           "inbounds": [{"port": int(port), "listen": "127.0.0.1", "protocol": "socks", "settings": {"udp": False}}],
           "outbounds": [{"protocol": "vless",
                          "settings": {"vnext": [{"address": ip, "port": 443, "users": [{"id": uuid, "encryption": "none"}]}]},
                          "streamSettings": {"network": "ws", "security": "tls",
                                             "tlsSettings": {"serverName": host, "fingerprint": "chrome"},
                                             "wsSettings": {"path": path, "host": host}}}]}, open(f, "w"))
PY
"$XRAY" run -c "$cfg" >"$log" 2>&1 &
xp=$!
sleep 2
printf "%-15s path=%-10s : " "$IP" "$P"
for i in 1 2 3 4; do
  curl -s -m 10 -o /dev/null -w "%{time_total}s/%{http_code} " --proxy "socks5h://127.0.0.1:$PORT" https://www.google.com/generate_204
done
echo -n " | exit: "
curl -s -m 12 --proxy "socks5h://127.0.0.1:$PORT" https://ipinfo.io/json | python -c "import sys,json; d=json.load(sys.stdin); print(d.get('city'), d.get('region'), d.get('country'))" 2>/dev/null || echo "(ipinfo failed)"
kill $xp 2>/dev/null
sleep 0.5
kill -9 $xp 2>/dev/null
wpid=$(netstat -ano -p tcp 2>/dev/null | grep "127.0.0.1:$PORT " | grep LISTEN | awk '{print $NF}' | head -1)
[ -n "$wpid" ] && taskkill //F //PID "$wpid" >/dev/null 2>&1
grep -i -E "error|failed|reject" "$log" | head -3
rm -f "$cfg" "$log"
