<#
.SYNOPSIS
  一键生成本组 v2rayN 节点链接。单个文件即可运行，不依赖仓库里的其他文件，也不含任何凭据。

.DESCRIPTION
  内置 ZY / A / B / C / D 五组 Cloudflare 入口地址（2026-10-18 从管理员网络实测挑选；A–D 组各入口互不重复，
  也不与 ZY 组重复）。运行后依次：
  1) 选择组别；
  2) 对本组每个入口做 3 次 TCP 建连测量（约 5 秒），按延迟排序，标出不可达或偏慢的入口；
  3) 输入节点 UUID（不回显，只在内存中使用，不写盘）；
  4) 生成 VLESS / WebSocket / TLS 分享链接（路径 /?ed=2560，即 WebSocket 早数据），复制到剪贴板。
  之后在 v2rayN 主窗口按 Ctrl+V 导入，右键「测试服务器延迟」，启用最快的节点。

  前提：使用 v2rayN 期间 Cloudflare WARP 不能接管节点流量（断开 WARP，或 warp-cli mode proxy，
  或把入口网段排除出隧道）；节点 Mux 关闭；参数设置里的「TLS 分片」关闭。

.PARAMETER Group        组别：ZY、A、B、C 或 D。不传则提示输入。
.PARAMETER Uuid         节点 UUID（UUIDv4）。不传则提示输入（不回显）；也可用环境变量 SMJ_NODE_UUID 提供。
.PARAMETER HostName     Worker 自定义域名，默认 dfvpn.smjtools.com；同时作为 TLS SNI 与 WebSocket Host。
.PARAMETER Path         WebSocket 路径，默认 /?ed=2560。
.PARAMETER NoTest       不做延迟测量，按内置顺序输出本组全部入口。
.PARAMETER Probes       每个入口的 TCP 测量次数，默认 3。
.PARAMETER MaxLatencyMs 超过该中位延迟的入口标为「慢」并排在最后，默认 250。
.PARAMETER ListOnly     只打印本组 IP:443#备注 列表（不含凭据），不需要 UUID，不生成链接。
.PARAMETER OutFile      额外把链接写入该文件。文件含凭据，放在不会提交到 Git 或公开的位置。
.PARAMETER NoClipboard  不写剪贴板，把链接打印到屏幕（可重定向到文件）。
.PARAMETER NoPause      结束时不等待回车（默认在交互式控制台里会等一下，避免右键运行时窗口一闪而过）。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键生成节点.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键生成节点.ps1 -Group B
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键生成节点.ps1 -Group D -ListOnly
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [ValidateSet('ZY', 'A', 'B', 'C', 'D', '')][string]$Group = '',
  [string]$Uuid = '',
  [string]$HostName = 'dfvpn.smjtools.com',
  [string]$Path = '/?ed=2560',
  [switch]$NoTest,
  [ValidateRange(1, 10)][int]$Probes = 3,
  [int]$MaxLatencyMs = 250,
  [switch]$ListOnly,
  [string]$OutFile = '',
  [switch]$NoClipboard,
  [switch]$NoPause,
  [int]$TimeoutMs = 2000
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$Group = $Group.ToUpperInvariant()

