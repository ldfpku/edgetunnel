# 同事一键配置包（Windows / macOS）

这个文件夹里的脚本会在**你自己的网络**里挑出到 Cloudflare 入口延迟最低、落点在美国的地址，生成可直接导入 v2rayN 的节点链接，并验证出口在美国。全程约 3–5 分钟（线路丢包多时更久），只需要输入一次管理员给你的节点 UUID（或者管理员已经把它放在包里）。脚本不含任何凭据，不改 v2rayN 的配置，也不碰系统代理。

目标三条：**到入口的延迟低于 200 ms**、**出口 IP 在美国**、**Cloudflare One (WARP) 开着关着都不影响**。

## 一、开始之前

| 需要 | Windows | macOS |
| --- | --- | --- |
| v2rayN | 7.x，已安装并能打开 | 7.x（v2rayN.app），已安装并能打开 |
| 节点 UUID | 管理员私下发给你的一串 `xxxxxxxx-xxxx-4xxx-xxxx-xxxxxxxxxxxx`；它不是后台密码。包里若已有 `uuid.txt`，不用输入 | 同左 |
| 系统自带工具 | PowerShell 5.1、curl.exe（Windows 10 1803 以上都有） | bash、perl、curl（macOS 自带） |
| 网络 | 直接连公司或家里的网络，不要挂其他 VPN | 同左 |

Cloudflare One / WARP 客户端：装没装、开没开都可以。脚本只在它处于「全隧道（WARP）模式且已连接」时把它切到「代理模式」（界面里显示为「本地代理」），因为全隧道会把节点流量也塞进 WARP 隧道，延迟至少多 100 ms。这个改动持久生效，想改回：`warp-cli mode warp`。

## 二、Windows：双击 `setup-nodes.cmd`

1. 把整个文件夹解压到不会删的位置（例如 `D:\smj-proxy`），**不要放在网络共享盘上**。
2. 若 Windows 提示「已阻止」或「无法加载脚本」：右键 `Setup-Nodes.ps1` → 属性 → 勾选「解除锁定」→ 确定。
3. 先启动 v2rayN（托盘里有图标即可）。
4. 双击 `setup-nodes.cmd`。黑色窗口会依次显示 6 步进度（见第四节）。
5. 第 6 步会提示输入 UUID（输入时不显示字符，粘贴后直接回车）。包里有 `uuid.txt` 时跳过这一步。
6. 看到「已把 N 条节点链接复制到剪贴板」后：切到 v2rayN 主窗口 → 按 **Ctrl+V** → 节点列表里出现备注形如 `CF-SJC-01` 的新节点。
7. 全选新节点 → 右键「测试服务器延迟」→ 双击最快的那个启用（左下角显示该节点名）。
8. 回到脚本窗口按回车，脚本经 v2rayN 检查出口国家与真连接延迟，打印 `RESULT:` 一行。

