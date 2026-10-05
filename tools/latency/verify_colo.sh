#!/bin/bash
# For each IP (args or stdin, one per line): TLS-connect with the real SNI/Host and report
# tcp / tls seconds, HTTP code and the Cloudflare colo that answered. Only code=200 IPs serve this zone.
# Usage: bash tools/latency/verify_colo.sh 104.17.157.1 172.64.79.1   |   cat ips.txt | bash tools/latency/verify_colo.sh
# Run with WARP disconnected (or the IPs excluded from WARP).
HOST="${HOST:-dfvpn.smjtools.com}"
unset HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy
verify() {
  for r in 1 2; do
    out=$(curl -s --noproxy '*' -m 6 -w "%{time_connect} %{time_appconnect} %{http_code}" --resolve "$HOST:443:$1" "https://$HOST/cdn-cgi/trace" 2>/dev/null)
    colo=$(echo "$out" | grep -oE 'colo=[A-Z]+' | head -1)
    printf "%-16s tcp=%.3f tls=%.3f code=%s %s\n" "$1" $(echo "$out" | tail -1) "$colo"
  done
}
export -f verify
export HOST
{ if [ $# -gt 0 ]; then printf '%s\n' "$@"; else cat; fi; } | xargs -P 8 -I{} bash -c 'verify {}' | sort -k1,1V