# ---------- 内置入口地址（IP:端口#备注；不含凭据） ----------
# 备注中的 SJC / LAX 是 2026-10-18 从管理员网络（中国联通）测得的 Cloudflare 落点机房，
# 其他运营商线路可能不同；脚本会在你的网络里重新测量并排序。
$Groups = [ordered]@{
  'ZY' = @(
    '104.17.157.1:443#ZY-SJC-01', '104.17.152.1:443#ZY-SJC-02', '104.17.150.1:443#ZY-SJC-03', '104.17.151.1:443#ZY-SJC-04',
    '104.17.143.1:443#ZY-SJC-05', '104.17.138.1:443#ZY-SJC-06', '104.17.148.1:443#ZY-SJC-07', '104.17.149.1:443#ZY-SJC-08',
    '104.17.133.1:443#ZY-SJC-09', '104.17.135.1:443#ZY-SJC-10', '172.64.79.1:443#ZY-SJC-11', '162.159.237.1:443#ZY-SJC-12',
    '104.18.57.1:443#ZY-LAX-13', '104.18.55.1:443#ZY-LAX-14', '104.16.0.1:443#ZY-LAX-15', '104.24.0.1:443#ZY-LAX-16'
  )
  'A' = @(
    '104.17.144.1:443#A-SJC-01', '104.17.142.1:443#A-SJC-02', '104.17.141.1:443#A-SJC-03', '104.17.132.1:443#A-SJC-04',
    '104.17.145.1:443#A-SJC-05', '104.17.133.2:443#A-SJC-06', '104.17.137.2:443#A-SJC-07', '104.17.131.2:443#A-SJC-08',
    '104.17.148.2:443#A-SJC-09', '104.18.51.1:443#A-LAX-10', '104.18.60.1:443#A-LAX-11', '104.18.63.1:443#A-LAX-12'
  )
  'B' = @(
    '104.17.147.1:443#B-SJC-01', '104.17.156.1:443#B-SJC-02', '104.17.146.1:443#B-SJC-03', '104.17.134.1:443#B-SJC-04',
    '104.17.153.1:443#B-SJC-05', '104.17.146.2:443#B-SJC-06', '104.17.135.2:443#B-SJC-07', '104.17.156.2:443#B-SJC-08',
    '104.17.136.2:443#B-SJC-09', '104.18.61.1:443#B-LAX-10', '104.18.50.1:443#B-LAX-11', '104.18.49.1:443#B-LAX-12'
  )
  'C' = @(
    '104.17.159.1:443#C-SJC-01', '104.17.155.1:443#C-SJC-02', '104.17.140.1:443#C-SJC-03', '104.17.130.1:443#C-SJC-04',
    '162.159.237.2:443#C-SJC-05', '104.17.130.2:443#C-SJC-06', '104.17.154.2:443#C-SJC-07', '104.17.147.2:443#C-SJC-08',
    '104.17.152.2:443#C-SJC-09', '104.18.53.1:443#C-LAX-10', '104.18.48.1:443#C-LAX-11', '104.19.83.1:443#C-LAX-12'
  )
  'D' = @(
    '104.17.158.1:443#D-SJC-01', '104.17.131.1:443#D-SJC-02', '104.17.139.1:443#D-SJC-03', '104.17.136.1:443#D-SJC-04',
    '104.17.154.1:443#D-SJC-05', '104.17.137.1:443#D-SJC-06', '104.17.128.1:443#D-SJC-07', '104.17.129.1:443#D-SJC-08',
    '104.17.157.2:443#D-SJC-09', '104.17.158.2:443#D-SJC-10', '104.17.151.2:443#D-SJC-11', '104.17.159.2:443#D-SJC-12',
    '104.17.128.2:443#D-SJC-13', '104.17.138.2:443#D-SJC-14', '104.17.139.2:443#D-SJC-15', '104.17.134.2:443#D-SJC-16',
    '104.17.144.2:443#D-SJC-17', '104.17.153.2:443#D-SJC-18', '104.18.59.1:443#D-LAX-19', '104.18.62.1:443#D-LAX-20',
    '104.27.90.1:443#D-LAX-21', '104.18.58.1:443#D-LAX-22', '104.18.7.1:443#D-LAX-23', '104.27.12.1:443#D-LAX-24'
  )
}

function ConvertTo-Entry([string]$Line) {
  if ($Line -notmatch '^\s*(\d{1,3}(?:\.\d{1,3}){3}):(\d+)#(\S+)\s*$') { throw "内置入口格式错误：$Line" }
  return [pscustomobject]@{ Ip = $Matches[1]; Port = [int]$Matches[2]; Remark = $Matches[3]; Median = $null; Max = $null; Loss = 0; Flag = '' }
}