用命令行运行可以加参数（见第五节）：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Nodes.ps1 -Prefix B
```

## 三、macOS：先在终端跑一次

Windows 上打的 zip 会丢掉 `.command` 的可执行权限，macOS 还会给下载的文件加隔离标记，所以**第一次必须在终端运行**：

1. 解压到不会删的位置，例如 `~/smj-proxy`。
2. 打开「终端」，执行（把路径换成你的）：

   ```bash
   cd ~/smj-proxy
   xattr -dr com.apple.quarantine .
   chmod +x setup-nodes.command setup-nodes.sh
   bash setup-nodes.command
   ```

3. 之后就可以直接双击 `setup-nodes.command`（若「访达」问是否用终端打开，选「打开」）。
4. 其余步骤与 Windows 相同：第 6 步输入 UUID → 在 v2rayN 主窗口按 **Cmd+V** 导入（没反应就用菜单「配置项 → 从剪贴板导入分享链接」） → 测延迟、启用最快节点 → 回到终端按回车验证。

带参数运行：

```bash
bash setup-nodes.sh --prefix B
```

## 四、脚本每一步在做什么

| 步骤 | 做什么 | 看什么 |
| --- | --- | --- |
| 1/6 环境检查 | 找 curl、v2rayN、xray 核心、Cloudflare One 客户端 | 找不到 v2rayN 只是警告，链接照样生成 |
| 2/6 WARP 适配 | 读取 WARP 模式和到 Cloudflare 入口的路由接口。未安装 / 已断开 / 代理模式：不动。全隧道且已连接：`warp-cli mode proxy`。切不动（公司 Zero Trust 管理的设备）：测量期间临时断开，结束后重连并把选中网段加入 WARP 排除列表 | 「WARP 没有接管直连流量」或「已切到代理模式」 |
| 3/6 扫描 | 对 Cloudflare 公布的全部 IPv4 段，每个 /24 探测一个 IP 的 TCP 建连时间（5956 个，约 1 分钟） | 「可达 N 段；TCP 建连分布」：你的线路到各机房的延迟直方图 |
| 4/6 复测 | 最快的 150 个各测 6 次，剔除有丢包或重传（最大值远高于中位数）的 | 「0 丢包且无重传的入口 N 个」 |
| 5/6 验证 | 按延迟顺序分批（每批 40 个，最多 120 个）用真实域名做 2 次 TLS 连接：必须 HTTP 200、落点机房在美国、TLS 耗时约 2 倍往返，直到找够 12 个；入选入口再做 WebSocket 握手，必须返回 101 且没被安全质询 | 验证表：`Reject` / 剔除原因 为空的是可用入口。常见剔除：`落点 HKG 不在美国`（香港机房 TCP 虽低但 TLS 常常 1–5 秒，不能用） |
| 6/6 生成链接 | 取中位延迟低于 200 ms 的入口（最多 12 个；不足 3 个时改为取最快的美国落点入口并标记 PARTIAL），生成 VLESS/WebSocket/TLS 链接（路径 `/?ed=2560`，比默认路径少一个往返），复制到剪贴板并写入文件。Windows 上找得到 xray 核心时，先用临时 xray 经最快入口测 3 次真连接延迟并查出口国家 | 「已把 N 条节点链接复制到剪贴板」 |
| 导入后验证 | 你导入并启用节点后，脚本经 `127.0.0.1:10808` 访问 ip.sb 查出口国家（必须 US）并测 3 次真连接延迟 | 「出口 US：…」「真连接延迟 … s」 |

### 两个延迟的含义

- **延迟 / 测试服务器延迟**（v2rayN「延迟」列）：到入口 IP 的一次 TCP 往返。大陆到美西机房（SJC / LAX / SEA）一般 160–240 ms，白天拥塞时偏高，晚上偏低。
- **真连接延迟**：经 Worker 完整访问一次 google 的 generate_204，约 4 个往返再加 Worker 到目标站的时间，正常 0.8–1.2 s。它受物理距离限制，换入口也不会低于约 0.65 s。

### `RESULT:` 一行怎么读

| 结果 | 含义 | 你要做什么 |
| --- | --- | --- |
| `RESULT: OK` | 至少 3 个入口低于 200 ms，出口美国 | 用就行 |
| `RESULT: PARTIAL` | 低于 200 ms 的入口不足 3 个，脚本生成了当前最快的美国落点入口（结果行里有最低值）。这是你当前线路到美国机房的延迟，换入口无法更低 | 节点可用。晚间或换网络（例如手机热点）再跑一次，通常能拿到更低的 |
| `RESULT: FAIL` | 一个可用入口都没有，或出口不是美国 | 看失败原因（下一节），处理后重跑 |

### 生成的文件

| 内容 | Windows | macOS |
| --- | --- | --- |
| 日志 | `%LOCALAPPDATA%\smj-proxy\setup-nodes.log` | `~/Library/Logs/smj-proxy-nodes.log` |
| 节点链接（含 UUID，勿外传） | `%LOCALAPPDATA%\smj-proxy\nodes.txt` | `~/Library/Application Support/smj-proxy/nodes.txt` |

## 五、参数

| Windows | macOS | 作用 |
| --- | --- | --- |
| `-Prefix B` | `--prefix B` | 节点备注前缀（管理员分配的组别），默认 `CF`，备注形如 `B-SJC-01` |
| `-Top 12` | `--top 12` | 最多生成几个节点 |
| `-MaxLatencyMs 200` | `--max-ms 200` | 入口延迟上限 |
| `-MinNodes 3` | `--min-nodes 3` | 至少几个达标入口才算 OK |
| `-WarpPolicy proxy\|disconnect\|keep` | `--warp=proxy\|disconnect\|keep` | 全隧道时切代理模式 / 断开 / 不动（keep 会直接判 FAIL，因为测出来的是隧道延迟） |
| `-ReportOnly` | `--report-only` | 只测量不生成链接，不需要 UUID |
| `-NoVerify` | `--no-verify` | 生成链接后不等待导入验证 |
| `-NoClipboard` | `--no-clipboard` | 链接打印到屏幕，不写剪贴板 |
| `-OutFile 文件` | `--out 文件` | 链接另存到指定文件 |
| `-Uuid xxx` | `--uuid xxx` | 直接给 UUID（也可用环境变量 `SMJ_NODE_UUID`，或把 `uuid.txt` 放在脚本同目录） |
| `-ProxyPort 10808` | `--port 10808` | v2rayN 本地端口不是 10808 时指定 |
| `-V2rayNPath <exe>` | — | v2rayN 不在常见位置时指定 |

## 六、常见问题

**延迟列全是 -1 或超时。** 域名可能被安全质询，或 WARP 全隧道接管了流量。脚本第 5 步会报「被安全质询」或第 2 步报 WARP 状态；前者告诉管理员，后者执行 `warp-cli mode proxy` 后重跑。

**验证表里全是 `落点 HKG 不在美国`。** 你的线路此刻只能到香港机房；香港机房 TCP 看着低，但 TLS 和真连接经常 1–5 秒或超时，脚本不选它。稍后再跑，或换网络。

**`RESULT: PARTIAL`，最低也有 260 ms。** 白天线路拥塞时常见（2026-10-19 下午管理员线路实测最低 262 ms，当晚 160–190 ms）。节点能用，只是没达到 200 ms 的目标；晚上重跑一次。

**出口不在美国。** 说明 v2rayN 当前启用的不是刚导入的节点（看左下角当前节点名），或者启用了其他出口的订阅。在 v2rayN 里双击 `CF-…` 节点后再验证。

**WARP 受公司策略管理，切不动也断不开。** 请管理员在 Zero Trust → Settings → WARP Client → Split Tunnels 里排除脚本选出的网段（日志里有「WARP 排除 x.x.x.0/24」），或使用 v2rayN 时关闭 WARP。

**Windows 双击脚本窗口一闪而过。** 用第二节的命令行方式运行，或右键 `Setup-Nodes.ps1` → 属性 → 解除锁定。

**macOS 双击提示「无法打开」。** 按第三节在终端先运行一次（`xattr` + `chmod`）。

**导入后 v2rayN 延迟仍高于脚本测出的值。** v2rayN 的测试经过 xray，比脚本的纯 TCP 多 20–40 ms 属正常；高出 100 ms 以上时，检查 WARP 是否又回到了全隧道模式（`warp-cli settings` 里 Mode 应为 WarpProxy）。

**v2rayN 设置建议。** 节点的 Mux 保持关闭；设置 → 参数设置：关闭「TLS 分片」（直连 Cloudflare 不需要它，开着每次握手多 20–40 ms）。

## 七、还原

- WARP 改回全隧道：`warp-cli mode warp`；删除排除网段：`warp-cli tunnel ip remove-range x.x.x.0/24`（`warp-cli tunnel ip list` 查看）。
- 删除节点：在 v2rayN 里选中 `CF-…` 节点删除即可。脚本没有改动 v2rayN 的其他配置和系统代理。
- 删除脚本生成的文件：上面「生成的文件」表中的两个文件。

## 八、可选：开机自检

仓库 `tools/startup` 目录提供开机后静默自检（v2rayN 在运行、WARP 不接管、系统代理指向 v2rayN、出口美国、入口延迟达标），Windows 双击 `一键设置.cmd`，macOS 双击 `一键设置.command`。需要时让管理员把该目录一起打包。

## 九、给管理员：打包与分发

1. 用 PowerShell 打包（不要用资源管理器右键压缩，它写出的中文文件名在 macOS 上会乱码）：

   ```powershell
   Compress-Archive -Path tools\colleague-kit\* -DestinationPath smj-colleague-kit.zip -Force
   ```

2. 想让同事零输入：把节点 UUID 单独写进 `tools\colleague-kit\uuid.txt`（一行，无空格）再打包，并只通过私下渠道发送。该文件已被 Git 忽略，发完请删除本机副本。
3. 同事分组：让对方运行时带 `-Prefix B` / `--prefix B`，节点备注就会是 `B-SJC-01`。
4. 同事在自己网络里选出的入口与管理员文档（`COLLEAGUE-NODES.md`）中预选的 A–D 组不同是正常的：不同运营商落点不同；预选组只是没法运行脚本时的备用方案（Windows 可用 `tools\latency\一键生成节点.ps1` 直接生成预选组）。
