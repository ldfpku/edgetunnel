# 三位同事的 v2rayN 入口候选地址

更新日期：2026-10-02。Worker：`zyvpn`；域名：`dfvpn.smjtools.com`。

完整的、可直接复制导入 v2rayN 的三组分享链接保存在本机私密文件 [V2RAYN-PRIVATE.md](./V2RAYN-PRIVATE.md)。该文件含有效 UUID，已被 Git 忽略，不要公开或提交。本文仅保留不含凭据的入口列表和使用说明。

## 国家与验证范围

以下为三组互不重复的 Cloudflare IPv4 入口候选地址，每组 12 个，共 36 个。地址取自 [Cloudflare 官方 IPv4 范围](https://www.cloudflare.com/ips-v4)。不是按 IP 地理定位挑选的日本 / 美国出口，也不是已经完成代理测速的优选排名。

**“每组 6 个日本出口 + 6 个美国出口”的条件目前未满足。** Cloudflare 入口 IP 使用 Anycast，同一个 IP 会因访问者网络而连接不同机房；当前所有地址连接同一个 `azure:japanwest` 放置的 Worker。不能把每组后六个入口改名为“美国”就宣称有美国出口。要满足实际出口国家要求，需要可用的美国部署 / 上游，以及各节点的端到端出口验证。

本次从部署机器使用正确的域名 Host / SNI，绕过环境代理逐个测试 HTTPS：最终部署后 36/36 个地址的 `/login` 返回 HTTP 200，TLS 证书校验全部通过。入口可达不等于 VLESS 隧道、最终出口、吞吐或三位同事所在网络均可用；请分别在各自网络中测速。

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

## v2rayN 使用方式

这些 `IP:端口#备注` 行是项目优选地址列表格式，**不能直接当作完整节点链接导入 v2rayN**。使用下列任一方式。

### 方式一：沿用现有订阅节点

1. 管理员登录 `https://dfvpn.smjtools.com/admin`，获取项目生成的原始节点 / 订阅，私下交给同事。不要分享 `ADMIN` 密码。
2. 同事在 v2rayN 导入原始节点，然后复制为 12 个节点。
3. 分别将连接地址改为本组 IP，端口设为 `443`；只改连接地址和备注，保留原始节点的 UUID、传输方式、路径、TLS SNI 和 WebSocket Host。
4. TLS SNI 和 WebSocket Host 应保持 `dfvpn.smjtools.com`，不能改成 IP；不要关闭证书验证。
5. 对各节点进行真连接延迟和速度测试，再选择稳定节点。需要出口国家时，通过实际代理访问 IP 查询服务验证，不要依靠备注判断。

### 方式二：默认 VLESS + WebSocket + TLS 配置生成链接

仅适用于后台仍使用 VLESS、WebSocket、路径 `/` 的默认配置；若你已修改协议、路径或其他传输设置，使用方式一，不要套用本示例。

在仓库根目录执行以下 PowerShell，将提示输入组别及后台显示的 UUID；**UUID 不是 ADMIN 密码，也不是 Cloudflare API Token**。脚本生成本组 12 个链接并复制到剪贴板，随后在 v2rayN 中选择“从剪贴板导入分享链接”。

```powershell
$group = (Read-Host 'Group A, B or C').Trim().ToUpperInvariant()
if ($group -notmatch '^[ABC]$') { throw 'Group must be A, B or C.' }
$uuid = (Read-Host 'Node UUID from admin panel').Trim()
if ($uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { throw 'A valid UUIDv4 is required.' }
$text = Get-Content -LiteralPath '.\COLLEAGUE-NODES.md' -Raw
$entries = [regex]::Matches($text, "(?m)^(104\.\d+\.\d+\.1):443#($group-\d{2})\r?$")
if ($entries.Count -ne 12) { throw 'Expected exactly 12 entries for the selected group.' }
$links = foreach ($entry in $entries) {
    'vless://{0}@{1}:443?security=tls&type=ws&host=dfvpn.smjtools.com&fp=chrome&sni=dfvpn.smjtools.com&path=%2F&encryption=none#{2}' -f $uuid, $entry.Groups[1].Value, $entry.Groups[2].Value
}
$links -join "`r`n" | Set-Clipboard
Write-Host 'Copied 12 private node links. Import them into v2rayN; clear the clipboard afterwards.'
```

生成后的链接含有效访问凭据，不能提交到 Git、公开发布或交给外部订阅转换服务。此文档不包含真实 UUID、ADMIN 密码或 API Token。

## 共用凭据的限制

三组只是入口分组，不是三个独立账户。当前项目使用同一套 UUID，无法按组单独撤销某位同事的访问。修改 ADMIN 可能改变派生 UUID / 订阅凭据，三位同事的节点会一起受影响；固定 UUID 后应按相应凭据管理方式撤销访问。
