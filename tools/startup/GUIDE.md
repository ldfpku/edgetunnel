# 一键设置与检验指南

目标三条：**浏览器访问 ip.sb 显示美国**、**到入口的延迟低于 250 ms**、**开机自动执行且不弹窗**。本指南说明一键脚本做了什么、每个功能块为什么需要、怎样用命令自己检验、出了问题怎么处理与还原。脚本不含任何凭据；节点、UUID 仍由 v2rayN 管理。

## 一、一键执行

| 系统 | 双击 | 等价命令 |
| --- | --- | --- |
| Windows | `一键设置.cmd` | `powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1` |
| macOS | `一键设置.command` | `bash setup-proxy.sh` |

把整个 `tools/startup` 目录放在一个**以后不会删的位置**（开机任务会一直从这里运行），然后双击。约 1–2 分钟，全程不需要输入，窗口里会依次显示四步和汇总：

1. **环境检查**：PowerShell / curl、v2rayN 是否在运行、是否装了 Cloudflare One 客户端。
2. **应用设置并检查**：下面第二节的功能块 1–5 逐个执行，结果写日志。
3. **注册开机任务**：Windows 计划任务 `SMJ-EnsureProxy` / macOS LaunchAgent `com.smj.ensure-proxy`。
4. **验证开机任务**：立刻触发一次任务，确认它能在没有窗口的情况下跑完并写出 `RESULT: OK`。

最后一行汇总里看到 `RESULT: OK — 出口美国，入口延迟达标` 即完成。想先看它会改什么、暂不改动：Windows `一键设置.cmd -DryRun`，macOS `bash setup-proxy.sh --dry-run`。

**一键脚本会改动你电脑的这些地方**（都可还原，见第五节）：

- Cloudflare One 客户端切到「代理模式」（持久设置）。
- Windows：系统代理设为 `127.0.0.1:10808`；注册一个当前用户的计划任务。macOS：注册一个 LaunchAgent（不改系统代理）。
- 若 v2rayN 没在运行就启动它；若有两个 v2rayN 实例，关闭不持有端口的那个。

它**不会**改动 v2rayN 的节点配置、不需要管理员权限、不接触 Cloudflare 账号。

Windows 首次运行若提示"已阻止"或执行策略问题，右键脚本文件 → 属性 → 勾选「解除锁定」。macOS 下载解压后若双击打不开，在终端执行 `bash 一键设置.command`；首次注册登录项时通知中心会提示"已添加后台项目"，这是系统固定行为。

## 二、功能块说明

每个功能块按「作用 → 为什么 → 脚本怎么做 → 自己检验 → 还原」展开。检验命令 Windows 在 PowerShell 中执行，macOS 在终端执行。

### 功能块 1：v2rayN 在运行，且只有一个实例

**作用**：代理本体。所有外网流量经它送到美国出口。

**为什么**：v2rayN 没起来，什么都不通。起了两个实例更糟：后起的那个抢不到 10808 端口（日志报 `failed to listen TCP on 10808`），而你看到的那个窗口恰恰是它——在里面换节点、测延迟都不作用于真正在跑的代理。

**脚本怎么做**：有进程或端口已被监听就不再启动；有两个实例时，保留持有端口的那个（监听进程的父进程），关闭另一个；都没有时先等 60 秒让 v2rayN 自己的开机任务先起，再由脚本启动。

**自己检验**：

```powershell
# Windows：应只有一个 v2rayN、一个 xray；端口 10808 在监听
Get-Process v2rayN, xray -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, StartTime
Get-NetTCPConnection -LocalPort 10808 -State Listen | Select-Object LocalAddress, OwningProcess
```

```bash
# macOS
pgrep -fl 'v2rayN|xray'
nc -z 127.0.0.1 10808 && echo "10808 在监听"
```

**还原 / 手动处理**：多余实例关不掉（以管理员身份运行的）时，自己退出那个窗口，只保留托盘里的一个；托盘已有图标时不要再双击 exe。

### 功能块 2：Cloudflare One / WARP 不接管系统流量

**作用**：让节点流量和 DNS 走自己的网卡直连 Cloudflare 入口，而不是绕进 WARP 隧道。

**为什么**：WARP 全隧道模式会接管全部路由和 DNS。从大陆它落点在洛杉矶、自报延迟 260 ms 以上、UDP 隧道常报"连接不稳定"；节点流量一旦进去，入口延迟从 180 ms 变成 280 ms 以上，真连接延迟从 1 秒变 2–3 秒。WARP 本身也不提供美国出口（它保留真实地区）。节点路径已经自足，WARP 对它只有拖累。

