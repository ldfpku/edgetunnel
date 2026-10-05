# 入口延迟测量脚本

这些脚本用于从**当前网络**挑选到 Cloudflare 入口延迟最低、最稳定的 IP，并复现 v2rayN 的两种延迟指标。它们不含任何凭据；`xray_realdelay.sh` 与 `make_links.py` 在运行时从被 Git 忽略的 `V2RAYN-PRIVATE.md` 读取 UUID，不会打印或写入仓库。

测量前提：**断开 WARP**（`warp-cli disconnect`，测完 `warp-cli connect`），或先用 `warp-cli tunnel ip add-range` 把待测网段排除出隧道；否则测到的是 WARP 隧道的延迟。脚本已自行忽略 `HTTP_PROXY` 等环境代理。

| 脚本 | 作用 |
| --- | --- |
| `scan_tcp.py` | 对 Cloudflare 公布的全部 IPv4 段每个 /24 探测一个 IP 的 TCP 建连时间（约 30 s），输出直方图与前 70 名 |
| `stab.py` | 对候选 IP 各做 6 次间隔探测，按丢包和中位数排序 |
| `verify_colo.sh` | 用真实 SNI/Host 做 TLS 连接，确认该 IP 为本域名服务（HTTP 200）并给出落点机房 `colo` |
| `xray_realdelay.sh` | 用临时 xray 实例复现 v2rayN「真连接延迟」，并打印实际出口城市 |
| `make_links.py` | 把 `IP:443#备注` 列表生成可导入 v2rayN 的完整分享链接（默认路径 `/?ed=2560`） |
| `Optimize-Colleague.ps1` | 同事端一键脚本：仅依赖 Windows PowerShell 5.1 与 curl.exe；断开 WARP 扫描、验证落点、添加 WARP 排除、按输入的 UUID 生成 `/?ed=2560` 链接到剪贴板 |

典型流程（在仓库根目录执行）：

```bash
python tools/latency/scan_tcp.py top.json
python tools/latency/stab.py "$(python -c 'import json;print(" ".join(json.load(open("top.json"))))')"
bash tools/latency/verify_colo.sh 104.17.157.1 172.64.79.1 162.159.237.1
bash tools/latency/xray_realdelay.sh 104.17.157.1
```

判读要点：TCP 中位数低但 TLS 时间远大于 2×RTT、或真连接波动到秒级的落点（2026-10-05 本线路的 HKG 即如此）不要选；优先选 TLS ≈ 2×RTT、0 丢包的段。`cdn-cgi/trace` 返回 403 的 IP 不为本域名服务。两种指标的含义与预期值见 [COLLEAGUE-NODES.md](../../COLLEAGUE-NODES.md)。
