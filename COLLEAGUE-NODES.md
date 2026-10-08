# 四组 v2rayN 入口候选地址

更新日期：2026-10-02。Worker：`zyvpn`；域名：`dfvpn.smjtools.com`。

完整的、可直接复制导入 v2rayN 的四组分享链接保存在本机私密文件 [V2RAYN-PRIVATE.md](./V2RAYN-PRIVATE.md)。A / B / C 各 12 个，D 组 24 个，共 60 个。 2026-10-05 新增 ZY 组 16 个实测优选入口（见下文），其链接同样保存在该私密文件。该文件含有效 UUID，已被 Git 忽略，不要公开或提交。本文仅保留不含凭据的入口列表和使用说明。

## 国家与验证范围

以下为四组互不重复的 Cloudflare IPv4 入口候选地址，共 60 个。地址取自 [Cloudflare 官方 IPv4 范围](https://www.cloudflare.com/ips-v4)。不是按 IP 地理定位挑选的日本 / 美国出口，也不是已经完成逐个代理测速的优选排名。

**“每组 6 个日本出口 + 6 个美国出口”的条件目前未满足。** Cloudflare 入口 IP 使用 Anycast，同一个 IP 会因访问者网络而连接不同机房；当前所有地址连接同一个 `aws:us-west-2` 放置的 Worker。区域提示控制执行位置，不保证出口国家；不能把入口按备注分为“日本 / 美国”就宣称具备对应出口。实际出口国家仍需各节点的端到端验证。

原三组曾从部署机器使用正确的域名 Host / SNI，绕过环境代理逐个测试 HTTPS：36/36 个地址的 `/login` 返回 HTTP 200，TLS 证书校验全部通过。同步新增入口时再次检查 HTTPS 与 VLESS / WebSocket 隧道，最新逐节点结果见本机私密文件。单次可用性检查不等于优选排名、最终出口国家、吞吐或各同事所在网络均可用；请分别在各自网络中测速。

## ZY 组：2026-10-05 实测优选入口（16 个）

排查环境：本机 Windows 11，WLAN，中国大陆线路，2026-10-05 10:50–11:20 测量；v2rayN 7.x + xray，本地混合端口 10808；Cloudflare WARP 消费者版（Free）处于 `Mode: Warp` 全隧道、MASQUE 协议。

### 延迟 300 ms 以上的原因

1. **WARP 全隧道接管了节点流量（主因）。** `warp-cli tunnel stats` 显示隧道落点 LAX、估算延迟 285 ms、丢包 0.37%，状态 `Network: unstable`；xray 到入口的 TCP/TLS 全部经它转发。经 WARP 时同一入口 TCP 建连 0.26–2.3 s、真连接 2–10 s 或超时；断开 WARP 直连后 TCP 建连稳定在 0.16–0.21 s。v2rayN 里 ZY 分组记录的 317 / 491 / 2063 / 超时与 US 分组同一批 IP 的 237–257 ms，差别只是测量时是否经过 WARP。
2. **原入口 IP 落点 LAX，约 200–240 ms。** 对 Cloudflare 公布的 5956 个 /24 段各探测一个 IP：`104.17.128.0/19`、`172.64.79.0/24`、`162.159.237.0/24` 从本线路落点 SJC，TCP 中位数 165–180 ms，6 次探测 0 丢包，TLS 握手 0.34–0.41 s（恰为 2×RTT，无重传）。落点 HKG 的段 TCP 虽低至 135–170 ms，但 TLS 1–2.5 s、真连接 1–10 s 并频繁超时，不采用。
3. **路径 `/` 未启用 WebSocket 早数据。** Worker 支持标准 `sec-websocket-protocol` 早数据，客户端路径改为 `/?ed=2560` 可少一个往返；实测每次新建连接省约 250 ms（LAX 入口 1.20 s → 0.95 s）。
4. 放置提示 `aws:us-west-2` 使 Worker 在 SEA 执行（响应头 `Cf-Placement: remote-SEA`，经节点查询出口为 Kent, Washington, US）。入口在 SJC / LAX 时每个服务端往返仅多 20–40 ms，且改动会影响四组同事的出口，本次不改。

### 两个指标的预期值（WARP 关闭、SJC 入口、`/?ed=2560`）

| v2rayN 指标 | 含义 | 预期 |
| --- | --- | --- |
| 测试服务器延迟（tcping） | 到入口 IP 的一次 TCP 往返 | SJC 入口 165–180 ms；LAX 备用入口 180–210 ms |
| 真连接延迟 | 经 Worker 对 `www.google.com/generate_204` 完成一次完整 HTTPS 请求，约 4 个往返 | 0.80–0.95 s；受本线路 RTT 限制无法低于约 0.65 s，换任何入口都一样 |

### 使用前提：节点流量不能再经过 WARP

二选一。方式一，使用 v2rayN 期间断开 WARP：

```text
warp-cli disconnect
```

方式二，保留 WARP，但把入口段排除出隧道（消费者版支持，持久生效，可用 `warp-cli tunnel ip list` 查看、`remove-range` 撤销）：

```text
warp-cli tunnel ip add-range 104.17.128.0/19
warp-cli tunnel ip add-range 172.64.79.0/24
warp-cli tunnel ip add-range 162.159.237.0/24
warp-cli tunnel ip add-range 104.18.55.0/24
warp-cli tunnel ip add-range 104.18.57.0/24
warp-cli tunnel ip add-range 104.16.0.0/24
warp-cli tunnel ip add-range 104.24.0.0/24
```

v2rayN 侧另有一项可选优化：直连 Cloudflare 入口不需要「TLS 分片」，关闭它可省每次握手 20–40 ms。节点必须关闭 Mux。

### 入口列表

前 12 个为 SJC 主用入口（同属一个 BGP 前缀，路由随时段可能变化），后 4 个为 LAX 备用入口，tcping 仍低于 250 ms。按 [方式二](#方式二默认-vless--websocket--tls-配置生成链接) 的脚本可生成完整链接；本机私密文件已含现成链接。

```text
104.17.157.1:443#ZY-SJC-01
104.17.152.1:443#ZY-SJC-02
104.17.150.1:443#ZY-SJC-03
104.17.151.1:443#ZY-SJC-04
104.17.143.1:443#ZY-SJC-05
104.17.138.1:443#ZY-SJC-06
104.17.148.1:443#ZY-SJC-07
104.17.149.1:443#ZY-SJC-08
104.17.133.1:443#ZY-SJC-09
104.17.135.1:443#ZY-SJC-10
172.64.79.1:443#ZY-SJC-11
162.159.237.1:443#ZY-SJC-12
104.18.57.1:443#ZY-LAX-13
104.18.55.1:443#ZY-LAX-14
104.16.0.1:443#ZY-LAX-15
104.24.0.1:443#ZY-LAX-16
```

| 备注 | 入口 IP | 落点 | TCP 中位数 / 最大值（6 次） | TLS 握手（2 次） |
| --- | --- | --- | --- | --- |
| ZY-SJC-01 | 104.17.157.1 | SJC | 170 / 193 ms | 0.341 / 0.344 s |
| ZY-SJC-02 | 104.17.152.1 | SJC | 172 / 178 ms | 0.341 / 0.369 s |
| ZY-SJC-03 | 104.17.150.1 | SJC | 174 / 193 ms | 0.334 / 0.341 s |
| ZY-SJC-04 | 104.17.151.1 | SJC | 172 / 182 ms | 0.343 / 0.355 s |
| ZY-SJC-05 | 104.17.143.1 | SJC | 169 / 180 ms | 0.363 / 0.388 s |
| ZY-SJC-06 | 104.17.138.1 | SJC | 172 / 190 ms | 0.339 / 0.353 s |
| ZY-SJC-07 | 104.17.148.1 | SJC | 170 / 191 ms | 0.349 / 0.358 s |
| ZY-SJC-08 | 104.17.149.1 | SJC | 171 / 190 ms | 0.350 / 0.359 s |
| ZY-SJC-09 | 104.17.133.1 | SJC | 169 / 199 ms | 0.349 / 0.356 s |
| ZY-SJC-10 | 104.17.135.1 | SJC | 171 / 198 ms | 0.347 / 0.355 s |
| ZY-SJC-11 | 172.64.79.1 | SJC | 165 / 191 ms | 0.341 / 0.375 s |
| ZY-SJC-12 | 162.159.237.1 | SJC | 180 / 193 ms | 0.346 / 0.337 s |
| ZY-LAX-13 | 104.18.57.1 | LAX | 180 / 218 ms | 0.385 / 0.401 s |
| ZY-LAX-14 | 104.18.55.1 | LAX | 190 / 200 ms | 0.374 / 0.406 s |
| ZY-LAX-15 | 104.16.0.1 | LAX | 209 / 229 ms | 0.430 / 0.415 s |
| ZY-LAX-16 | 104.24.0.1 | LAX | 211 / 219 ms | 0.425 / 0.435 s |

测量脚本与复测方法见 [tools/latency](./tools/latency/README.md)。

## 同事端优化方案（v2rayN + Cloudflare One 客户端）

同事端出现同样的 300 ms 以上延迟时，原因与本机一致，按下面顺序处理；每位同事的运营商路由不同，**入口 IP 必须在自己的网络里重新测**，不要直接照搬 ZY 组的 IP。

### 一键脚本

仓库内 [tools/latency/Optimize-Colleague.ps1](./tools/latency/Optimize-Colleague.ps1) 只依赖 Windows 自带的 PowerShell 5.1 和 curl.exe，不需要 Python。把该文件发给同事，在 PowerShell 中运行：

```powershell
powershell -ExecutionPolicy Bypass -File .\Optimize-Colleague.ps1 -Prefix B
```

脚本依次：检测 WARP 并临时断开（结束时自动重连）→ 对 Cloudflare 全部 IPv4 段每个 /24 探测一个 IP 的 TCP 建连（约 1 分钟）→ 对最快 150 个复测 6 次，剔除丢包或抖动 → 对前 36 个用真实 SNI 各做 2 次 TLS 验证并读出落点机房，剔除 TLS 异常慢的落点 → 把选中入口所在 /24 加入 WARP 排除列表 → 用同事输入的 UUID（不回显，不写盘）生成带 `/?ed=2560` 的 12 条链接并复制到剪贴板。随后在 v2rayN 选中分组按 Ctrl+V 导入，右键「测试服务器延迟」，启用最快的节点。

参数：`-Top` 节点数（默认 12）、`-Prefix` 备注前缀（默认 CF，备注形如 B-SJC-01）、`-ReportOnly` 只测量不生成链接、`-NoWarpChange` 不改动 WARP（需自行先关闭 WARP）、`-OutFile` 把链接另存为文件（含凭据）。

受组织 Zero Trust 策略管理的 WARP 设备可能无法断开或添加排除；脚本会提示。此时请管理员在 Zero Trust 的 Split Tunnels 中排除选出的网段，或者使用 v2rayN 期间断开 WARP。

### 开机自检脚本

[tools/startup](./tools/startup/README.md) 提供登录后静默运行的自检脚本（Windows 计划任务 / macOS LaunchAgent，不弹窗、不需要管理员）：确认 v2rayN 在运行且只有一个实例、把 Cloudflare One 客户端切到代理模式以免接管节点流量和 DNS、系统代理指向 v2rayN、经代理访问 ip.sb 的出口为美国、入口延迟低于 250 ms，结果写入日志。安装与参数见该目录的 README。

### 手动方案

不方便运行脚本时，按顺序做这三件事即可拿到绝大部分收益：

1. **让节点流量绕开 WARP。** 使用 v2rayN 期间执行 `warp-cli disconnect`；或保留 WARP，对每个节点 IP 所在网段执行 `warp-cli tunnel ip add-range <网段>/24`（消费者版支持）。不处理这一步，换任何入口都没有效果。
2. **把节点路径从 `/` 改为 `/?ed=2560`。** 在 v2rayN 编辑节点，传输「路径」填 `/?ed=2560`，其他不动；Worker 已支持该早数据格式，每次新建连接少一个往返。
3. **在自己的网络里挑入口。** 可用本文件各组列表里的 IP 先做「测试服务器延迟」，优先选 tcping 低且稳定的；或用 [tools/latency](./tools/latency/README.md) 的脚本扫描。注意 tcping 很低但真连接经常超时的落点不要选。

v2rayN 设置：节点 Mux 必须关闭；参数设置里的「TLS 分片」可关闭，直连 Cloudflare 不需要它。

### 期望值与边界

`测试服务器延迟` 约等于到入口的一次往返，大陆常见线路到 SJC / LAX 落点为 160～240 ms；`真连接延迟` 约等于 4 倍往返再加 Worker 到目标站的耗时，通常 0.7～1.0 s，受物理距离限制，换入口不会低于 0.65 s。Worker 放置区域保持 `aws:us-west-2`，出口为美国；若将来多数同事的入口都落在亚洲机房，再评估是否迁移放置区域。

## 同事 A：12 个候选入口

```text
104.16.0.1:443#A-01
104.16.1.1:443#A-02
104.16.2.1:443#A-03
104.16.3.1:443#A-04
104.16.4.1:443#A-05
104.16.5.1:443#A-06
104.24.0.1:443#A-07
104.24.1.1:443#A-08
104.24.2.1:443#A-09
104.24.3.1:443#A-10
104.24.4.1:443#A-11
104.24.5.1:443#A-12
```

## 同事 B：12 个候选入口

```text
104.17.0.1:443#B-01
104.17.1.1:443#B-02
104.17.2.1:443#B-03
104.17.3.1:443#B-04
104.17.4.1:443#B-05
104.17.5.1:443#B-06
104.25.0.1:443#B-07
104.25.1.1:443#B-08
104.25.2.1:443#B-09
104.25.3.1:443#B-10
104.25.4.1:443#B-11
104.25.5.1:443#B-12
```

## 同事 C：12 个候选入口

```text
104.18.0.1:443#C-01
104.18.1.1:443#C-02
104.18.2.1:443#C-03
104.18.3.1:443#C-04
104.18.4.1:443#C-05
104.18.5.1:443#C-06
104.26.0.1:443#C-07
104.26.1.1:443#C-08
104.26.2.1:443#C-09
104.26.3.1:443#C-10
104.26.4.1:443#C-11
104.26.5.1:443#C-12
```

## 同事 D：24 个候选入口

```text
104.19.0.1:443#D-01
104.19.1.1:443#D-02
104.19.2.1:443#D-03
104.19.3.1:443#D-04
104.19.4.1:443#D-05
104.19.5.1:443#D-06
104.19.6.1:443#D-07
104.19.7.1:443#D-08
104.19.8.1:443#D-09
104.19.9.1:443#D-10
104.19.10.1:443#D-11
104.19.11.1:443#D-12
104.20.0.1:443#D-13
104.20.1.1:443#D-14
104.20.2.1:443#D-15
104.20.3.1:443#D-16
104.20.4.1:443#D-17
104.20.5.1:443#D-18
104.20.6.1:443#D-19
104.20.7.1:443#D-20
104.20.8.1:443#D-21
104.20.9.1:443#D-22
104.20.10.1:443#D-23
104.20.11.1:443#D-24
```

## v2rayN 使用方式

这些 `IP:端口#备注` 行是项目优选地址列表格式，**不能直接当作完整节点链接导入 v2rayN**。使用下列任一方式。

### 方式一：沿用现有订阅节点

1. 管理员登录 `https://dfvpn.smjtools.com/admin`，获取项目生成的原始节点 / 订阅，私下交给同事。不要分享 `ADMIN` 密码。
2. 同事在 v2rayN 导入原始节点，然后按本组数量复制节点（A / B / C 各 12 个，D 组 24 个）。
3. 分别将连接地址改为本组 IP，端口设为 `443`；只改连接地址和备注，保留原始节点的 UUID、传输方式、路径、TLS SNI 和 WebSocket Host。
4. TLS SNI 和 WebSocket Host 应保持 `dfvpn.smjtools.com`，不能改成 IP；不要关闭证书验证。
5. 对各节点进行真连接延迟和速度测试，再选择稳定节点。需要出口国家时，通过实际代理访问 IP 查询服务验证，不要依靠备注判断。

### 方式二：默认 VLESS + WebSocket + TLS 配置生成链接

仅适用于后台仍使用 VLESS、WebSocket、路径 `/` 的默认配置（脚本会附加早数据参数 `?ed=2560`，Worker 已验证支持）；若你已修改协议、路径或其他传输设置，使用方式一，不要套用本示例。

在仓库根目录执行以下 PowerShell，将提示输入组别及后台显示的 UUID；**UUID 不是 ADMIN 密码，也不是 Cloudflare API Token**。脚本生成本组所有链接并复制到剪贴板，随后在 v2rayN 中选择“从剪贴板导入分享链接”。

```powershell
$group = (Read-Host 'Group ZY, A, B, C or D').Trim().ToUpperInvariant()
if ($group -notmatch '^(ZY|[ABCD])$') { throw 'Group must be ZY, A, B, C or D.' }
$uuid = (Read-Host 'Node UUID from admin panel').Trim()
if ($uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { throw 'A valid UUIDv4 is required.' }
$text = Get-Content -LiteralPath '.\COLLEAGUE-NODES.md' -Raw
$pattern = if ($group -eq 'ZY') { '(?m)^(\d{1,3}(?:\.\d{1,3}){3}):443#(ZY-[A-Z]+-\d{2})\r?$' } else { "(?m)^(\d{1,3}(?:\.\d{1,3}){3}):443#($group-\d{2})\r?$" }
$entries = [regex]::Matches($text, $pattern)
$expectedCount = switch ($group) { 'ZY' { 16 } 'D' { 24 } default { 12 } }
if ($entries.Count -ne $expectedCount) { throw "Expected exactly $expectedCount entries for the selected group." }
$links = foreach ($entry in $entries) {
    'vless://{0}@{1}:443?security=tls&type=ws&host=dfvpn.smjtools.com&fp=chrome&sni=dfvpn.smjtools.com&path=%2F%3Fed%3D2560&encryption=none#{2}' -f $uuid, $entry.Groups[1].Value, $entry.Groups[2].Value
}
$links -join "`r`n" | Set-Clipboard
Write-Host "Copied $expectedCount private node links. Import them into v2rayN; clear the clipboard afterwards."
```

生成后的链接含有效访问凭据，不能提交到 Git、公开发布或交给外部订阅转换服务。此文档不包含真实 UUID、ADMIN 密码或 API Token。

## 共用凭据的限制

四组只是入口分组，不是四个独立账户。当前部署使用同一个固定 UUID Secret，无法按组单独撤销某位同事的访问；轮换该 UUID 会影响四组节点。ADMIN 仍仅作为管理员密码，不应向同事分享；若改回派生 UUID 模式，修改 ADMIN 也可能影响节点凭据。