**脚本怎么做**：默认 `warp-cli mode proxy`——客户端照常登录、照常显示"已连接"，但不再改路由和 DNS，只在 `127.0.0.1:40000` 留一个可选的 SOCKS5 给需要的程序用。这是持久设置，重启后仍有效。可选策略：`disconnect`（断开）、`keep`（不动，只记录）。由组织 Zero Trust 策略管理的客户端脚本不会改，只在日志提示。

**自己检验**：

```powershell
# Windows：Mode 应为 WarpProxy；到入口的路由应走物理网卡（WLAN / 以太网），不是 CloudflareWARP
warp-cli settings | Select-String Mode
(Find-NetRoute -RemoteIPAddress 104.17.157.1 | Where-Object NextHop | Select-Object -First 1).InterfaceAlias
```

```bash
# macOS：Mode 应为 WarpProxy；路由接口应是 en0 之类，不是 utun
warp-cli settings | grep Mode
route -n get 104.17.157.1 | grep interface
```

**还原**：`warp-cli mode warp`。

### 功能块 3：系统代理指向 v2rayN

**作用**：浏览器和大多数程序按系统代理把请求交给 `127.0.0.1:10808`。这一步决定了"浏览器打开 ip.sb 显示美国"。

**为什么**：代理再好，浏览器不用它也没意义。v2rayN 的「自动配置系统代理」平时会设好，但被别的软件清掉、或 v2rayN 异常退出时会丢。

**脚本怎么做**：Windows 读注册表 `ProxyEnable / ProxyServer`，不对就设成 `127.0.0.1:10808` 并通知系统立即生效。macOS 改系统代理需要管理员授权，脚本只检查并提示，由 v2rayN 的「自动配置系统代理」负责。

**自己检验**：

```powershell
# Windows：ProxyEnable 应为 1，ProxyServer 含 127.0.0.1:10808
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable, ProxyServer
```

```bash
# macOS：Enabled: Yes，Port: 10808
networksetup -getwebproxy Wi-Fi
networksetup -getsocksfirewallproxy Wi-Fi
```

**还原**：在 v2rayN 中选择「清除系统代理」。

### 功能块 4：出口在美国

**作用**：经代理访问时，对方看到的 IP 在美国。

**为什么**：这是用国外 AI 服务的前提。出口由 Worker 的放置区域决定（`aws:us-west-2`，实际在西雅图附近执行），与你选哪个入口 IP 无关。

**脚本怎么做**：经代理访问 `https://api.ip.sb/geoip`，`country_code` 必须是 `US`；失败时改用 Cloudflare 的 `cdn-cgi/trace` 看 `loc=`。

**自己检验**（两个系统相同，macOS 把 `curl.exe` 换成 `curl`）：

```powershell
curl.exe --proxy socks5h://127.0.0.1:10808 -sS -A "Mozilla/5.0" https://api.ip.sb/geoip
curl.exe --proxy socks5h://127.0.0.1:10808 -sS https://www.cloudflare.com/cdn-cgi/trace | Select-String "loc=|colo="
```

浏览器里直接打开 <https://ip.sb/> 看到美国，说明功能块 3 和 4 同时成立。

**不达标时**：v2rayN 当前节点不是美国出口，选回「最低延迟」策略组。

### 功能块 5：入口延迟低于 250 ms

**作用**：对应 v2rayN「延迟」列——到入口 IP 的一次 TCP 往返。

**为什么**：这是用户直观感受到的"快慢"。大陆到美西入口正常 160–240 ms；所有入口一起超过 250 ms，几乎总是被隧道接管（功能块 2），而不是入口本身变慢。

**脚本怎么做**：对每个入口 IP 直连（显式绕过环境代理）、带真实 SNI 发一次 HTTPS 请求，记录 `time_connect`；至少 3 个入口低于 250 ms 才算达标。同时记录一次「真连接延迟」（经代理访问 `generate_204`）作为参考。

**自己检验**（macOS 把 `curl.exe` 换成 `curl`，`NUL` 换成 `/dev/null`）：