# ---------- 并发 TCP 建连测量（只用 .NET，不需要外部工具） ----------
function Test-TcpBatch {
  param([string[]]$Ips, [int]$Port, [int]$Timeout)
  $items = @()
  foreach ($ip in $Ips) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $t = $c.ConnectAsync($ip, $Port)
    $items += [pscustomobject]@{ Ip = $ip; Client = $c; Task = $t; Sw = $sw; Ms = $null; Done = $false }
  }
  while ($true) {
    $pending = 0
    foreach ($it in $items) {
      if ($it.Done) { continue }
      if ($it.Task.IsCompleted) {
        $it.Sw.Stop(); $it.Done = $true
        if ($it.Task.Status -eq 'RanToCompletion' -and $it.Client.Connected) { $it.Ms = [math]::Round($it.Sw.Elapsed.TotalMilliseconds, 1) }
      } elseif ($it.Sw.ElapsedMilliseconds -gt $Timeout) { $it.Done = $true } else { $pending++ }
    }
    if ($pending -eq 0) { break }
    Start-Sleep -Milliseconds 10
  }
  foreach ($it in $items) { try { $it.Client.Close() } catch { }; try { $it.Client.Dispose() } catch { } }
  return $items | Select-Object Ip, Ms
}

function Get-Median([double[]]$Values) {
  $s = @($Values | Sort-Object); $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] } else { return ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}

# ---------- 1. 组别 ----------
if (-not $Group) {
  $Group = (Read-Host '请输入组别（ZY / A / B / C / D）').Trim().ToUpperInvariant()
  if ($Group -notmatch '^(ZY|[ABCD])$') { throw '组别必须是 ZY、A、B、C 或 D。' }
}
$entries = @($Groups[$Group] | ForEach-Object { ConvertTo-Entry $_ })
if ($entries.Count -eq 0) { throw "组 $Group 没有内置入口。" }
$dup = @($entries | Group-Object Ip | Where-Object { $_.Count -gt 1 })
if ($dup.Count -gt 0) { throw ('内置入口重复：' + (($dup | ForEach-Object { $_.Name }) -join ' ')) }

if ($ListOnly) {
  $entries | ForEach-Object { '{0}:{1}#{2}' -f $_.Ip, $_.Port, $_.Remark }
  return
}

Write-Host ('组 {0}：{1} 个入口，域名 {2}，路径 {3}' -f $Group, $entries.Count, $HostName, $Path) -ForegroundColor Cyan

# ---------- 2. 延迟测量 ----------
if (-not $NoTest) {
  Write-Host ('对每个入口做 {0} 次 TCP 建连测量（超时 {1} ms）…' -f $Probes, $TimeoutMs)
  $samples = @{}
  foreach ($e in $entries) { $samples[$e.Ip] = New-Object System.Collections.Generic.List[double] }
  $byPort = @($entries | Group-Object Port)
  for ($round = 0; $round -lt $Probes; $round++) {
    foreach ($pg in $byPort) {
      foreach ($r in (Test-TcpBatch -Ips @($pg.Group | ForEach-Object { $_.Ip }) -Port ([int]$pg.Name) -Timeout $TimeoutMs)) {
        if ($r.Ms) { $samples[$r.Ip].Add($r.Ms) }
      }
    }
    Start-Sleep -Milliseconds 150
  }
  foreach ($e in $entries) {
    $s = $samples[$e.Ip]
    $e.Loss = $Probes - $s.Count
    if ($s.Count -gt 0) {
      $e.Median = [math]::Round((Get-Median $s.ToArray()))
      $e.Max = [math]::Round(($s | Measure-Object -Maximum).Maximum)
    }
    if ($s.Count -eq 0) { $e.Flag = '不可达' }
    elseif ($e.Median -gt $MaxLatencyMs) { $e.Flag = '慢' }
    elseif ($e.Loss -gt 0) { $e.Flag = '有丢包' }
  }
  $entries = @($entries | Sort-Object @{ Expression = { if ($_.Median -eq $null) { 1 } else { 0 } } }, @{ Expression = { if ($_.Median -gt $MaxLatencyMs) { 1 } else { 0 } } }, Loss, Median)
  Write-Host ''
  Write-Host '测量结果（按延迟排序；中位值即 v2rayN「测试服务器延迟」的预期值）：' -ForegroundColor Yellow
  $entries | Format-Table @{ Label = '备注'; Expression = { $_.Remark } }, @{ Label = '入口'; Expression = { $_.Ip } },
    @{ Label = '中位 ms'; Expression = { $_.Median } }, @{ Label = '最大 ms'; Expression = { $_.Max } },
    @{ Label = '丢包'; Expression = { '{0}/{1}' -f $_.Loss, $Probes } }, @{ Label = '标记'; Expression = { $_.Flag } } -AutoSize | Out-String -Width 120 | Write-Host
  $reach = @($entries | Where-Object { $_.Flag -ne '不可达' })
  $unreach = @($entries | Where-Object { $_.Flag -eq '不可达' })
  if ($reach.Count -eq 0) { throw '本组入口全部不可达：请确认网络正常、443 端口未被 WARP 全隧道或防火墙拦截后重试。' }
  if ($unreach.Count -gt 0) { Write-Warning ('{0} 个入口不可达，已从链接中剔除：{1}' -f $unreach.Count, (($unreach | ForEach-Object { $_.Ip }) -join ' ')) }
  $slow = @($reach | Where-Object { $_.Flag -eq '慢' })
  if ($slow.Count -eq $reach.Count) { Write-Warning ('所有入口的中位延迟都超过 {0} ms。这是你的线路到美西入口的往返时间，换入口帮助有限；若远高于 300 ms，先确认 WARP 没有接管流量。' -f $MaxLatencyMs) }
  $entries = $reach
} else {
  Write-Host '已跳过延迟测量（-NoTest），按内置顺序输出。'
}

