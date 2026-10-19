# 开机自检与一键设置（Windows / macOS）

保证三件事：**浏览器访问 ip.sb 显示美国**、**到入口的延迟低于 250 ms**、**开机自动执行且不弹窗**。脚本不含任何凭据，节点仍由 v2rayN 管理。

## 一键执行

| 系统 | 双击 | 等价命令 |
| --- | --- | --- |
| Windows | `一键设置.cmd` | `powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1` |
| macOS | `一键设置.command` | `bash setup-proxy.sh` |

### 独立单文件版（Windows）

只需单独分发 `一键设置-独立版.ps1`，不依赖本目录中的其他脚本。运行命令：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键设置-独立版.ps1
```

支持 `-DryRun`、`-RepeatMinutes 30`、`-WarpPolicy disconnect`、`-EntryIPs 1.2.3.4,5.6.7.8`、`-V2rayNPath <exe>`、`-SkipTask` 和 `-Uninstall`。计划任务会回调该脚本本身；如果系统拒绝创建计划任务，会尝试写入当前用户登录启动项（不支持定时复查）。设置完成后不要移动或删除脚本。macOS 仍使用上表中的目录版脚本。

把整个目录放在以后不会删的位置再双击。约 1–2 分钟，不需要输入；最后看到 `RESULT: OK — 出口美国，入口延迟达标` 即完成。先看会改什么、不改动：`一键设置.cmd -DryRun` / `bash setup-proxy.sh --dry-run`。

Windows 一键命令按自身所在目录定位脚本，不依赖固定盘符或启动时的工作目录，支持带空格的路径和网络共享目录。v2rayN 优先按指定路径、正在运行的进程、计划任务和常见安装位置查找，再自动检查各盘的 `tools\v2rayN-windows-64\v2rayN.exe`。注册开机任务后若移动脚本目录，请在新位置重新运行一键设置。

每个功能块的作用、怎样用命令自己检验、怎样还原，见 **[GUIDE.md](./GUIDE.md)**。

## 文件

| 文件 | 作用 |
| --- | --- |
| `一键设置-独立版.ps1` | Windows 独立单文件版：自包含设置、检查、计划任务注册与卸载 |
| `一键设置.cmd` / `Setup-Proxy.ps1` | Windows 一键：环境检查 → 应用并检查 → 注册计划任务 → 触发任务验证 → 汇总 |
| `Ensure-Proxy.ps1` | Windows 检查与修正脚本，计划任务每次登录后静默运行的就是它 |
| `Install-StartupTask.ps1` | 注册 / 删除计划任务 `SMJ-EnsureProxy`（无窗口、不需要管理员） |
| `一键设置.command` / `setup-proxy.sh` | macOS 一键：同上四步 |
| `ensure-proxy.sh` | macOS 检查与修正脚本（系统自带 bash 3.2 即可） |
| `install-launchagent.sh` | 注册 / 删除 LaunchAgent `com.smj.ensure-proxy` |
| `GUIDE.md` | 功能块说明、全套设置清单、检验命令、常见问题与还原 |

## 检查脚本每次做什么

1. 等网络就绪（最多 2 分钟）。
2. v2rayN 在运行且只有一个实例：没有就启动；有两个时保留持有 10808 端口的那个，关闭另一个。
3. Cloudflare One / WARP 不接管流量：默认切到代理模式（`warp-cli mode proxy`，持久生效，`warp-cli mode warp` 可改回）。
4. 系统代理指向 `127.0.0.1:10808`（Windows 直接设置；macOS 只检查，由 v2rayN 设置）。
5. 经代理访问 `api.ip.sb/geoip`，出口必须是 `US`。
6. 直连每个入口测 TCP 建连，至少 3 个低于 250 ms；同时记录真连接延迟。

结果写入日志，最后一行是 `RESULT: OK` 或 `RESULT: FAIL — 原因`：Windows `%LOCALAPPDATA%\smj-proxy\ensure-proxy.log`，macOS `~/Library/Logs/smj-proxy.log`。

## 常用参数

Windows 通过 `一键设置.cmd` 或 `Setup-Proxy.ps1` 传入，会一并写进计划任务；macOS 用命令行参数或环境变量：

| Windows | macOS | 作用 |
| --- | --- | --- |
| `-RepeatMinutes 30` | `--interval 1800` | 登录后再定期复查 |
| `-WarpPolicy disconnect` | `--warp=disconnect` | WARP 改为断开（默认 proxy） |
| `-EntryIPs 1.2.3.4,5.6.7.8` | `ENTRY_IPS="1.2.3.4 5.6.7.8"` | 用自己网络测出的入口 |
| `-V2rayNPath <exe>` | `V2RAYN_APP=<app>` | v2rayN 不在常见位置时指定 |
| `-Uninstall [-RestoreWarp]` | `--uninstall [--restore-warp]` | 删除开机任务，可选把 WARP 改回全隧道 |

## 延迟的含义

250 ms 指 v2rayN「延迟」列（到入口的一次 TCP 往返），大陆到美西入口一般 160–240 ms。「真连接延迟」是 4 次往返加 Worker 到目标站的时间，正常 0.8–1.2 s，受物理距离限制，换入口也不会低于约 0.65 s。