```powershell
# 入口延迟：对应「延迟」列，看 connect（秒）
curl.exe --noproxy "*" -o NUL -sS --resolve dfvpn.smjtools.com:443:104.17.157.1 -w 'connect %{time_connect}s  tls %{time_appconnect}s  http %{http_code}\n' https://dfvpn.smjtools.com/

# 真连接延迟：对应「真连接延迟」，正常 0.8–1.2 s
1..5 | ForEach-Object { curl.exe --proxy socks5h://127.0.0.1:10808 -o NUL -sS -w 'HTTP %{http_code}  total %{time_total}s\n' https://www.google.com/generate_204 }

# 下载速度：10 MB 测试文件，speed_download 单位 B/s
curl.exe --proxy socks5h://127.0.0.1:10808 -o NUL -sS --max-time 60 -w 'speed %{speed_download} B/s  total %{time_total}s\n' https://proof.ovh.net/files/10Mb.dat
```

**数值含义**：「真连接延迟」约等于 4 次往返加 Worker 到目标站的时间，受物理距离限制，换任何入口都不会低于约 0.65 s；250 ms 的目标指的是入口延迟。

**不达标时**：先看功能块 2 的路由检验；路由已直连仍慢，说明你的运营商到这批入口就是慢，运行 `tools/latency/Optimize-Colleague.ps1` 在自己网络里挑入口，把结果用参数传给脚本（见第四节）。

### 功能块 6：开机自动执行，不弹窗

**作用**：每次登录后自动把功能块 1–5 跑一遍并修正，不需要人操作。

**为什么**：WARP 设置、系统代理、v2rayN 状态都可能在重启或软件更新后变化；这次就发生过 WARP 排除规则无故消失。

**脚本怎么做**：Windows 注册计划任务 `SMJ-EnsureProxy`：当前用户、普通权限、仅用户登录时运行、登录后 45 秒开始、经 wscript 无窗口启动 PowerShell（新版 Windows 若停用了 VBScript，退回直接启动 PowerShell，登录时会闪一下窗口）。macOS 注册 LaunchAgent `com.smj.ensure-proxy`，登录后运行，本来就没有窗口。两者都可加"每 N 分钟复查"。

**自己检验**：

```powershell
# Windows：任务存在且 Ready；上次运行结果 0；日志最后一行 RESULT
Get-ScheduledTask -TaskName SMJ-EnsureProxy | Select-Object TaskName, State
Get-ScheduledTaskInfo -TaskName SMJ-EnsureProxy | Select-Object LastRunTime, LastTaskResult
Get-Content "$env:LOCALAPPDATA\smj-proxy\ensure-proxy.log" -Tail 5
Start-ScheduledTask -TaskName SMJ-EnsureProxy   # 手动触发一次
```

```bash
# macOS
launchctl print "gui/$(id -u)/com.smj.ensure-proxy" | grep -E 'state|last exit'
tail -n 5 ~/Library/Logs/smj-proxy.log
launchctl kickstart -k "gui/$(id -u)/com.smj.ensure-proxy"   # 手动触发一次
```

**还原**：Windows `一键设置.cmd -Uninstall`，macOS `bash setup-proxy.sh --uninstall`。

## 三、全套设置清单

脚本管不到、需要在软件里确认一次的设置：

| 位置 | 设置 | 说明 |
| --- | --- | --- |
| v2rayN | 导入本组节点，建「最低延迟」策略组并选中 | 策略组自动选最快入口并切换，脚本只检查不选节点 |
| v2rayN | 系统代理：自动配置系统代理 | macOS 上这是唯一设置系统代理的途径 |
| v2rayN | 设置 → 参数设置：启动时隐藏主窗口 | 否则开机会弹出 v2rayN 主窗口 |
| v2rayN | 节点 Mux 关闭；TLS 分片可关闭 | 直连 Cloudflare 不需要分片 |
| v2rayN | 不要重复启动 | 托盘有图标就不要再双击 exe |
| Cloudflare One | 模式：代理模式（脚本已设） | 不要改回"流量和 DNS"全隧道 |
| Windows / macOS | 开机任务 / 登录项（脚本已注册） | 见功能块 6 |

脚本参数（一键脚本会透传给开机任务）：