# ---------- 3. UUID ----------
if (-not $Uuid -and $env:SMJ_NODE_UUID) { $Uuid = $env:SMJ_NODE_UUID }
if (-not $Uuid) {
  $sec = Read-Host '请输入节点 UUID（不回显；由管理员提供，不是 ADMIN 密码）' -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
  try { $Uuid = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$Uuid = $Uuid.Trim().ToLowerInvariant()
if ($Uuid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') {
  throw 'UUID 格式不正确，需要 UUIDv4（形如 xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx）。它不是 ADMIN 密码，也不是 Cloudflare API Token。'
}

# ---------- 4. 生成链接 ----------
$escapedPath = [Uri]::EscapeDataString($Path)
$links = @($entries | ForEach-Object {
  'vless://{0}@{1}:{2}?security=tls&type=ws&host={3}&fp=chrome&sni={3}&path={4}&encryption=none#{5}' -f $Uuid, $_.Ip, $_.Port, $HostName, $escapedPath, $_.Remark
})
$text = ($links -join "`r`n")
if ($OutFile) {
  $full = $OutFile; if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).ProviderPath $full }; $full = [IO.Path]::GetFullPath($full)
  [IO.File]::WriteAllText($full, $text + "`r`n", (New-Object System.Text.UTF8Encoding $false))
  Write-Host ('链接已写入 {0}（含凭据，勿提交或公开）。' -f $full) -ForegroundColor Yellow
}
if ($NoClipboard) {
  Write-Output $links
} else {
  Set-Clipboard -Value $text
  Write-Host ''
  Write-Host ('已把组 {0} 的 {1} 条节点链接复制到剪贴板。' -f $Group, $links.Count) -ForegroundColor Green
}
Write-Host ''
Write-Host '接下来在 v2rayN 中：'
Write-Host ('  1. 主窗口按 Ctrl+V 导入（备注形如 {0}-SJC-01；可先删除本组旧节点）。' -f $Group)
Write-Host '  2. 全选新节点 → 右键「测试服务器延迟」；「真连接延迟」约 0.8–1.0 s 属正常，受线路往返限制。'
Write-Host '  3. 双击最快的节点启用。'
Write-Host '  4. 节点 Mux 保持关闭；设置 → 参数设置：关闭「TLS 分片」。'
Write-Host '  5. 使用 v2rayN 期间 WARP 不能接管流量：warp-cli disconnect，或 warp-cli mode proxy。'
Write-Host '  链接含访问凭据：不要发到公开渠道，用完可清空剪贴板。'

# 右键「使用 PowerShell 运行」时窗口会在脚本结束后立即关闭，留一个回车让人看完结果。
if (-not $NoClipboard -and -not $NoPause -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
  try { Read-Host '按回车键关闭窗口' | Out-Null } catch { }
}
