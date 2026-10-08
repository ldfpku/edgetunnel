# 开机自检脚本（Windows / macOS）

登录后静默运行，保证三件事：**浏览器访问 ip.sb 显示美国**、**到入口的延迟低于 250 ms**、**开机自动执行且不弹窗**。脚本不含任何凭据，节点仍由 v2rayN 管理。

| 文件 | 作用 |
| --- | --- |
| `Ensure-Proxy.ps1` | Windows 自检与修正脚本（PowerShell 5.1 即可，不需要管理员） |
| `Install-StartupTask.ps1` | 注册 / 删除 Windows 计划任务：登录后 45 秒无窗口运行上面的脚本 |
| `ensure-proxy.sh` | macOS 自检与修正脚本（系统自带 bash 3.2 即可） |
| `install-launchagent.sh` | 注册 / 删除 macOS LaunchAgent：登录后静默运行上面的脚本 |

## 脚本每次做什么

1. **等网络就绪**（最多 2 分钟），避免开机早期误判。
2. **v2rayN 在运行**：没有就启动。已有进程、或 10808 端口已被监听时不再启动，先等 60 秒给 v2rayN 自己的开机任务让路，避免两个实例互相抢端口（第二个实例会报 `failed to listen TCP on 10808`，而且它的界面不控制真正在跑的代理）。
3. **Cloudflare One / WARP 不接管流量**：WARP 全隧道会把节点流量和 DNS 绕到洛杉矶（+100 ms 以上，且经常报"连接不稳定"）。默认把客户端切到**代理模式**（`warp-cli mode proxy`）：客户端保持登录和连接，但不再改路由和 DNS，只在 `127.0.0.1:40000` 留一个可选的 SOCKS5。这是持久设置，重启后仍有效；想改回：`warp-cli mode warp`。由组织策略管理的 WARP 脚本不会动，只在日志里提示。
4. **系统代理指向 `127.0.0.1:10808`**（Windows 会直接设置并立即生效；macOS 改系统代理需要管理员授权，脚本只检查，由 v2rayN 的「自动配置系统代理」负责）。
5. **出口国家**：经代理访问 `api.ip.sb/geoip`，必须是 `US`（备用 Cloudflare trace）。
6. **入口延迟**：直连每个入口 IP 的 TCP 建连时间，至少 3 个低于 250 ms 才算达标；同时记录一次「真连接延迟」。

结果写入日志，最后一行是 `RESULT: OK` 或 `RESULT: FAIL — 原因`：

- Windows：`%LOCALAPPDATA%\smj-proxy\ensure-proxy.log`
- macOS：`~/Library/Logs/smj-proxy.log`

## Windows 安装

把 `Ensure-Proxy.ps1` 和 `Install-StartupTask.ps1` 放在同一个固定目录（不要放在以后会删的下载目录），在 PowerShell 中：

```powershell
powershell -ExecutionPolicy Bypass -File .\Install-StartupTask.ps1
```

- 任务名 `SMJ-EnsureProxy`，当前用户、普通权限、登录后 45 秒运行，通过 wscript 无窗口启动，不闪黑窗。
- 立即试一次：`Start-ScheduledTask -TaskName SMJ-EnsureProxy`，然后看日志。
- 想让它每 30 分钟复查一次：加 `-RepeatMinutes 30`。
- 先看看会改什么、不实际改动：`powershell -ExecutionPolicy Bypass -File .\Ensure-Proxy.ps1 -DryRun`。
- 删除：`-Uninstall`。

常用参数（通过 `-ScriptArgs` 传给任务，例如 `-ScriptArgs "-WarpPolicy disconnect"`）：`-ProxyPort`、`-EntryIPs`、`-MaxLatencyMs`、`-WarpPolicy proxy|disconnect|keep`、`-V2rayNPath`、`-NoSystemProxy`。

## macOS 安装

```bash
bash install-launchagent.sh
```

- LaunchAgent `com.smj.ensure-proxy`，登录后自动运行，无窗口。首次注册时系统会在通知中心提示"已添加后台项目"，这是 macOS 的固定行为。
- 立即试一次：`launchctl kickstart -k gui/$(id -u)/com.smj.ensure-proxy`。
- 每 30 分钟复查：`bash install-launchagent.sh --interval 1800`。删除：`--uninstall`。
- 只检查不改动：`bash ensure-proxy.sh --dry-run`。参数用环境变量：`PROXY_PORT`、`ENTRY_IPS`、`MAX_LATENCY_MS`、`WARP_POLICY`、`V2RAYN_APP`。

## 使用前提

- v2rayN 已导入本组节点，选中「最低延迟」策略组，系统代理设为「自动配置系统代理」。
- 不希望开机弹出 v2rayN 主窗口：在 v2rayN 设置 → 参数设置 中勾选「启动时隐藏主窗口」；脚本只负责不弹自己的窗口。
- 节点 Mux 关闭；直连 Cloudflare 不需要 TLS 分片，可关闭。

## 延迟的含义

250 ms 指 v2rayN「延迟」列（到入口的一次 TCP 往返），大陆到美西入口一般 160–220 ms。「真连接延迟」是 4 次往返加 Worker 到目标站的时间，正常 0.8–1.2 s，受物理距离限制，换入口也不会低于约 0.65 s。

## 日志里常见的 FAIL

| 原因 | 处理 |
| --- | --- |
| 低于 250 ms 的入口不足 3 个，且日志显示入口经 `CloudflareWARP` / `utun` 路由 | WARP 仍在接管。检查客户端模式是否被改回，或 WARP 由组织管理（找管理员在 Split Tunnels 排除入口网段） |
| 低于 250 ms 的入口不足 3 个，入口经物理网卡直连 | 本网络到这批入口就是慢。运行 `tools/latency/Optimize-Colleague.ps1` 在自己网络里重新选入口，把结果用 `-EntryIPs` 传给脚本 |
| 出口不在美国 | v2rayN 当前节点不是美国出口，选回策略组 |
| 代理端口未监听 | v2rayN 没起来，或两个实例抢端口：退出多余的实例，只保留一个 |