| 参数（Windows / macOS） | 作用 |
| --- | --- |
| `-WarpPolicy proxy\|disconnect\|keep` / `--warp=...` | WARP 处理策略，默认 proxy |
| `-RepeatMinutes 30` / `--interval 1800` | 登录后再每 30 分钟复查 |
| `-EntryIPs 1.2.3.4,5.6.7.8` / `ENTRY_IPS="1.2.3.4 5.6.7.8"` | 用自己网络测出的入口替换默认列表 |
| `-MaxLatencyMs 250` / `MAX_LATENCY_MS=250` | 达标阈值 |
| `-ProxyPort 10808` / `--port=10808` | v2rayN 本地端口 |
| `-V2rayNPath C:\...\v2rayN.exe` / `V2RAYN_APP=/Applications/v2rayN.app` | v2rayN 不在常见位置时指定 |
| `-DryRun` / `--dry-run` | 只检查不改动 |

## 四、检验命令汇总

一键跑完后，想自己确认一遍，按顺序执行即可（Windows PowerShell）：

```powershell
Get-Process v2rayN, xray -ErrorAction SilentlyContinue | Select-Object Id, ProcessName
warp-cli settings | Select-String Mode
(Find-NetRoute -RemoteIPAddress 104.17.157.1 | Where-Object NextHop | Select-Object -First 1).InterfaceAlias
Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' | Select-Object ProxyEnable, ProxyServer
curl.exe --proxy socks5h://127.0.0.1:10808 -sS -A "Mozilla/5.0" https://api.ip.sb/geoip
curl.exe --noproxy "*" -o NUL -sS --resolve dfvpn.smjtools.com:443:104.17.157.1 -w 'connect %{time_connect}s\n' https://dfvpn.smjtools.com/
Get-ScheduledTaskInfo -TaskName SMJ-EnsureProxy | Select-Object LastRunTime, LastTaskResult
Get-Content "$env:LOCALAPPDATA\smj-proxy\ensure-proxy.log" -Tail 3
```

macOS 终端：

```bash
pgrep -fl 'v2rayN|xray'
warp-cli settings | grep Mode
route -n get 104.17.157.1 | grep interface
networksetup -getwebproxy Wi-Fi
curl --proxy socks5h://127.0.0.1:10808 -sS -A "Mozilla/5.0" https://api.ip.sb/geoip
curl --noproxy '*' -o /dev/null -sS --resolve dfvpn.smjtools.com:443:104.17.157.1 -w 'connect %{time_connect}s\n' https://dfvpn.smjtools.com/
launchctl print "gui/$(id -u)/com.smj.ensure-proxy" | grep -E 'state|last exit'
tail -n 3 ~/Library/Logs/smj-proxy.log
```

预期：一个 v2rayN 一个 xray；`Mode: WarpProxy`；路由走 WLAN / en0；代理开启且端口 10808；`country_code":"US`；`connect` 0.16–0.24 s；任务 `LastTaskResult 0`；日志末行 `RESULT: OK`。

## 五、常见问题与还原

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 所有入口 260 ms 以上，日志说入口经 `CloudflareWARP` / `utun` 路由 | WARP 又回到全隧道 | 重跑一键脚本；或 `warp-cli mode proxy`；组织管理的客户端请管理员在 Split Tunnels 排除入口网段 |
| 入口直连仍超过 250 ms | 本网络到这批入口慢 | `tools/latency/Optimize-Colleague.ps1` 选入口，用 `-EntryIPs` 传入 |
| 出口不是 US | 当前节点不是美国出口 | v2rayN 选回策略组 |
| 端口 10808 未监听 / 两个 v2rayN | 重复启动 | 退出多余实例，只留托盘那个；重跑一键脚本会自动处理普通权限的多余实例 |
| 浏览器 ip.sb 仍是国内，但日志说出口 US | 浏览器没走系统代理 | Windows 重跑一键脚本；macOS 在 v2rayN 开「自动配置系统代理」；浏览器若有自己的代理扩展先关掉 |
| 登录时闪一下黑窗 | 系统没有 VBScript，退回直接启动 PowerShell | 可忽略，不影响功能 |
| 真连接延迟 1 秒左右 | 正常值 | 4 次往返的物理下限，换入口不会更低 |

**完全还原**：

```powershell
# Windows：删任务，WARP 改回全隧道；系统代理在 v2rayN 里选「清除系统代理」
一键设置.cmd -Uninstall -RestoreWarp
```

```bash
# macOS
bash setup-proxy.sh --uninstall --restore-warp
```

日志位置：Windows `%LOCALAPPDATA%\smj-proxy\ensure-proxy.log`；macOS `~/Library/Logs/smj-proxy.log`（LaunchAgent 自身输出在 `smj-proxy.launchd.log`）。日志超过 1 MB 自动轮转为 `.1`。
