#!/usr/bin/env python3
"""Stability check: 6 spaced TCP connects to :443 per IP; reports median, max and loss, sorted by (loss, median).

Usage:  python tools/latency/stab.py "ip1 ip2 ..." [out.json]
Run with WARP disconnected (or the IPs excluded from WARP).
"""
import asyncio
import json
import statistics
import sys
import time

SEM = asyncio.Semaphore(40)


async def probe(ip, timeout=2.0):
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
            return dt
        except Exception:
            return None


async def main(cands, out):
    async def many(ip):
        ds = []
        for _ in range(6):
            ds.append(await probe(ip))
            await asyncio.sleep(0.15)
        ok = [d for d in ds if d is not None]
        return ip, (statistics.median(ok) * 1000 if ok else None), (max(ok) * 1000 if ok else None), 6 - len(ok)

    res = await asyncio.gather(*(many(ip) for ip in cands))
    res = sorted([r for r in res if r[1] is not None], key=lambda r: (r[3], r[1]))
    if out:
        json.dump(res, open(out, "w"))
    for ip, med, mx, loss in res:
        print(f"{ip:<16} med={med:6.0f}ms max={mx:6.0f}ms loss={loss}/6")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1].split(), sys.argv[2] if len(sys.argv) > 2 else None))
