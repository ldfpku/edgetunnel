#!/usr/bin/env python3
"""Scan one IP (x.y.z.1) per /24 across Cloudflare's published IPv4 ranges and rank by TCP-connect time to :443.

Usage:  python tools/latency/scan_tcp.py [out.json]
Run with WARP disconnected (or the ranges excluded from WARP), otherwise you measure the WARP tunnel.
Prints a latency histogram and the top candidates (median of 3 re-probes); writes the top 70 IPs to out.json.
"""
import asyncio
import ipaddress
import json
import statistics
import sys
import time

RANGES = ["173.245.48.0/20", "103.21.244.0/22", "103.22.200.0/22", "103.31.4.0/22", "141.101.64.0/18",
          "108.162.192.0/18", "190.93.240.0/20", "188.114.96.0/20", "197.234.240.0/22", "198.41.128.0/17",
          "162.158.0.0/15", "104.16.0.0/13", "104.24.0.0/14", "172.64.0.0/13", "131.0.72.0/22"]
TARGETS = [str(sub.network_address + 1) for r in RANGES for sub in ipaddress.ip_network(r).subnets(new_prefix=24)]
SEM = asyncio.Semaphore(200)


async def probe(ip, timeout=1.5):
    async with SEM:
        t0 = time.perf_counter()
        try:
            _, w = await asyncio.wait_for(asyncio.open_connection(ip, 443), timeout)
            dt = time.perf_counter() - t0
            w.close()
            try:
                await w.wait_closed()
            except Exception:
                pass
            return ip, dt
        except Exception:
            return ip, None


async def main(out):
    t0 = time.time()
    res = await asyncio.gather(*(probe(ip) for ip in TARGETS))
    ok = sorted([(ip, dt) for ip, dt in res if dt is not None], key=lambda x: x[1])
    print(f"scanned={len(TARGETS)} /24s, reachable={len(ok)}, took={time.time() - t0:.0f}s")
    buckets = {}
    for _, dt in ok:
        b = int(dt * 1000) // 25 * 25
        buckets[b] = buckets.get(b, 0) + 1
    print("tcp-connect histogram (ms bucket: count):", dict(sorted(buckets.items())))

    async def multi(ip):
        ds = []
        for _ in range(3):
            _, d = await probe(ip, 2.0)
            if d is not None:
                ds.append(d)
        return ip, (statistics.median(ds) if ds else None), len(ds)

    res2 = await asyncio.gather(*(multi(ip) for ip, _ in ok[:150]))
    res2 = sorted([r for r in res2 if r[1] is not None and r[2] == 3], key=lambda x: x[1])
    print("TOP-40 by median tcp connect over 3 runs (ms):")
    print(", ".join(f"{ip}={m * 1000:.0f}" for ip, m, _ in res2[:40]))
    json.dump([ip for ip, _, _ in res2[:70]], open(out, "w"))
    print(f"wrote top {min(70, len(res2))} IPs to {out}")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "top_ips.json"))
