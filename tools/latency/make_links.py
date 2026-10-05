#!/usr/bin/env python3
"""Turn `IP:PORT#REMARK` lines into v2rayN-importable VLESS/WS/TLS share links.

The UUID is read at runtime from V2RAYN-PRIVATE.md (first UUIDv4) unless --uuid is given; it is never stored here.
Usage:  python tools/latency/make_links.py ips.txt [--prefix ZY-] [--path "/?ed=2560"] > links.txt
Output contains live credentials: keep it in a git-ignored file and never share publicly.
"""
import argparse
import re
import sys
import urllib.parse

UUID_RE = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}', re.I)
LINE_RE = re.compile(r'^\s*(\d{1,3}(?:\.\d{1,3}){3}):(\d+)#(\S+)\s*$')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("list", help="file with IP:PORT#REMARK lines, or - for stdin")
    ap.add_argument("--uuid-file", default="V2RAYN-PRIVATE.md")
    ap.add_argument("--uuid")
    ap.add_argument("--host", default="dfvpn.smjtools.com")
    ap.add_argument("--path", default="/?ed=2560", help="WebSocket path; ?ed=2560 enables early data (saves one RTT)")
    ap.add_argument("--prefix", default="", help="only emit lines whose remark starts with this")
    a = ap.parse_args()
    uuid = a.uuid
    if not uuid:
        m = UUID_RE.search(open(a.uuid_file, encoding="utf-8").read())
        if not m:
            sys.exit(f"no UUIDv4 found in {a.uuid_file}")
        uuid = m.group(0)
    src = sys.stdin if a.list == "-" else open(a.list, encoding="utf-8")
    n = 0
    for line in src:
        m = LINE_RE.match(line)
        if not m or not m.group(3).startswith(a.prefix):
            continue
        ip, port, remark = m.groups()
        print(f"vless://{uuid}@{ip}:{port}?security=tls&type=ws&host={a.host}&fp=chrome&sni={a.host}"
              f"&path={urllib.parse.quote(a.path, safe='')}&encryption=none#{remark}")
        n += 1
    print(f"{n} links", file=sys.stderr)


if __name__ == "__main__":
    main()
