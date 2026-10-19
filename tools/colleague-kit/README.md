# 同事一键配置（Windows / macOS）

脚本在**你自己的网络**里选出延迟最低、落点在美国的 Cloudflare 入口，生成 v2rayN 节点链接，并验证出口在美国。全程约 3–5 分钟，不需要输入任何东西（节点 UUID 已随包内的 `uuid.txt` 一起发给你）。脚本不改 v2rayN 配置和系统代理。

目标：**到入口延迟低于 200 ms、出口 IP 在美国、Cloudflare One (WARP) 开着关着都不影响。**

## 1. 生成节点

准备：v2rayN 7.x 已安装并启动；电脑直接连公司或家里的网络，不挂其他 VPN。包里的 `uuid.txt` 是节点凭据，脚本会自动读取；不要外传，也不要删（删了脚本会改为提示你输入 UUID）。

**Windows**

1. 解压到不会删的位置（如 `D:\smj-proxy`）。若提示「已阻止」：右键 `Setup-Nodes.ps1` → 属性 → 勾选「解除锁定」。
2. 双击 `setup-nodes.cmd`，等待扫描完成（约 3–5 分钟）。
3. 看到「已把 N 条节点链接复制到剪贴板」后，转到第 3 节导入；导入并启用后回到脚本窗口按回车，脚本会做验证。

**macOS**（Windows 打的 zip 会丢掉执行权限，第一次必须在终端运行）

```bash
cd ~/smj-proxy
xattr -dr com.apple.quarantine .
chmod +x setup-nodes.command setup-nodes.sh
bash setup-nodes.command
```

之后可直接双击 `setup-nodes.command`。其余步骤与 Windows 相同。

**结果行**

| `RESULT:` | 含义 | 做什么 |
| --- | --- | --- |
| `OK` | 至少 3 个入口低于 200 ms，出口美国 | 直接用 |
| `PARTIAL` | 低于 200 ms 的不足 3 个，已生成当前最快的美国入口（行内有最低值） | 节点能用；晚上或换网络再跑一次通常更低 |
| `FAIL` | 没有可用的美国入口，或出口不是美国 | 看结果行的原因，对照第 5 节 |

生成的文件：链接 `%LOCALAPPDATA%\smj-proxy\nodes.txt`（macOS `~/Library/Application Support/smj-proxy/nodes.txt`，含 UUID 勿外传）；日志 `%LOCALAPPDATA%\smj-proxy\setup-nodes.log`（macOS `~/Library/Logs/smj-proxy-nodes.log`）。

关于 WARP：装没装、开没开都可以。只有「全隧道模式且已连接」时脚本会把它切到代理模式（界面显示「本地代理」），否则节点流量会被塞进 WARP 隧道。改回：`warp-cli mode warp`。

## 2. 配置（常用参数）

| Windows | macOS | 作用 |
| --- | --- | --- |
| `-Prefix B` | `--prefix B` | 节点备注前缀（管理员分配的组别），默认 `CF`，备注形如 `B-SJC-01` |
| `-Uuid xxx` | `--uuid xxx` | 不用包里的 `uuid.txt`，改用这个 UUID |
| `-ReportOnly` | `--report-only` | 只测量不生成链接，不需要 UUID |
| `-NoVerify` | `--no-verify` | 生成链接后不等待导入验证 |
| `-ProxyPort 10808` | `--port 10808` | v2rayN 本地端口不是 10808 时指定 |

带参数运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Nodes.ps1 -Prefix B
```

```bash
bash setup-nodes.sh --prefix B
```

全部参数：Windows `Get-Help .\Setup-Nodes.ps1 -Detailed`，macOS `bash setup-nodes.sh --help`。

## 3. 在 v2rayN 中使用

1. 主窗口按 **Ctrl+V**（macOS **Cmd+V**；没反应就用菜单「配置项 → 从剪贴板导入分享链接」），列表里出现备注 `CF-SJC-01` 之类的新节点。
2. 全选新节点 → 右键「测试服务器延迟」→ 双击最快的启用，左下角显示当前节点名。
3. 把新节点放进一个策略组并选「最低延迟」，v2rayN 会自动切到最快的那个。
4. 设置：节点的 Mux 保持关闭；「设置 → 参数设置」关闭「TLS 分片」；系统代理选「自动配置系统代理」。
5. 删除旧的高延迟节点。

延迟含义：「延迟」列是到入口的一次 TCP 往返，大陆到美西机房一般 160–240 ms，白天拥塞偏高；「真连接延迟」是经 Worker 完整访问一次网站，正常 0.8–1.2 s，受物理距离限制换入口也不会低于约 0.65 s。

## 4. 验证节点和速度

脚本自带：导入并启用节点后在脚本窗口按回车，它经 `127.0.0.1:10808` 查出口国家（必须 US）并测 3 次真连接延迟。

手动验证（Windows 在 PowerShell 执行；macOS 把 `curl.exe` 换成 `curl`，`NUL` 换成 `/dev/null`）：

```powershell
# 出口国家：country_code 必须是 US
curl.exe --proxy socks5h://127.0.0.1:10808 -sS -A "Mozilla/5.0" https://api.ip.sb/geoip

# 真连接延迟：5 次，正常 0.8–1.2 s
1..5 | ForEach-Object { curl.exe --proxy socks5h://127.0.0.1:10808 -o NUL -sS -w 'HTTP %{http_code}  total %{time_total}s\n' https://www.google.com/generate_204 }

# 下载速度：10 MB 测试文件，speed_download 单位 B/s（除以 1048576 得 MB/s）
curl.exe --proxy socks5h://127.0.0.1:10808 -o NUL -sS --max-time 60 -w 'speed %{speed_download} B/s  total %{time_total}s\n' https://proof.ovh.net/files/10Mb.dat
```

v2rayN 里也可以：右键节点「测试真连接延迟」和「测试下载速度」。浏览器打开 <https://ip.sb/> 显示美国即出口正确。

## 5. 常见问题

- **PARTIAL，最低也有 260 ms**：白天线路拥塞时常见（管理员线路 2026-10-19 下午 262 ms，当晚 160–190 ms）。晚上重跑。
- **验证表里全是「落点 HKG 不在美国」**：此刻线路只到香港机房，香港入口 TLS 常 1–5 秒，脚本不选它。稍后或换网络再跑。
- **出口不在美国**：v2rayN 当前启用的不是刚导入的节点，双击 `CF-…` 节点后再验证。
- **WARP 受公司策略管理，切不动也断不开**：请管理员在 Zero Trust → Split Tunnels 排除日志里「WARP 排除 x.x.x.0/24」的网段，或用 v2rayN 时关闭 WARP。
- **Windows 窗口一闪而过 / macOS 提示无法打开**：Windows 按第 1 节「解除锁定」或用第 2 节的命令运行；macOS 按第 1 节在终端先跑一次。
- **导入后 v2rayN 延迟比脚本高 100 ms 以上**：检查 WARP 是否回到了全隧道（`warp-cli settings` 的 Mode 应为 WarpProxy）。

## 6. 还原

- WARP 改回全隧道：`warp-cli mode warp`；删除排除网段：`warp-cli tunnel ip remove-range x.x.x.0/24`。
- 节点在 v2rayN 里删除即可；脚本生成的两个文件见第 1 节。

## 7. 管理员：打包

在仓库的 `tools\colleague-kit` 目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pack-Kit.ps1
```

它从本机的 V2RAYN-PRIVATE.md 读取节点 UUID 写成 `uuid.txt`，连同 5 个文件压成桌面上的 `smj-colleague-kit.zip`；`uuid.txt` 只进 zip，不会留在仓库。zip 含凭据，只通过私下渠道发给同事。`-OutFile` 改输出位置，`-NoUuid` 不放入 UUID（同事自行输入）。分组时让同事带 `-Prefix B` / `--prefix B` 运行。开机自检见仓库 `tools/startup`。
