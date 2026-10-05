#Requires -Version 5.1
<#
.SYNOPSIS
  一键优化 v2rayN + Cloudflare WARP 同事端：从你自己的网络挑选低延迟 Cloudflare 入口，把它们排除出 WARP 隧道，并生成可直接粘贴进 v2rayN 的节点链接。

.DESCRIPTION
  步骤：
  1) 若 WARP 已连接，先临时断开（脚本结束时自动重连）。不断开的话测到的是 WARP 隧道而不是入口本身。
  2) 对 Cloudflare 公布的全部 IPv4 段，每个 /24 探测一个 IP 的 TCP 建连时间（约 30–60 秒）。
  3) 对前 150 名复测 6 次，剔除有丢包或明显抖动（最大值超过中位数的 1.5 倍 + 30 ms）的。
  4) 对前 36 名用真实 SNI 做 2 次 TLS 连接，确认为本域名服务（HTTP 200）并记录落点机房；任一次 TLS 时间明显超过 2 倍 RTT 的落点视为不稳定，剔除。
  5) 把选中入口所在的 /24 加入 WARP 排除列表（消费者版 WARP 支持；受组织 Zero Trust 管理的设备会失败，脚本会提示改为使用 v2rayN 时断开 WARP）。
  6) 用你输入的 UUID 生成带早数据路径 /?ed=2560 的 vless 链接，复制到剪贴板。UUID 只在内存中使用，不写盘（除非指定 -OutFile）。

  之后在 v2rayN 里：选中你的分组 → Ctrl+V 导入 → 右键「测试服务器延迟」→ 启用最快的节点。

.PARAMETER HostName   Worker 自定义域名，默认 dfvpn.smjtools.com。
.PARAMETER Uuid       节点 UUID；不传则交互式输入（不回显）。
.PARAMETER Top        生成的节点数量，默认 12。
.PARAMETER Prefix     节点备注前缀，默认 CF；备注形如 CF-SJC-01。
.PARAMETER NoWarpChange  不断开 WARP、不添加排除。请自行先关闭 WARP 再运行，否则测量无效。
.PARAMETER ReportOnly 只测量并打印结果：不改 WARP 排除、不询问 UUID、不生成链接（仍会临时断开并重连 WARP）。
.PARAMETER OutFile    额外把链接写入该文件（含凭据，请放在不会提交的位置）。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Optimize-Colleague.ps1
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Optimize-Colleague.ps1 -Prefix B -Top 12
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Optimize-Colleague.ps1 -ReportOnly -NoWarpChange
#>
[CmdletBinding()]
param(
  [string]$HostName = 'dfvpn.smjtools.com',
  [string]$Uuid,
  [int]$Top = 12,
  [string]$Prefix = 'CF',
  [switch]$NoWarpChange,
  [switch]$ReportOnly,
  [string]$OutFile,
  [int]$ScanTimeoutMs = 1500
)

$ErrorActionPreference = 'Stop'
$script:Started = Get-Date

function Write-Step([string]$Text) { Write-Host ("[{0:mm\:ss}] {1}" -f ((Get-Date) - $script:Started), $Text) -ForegroundColor Cyan }

# ---------- Cloudflare 公布的 IPv4 段，每个 /24 取 x.y.z.1 ----------
function Get-CfTargets {
  $ranges = @('173.245.48.0/20', '103.21.244.0/22', '103.22.200.0/22', '103.31.4.0/22', '141.101.64.0/18',
    '108.162.192.0/18', '190.93.240.0/20', '188.114.96.0/20', '197.234.240.0/22', '198.41.128.0/17',
    '162.158.0.0/15', '104.16.0.0/13', '104.24.0.0/14', '172.64.0.0/13', '131.0.72.0/22')
  $list = New-Object System.Collections.Generic.List[string]
  foreach ($r in $ranges) {
    $parts = $r.Split('/'); $bits = [int]$parts[1]
    $b = [System.Net.IPAddress]::Parse($parts[0]).GetAddressBytes(); [Array]::Reverse($b)
    $start = [BitConverter]::ToUInt32($b, 0)
    $count = [int]([math]::Pow(2, 32 - $bits) / 256)
    for ($i = 0; $i -lt $count; $i++) {
      $v = [uint32]($start + ($i * 256) + 1)
      $bb = [BitConverter]::GetBytes($v); [Array]::Reverse($bb)
      $list.Add((New-Object System.Net.IPAddress(, $bb)).ToString())
    }
  }
  return , $list.ToArray()
}

# ---------- 并发 TCP 建连探测（无需外部工具） ----------
function Test-TcpBatch {
  param([string[]]$Ips, [int]$TimeoutMs)
  $items = @()
  foreach ($ip in $Ips) {
    $c = New-Object System.Net.Sockets.TcpClient
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $t = $c.ConnectAsync($ip, 443)
    $items += [pscustomobject]@{ Ip = $ip; Client = $c; Task = $t; Sw = $sw; Ms = $null; Done = $false }
  }
  while ($true) {
    $pending = 0
    foreach ($it in $items) {
      if ($it.Done) { continue }
      if ($it.Task.IsCompleted) {
        $it.Sw.Stop(); $it.Done = $true
        if ($it.Task.Status -eq 'RanToCompletion' -and $it.Client.Connected) { $it.Ms = [math]::Round($it.Sw.Elapsed.TotalMilliseconds, 1) }
      } elseif ($it.Sw.ElapsedMilliseconds -gt $TimeoutMs) { $it.Done = $true } else { $pending++ }
    }
    if ($pending -eq 0) { break }
    Start-Sleep -Milliseconds 10
  }
  foreach ($it in $items) { try { $it.Client.Close() } catch {}; try { $it.Client.Dispose() } catch {} }
  return $items | Select-Object Ip, Ms
}

function Get-Median([double[]]$Values) {
  $s = $Values | Sort-Object; $n = $s.Count
  if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] } else { return ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}

# ---------- 用真实 SNI 验证入口为本域名服务，并读出落点机房 ----------
function Test-Colo([string]$Ip) {
  $out = & curl.exe -s --noproxy '*' -m 6 --resolve "${HostName}:443:${Ip}" -w "`n%{time_connect} %{time_appconnect} %{http_code}" "https://${HostName}/cdn-cgi/trace" 2>$null
  $lines = @((@($out) -join "`n") -split "`n"); $last = $lines[-1].Trim().Split(' ')
  $colo = (($lines | Where-Object { $_ -match '^colo=' } | Select-Object -First 1) -replace '^colo=', '')
  if (-not $colo) { $colo = '-' }
  $tcp = 0.0; $tls = 0.0
  [void][double]::TryParse($last[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tcp)
  if ($last.Count -gt 1) { [void][double]::TryParse($last[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tls) }
  $code = if ($last.Count -gt 2) { $last[2] } else { '000' }
  return [pscustomobject]@{ Ip = $Ip; CurlTcp = $tcp; Tls = $tls; Code = $code; Colo = $colo }
}

# ---------- WARP ----------
$warpExe = $null
$cmd = Get-Command warp-cli -ErrorAction SilentlyContinue
if ($cmd) { $warpExe = $cmd.Source } elseif (Test-Path 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe') { $warpExe = 'C:\Program Files\Cloudflare\Cloudflare WARP\warp-cli.exe' }
function Get-WarpStatus { if ($warpExe) { try { return (& $warpExe status 2>$null | Select-Object -First 1) } catch { return '' } } else { return '' } }

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw '未找到 curl.exe（Windows 10 1803 以上自带）。' }

$warpWasConnected = $false
$warpStatus = Get-WarpStatus
if ($warpExe) { Write-Step "检测到 Cloudflare WARP：$warpStatus" } else { Write-Step '未检测到 Cloudflare WARP 客户端，跳过 WARP 相关步骤。' }
if ($warpExe -and $warpStatus -match 'Connected' -and $warpStatus -notmatch 'Disconnected') {
  $warpWasConnected = $true
  if ($NoWarpChange) {
    Write-Warning 'WARP 处于连接状态且指定了 -NoWarpChange：未被排除的入口将经 WARP 隧道测量，结果不代表直连。'
  } else {
    Write-Step '临时断开 WARP 以便测量直连延迟（结束时自动重连）…'
    & $warpExe disconnect | Out-Null
    for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if ((Get-WarpStatus) -match 'Disconnected') { break } }
    if ((Get-WarpStatus) -notmatch 'Disconnected') { Write-Warning 'WARP 未能断开（可能受组织策略锁定）。本次测量将经过隧道；请手动关闭 WARP 后重跑。' }
    else { Start-Sleep -Seconds 2 }
  }
}

try {
  # ---------- 1. 全量扫描 ----------
  $targets = Get-CfTargets
  Write-Step ("扫描 {0} 个 /24 段（每段 1 个 IP，TCP 443）…" -f $targets.Count)
  $first = @{}
  $batchSize = 256
  for ($i = 0; $i -lt $targets.Count; $i += $batchSize) {
    $end = [math]::Min($i + $batchSize - 1, $targets.Count - 1)
    foreach ($r in (Test-TcpBatch -Ips $targets[$i..$end] -TimeoutMs $ScanTimeoutMs)) { if ($r.Ms) { $first[$r.Ip] = $r.Ms } }
    Write-Progress -Activity '扫描 Cloudflare 入口' -Status ("{0}/{1}，已可达 {2}" -f ($end + 1), $targets.Count, $first.Count) -PercentComplete ((($end + 1) * 100) / $targets.Count)
  }
  Write-Progress -Activity '扫描 Cloudflare 入口' -Completed
  if ($first.Count -eq 0) { throw '没有任何入口可达：请检查网络，或 WARP/防火墙是否拦截了 443 端口。' }
  $hist = $first.Values | Group-Object { [int][math]::Floor($_ / 25) * 25 } | Sort-Object { [int]$_.Name } | ForEach-Object { "{0}ms:{1}" -f $_.Name, $_.Count }
  Write-Step ("可达 {0} 段；TCP 建连分布 → {1}" -f $first.Count, ($hist -join '  '))

  # ---------- 2. 稳定性复测 ----------
  $top150 = @($first.GetEnumerator() | Sort-Object Value | Select-Object -First 150 | ForEach-Object { $_.Key })
  Write-Step ("对最快的 {0} 个入口复测 6 次…" -f $top150.Count)
  $samples = @{}; foreach ($ip in $top150) { $samples[$ip] = New-Object System.Collections.Generic.List[double] }
  for ($round = 0; $round -lt 6; $round++) {
    foreach ($r in (Test-TcpBatch -Ips $top150 -TimeoutMs 2000)) { if ($r.Ms) { $samples[$r.Ip].Add($r.Ms) } }
    Start-Sleep -Milliseconds 200
  }
  $stable = foreach ($ip in $top150) {
    $s = $samples[$ip]
    if ($s.Count -eq 6) { [pscustomobject]@{ Ip = $ip; Median = Get-Median $s.ToArray(); Max = ($s | Measure-Object -Maximum).Maximum } }
  }
  $stable = @($stable | Sort-Object Median)
  Write-Step ("0 丢包的入口 {0} 个；最低 TCP 中位数 {1} ms" -f $stable.Count, $stable[0].Median)

  # ---------- 3. TLS / 落点验证 ----------
  $cands = @($stable | Select-Object -First 36)
  Write-Step ("对前 {0} 个入口各做 2 次 TLS 握手与落点验证…" -f $cands.Count)
  $verified = foreach ($c in $cands) {
    $v1 = Test-Colo $c.Ip; $v2 = Test-Colo $c.Ip
    $tls = [math]::Max($v1.Tls, $v2.Tls)
    $code = if ($v1.Code -eq '200' -and $v2.Code -eq '200') { '200' } else { "$($v1.Code)/$($v2.Code)" }
    $colo = if ($v1.Colo -ne '-') { $v1.Colo } else { $v2.Colo }
    $reason = ''
    if ($code -ne '200') { $reason = "HTTP $code，不为本域名服务或不稳定" }
    elseif ($c.Max -gt ($c.Median * 1.5 + 30)) { $reason = 'TCP 抖动/重传，落点不稳定' }
    elseif ($tls -gt (2.6 * $c.Median / 1000 + 0.08)) { $reason = 'TLS 耗时远超 2×RTT，落点不稳定' }
    [pscustomobject]@{ Ip = $c.Ip; Colo = $colo; TcpMedianMs = [math]::Round($c.Median); TcpMaxMs = [math]::Round($c.Max); TlsMaxSec = [math]::Round($tls, 3); Code = $code; Reject = $reason }
  }
  $verified = @($verified)
  $good = @($verified | Where-Object { -not $_.Reject } | Sort-Object { ($_.TcpMedianMs + $_.TcpMaxMs) / 2 })
  Write-Host ''
  Write-Host '验证结果（按 TCP 中位数排序；Reject 为空的为可用入口）：' -ForegroundColor Yellow
  $verified | Sort-Object TcpMedianMs | Format-Table Ip, Colo, TcpMedianMs, TcpMaxMs, TlsMaxSec, Code, Reject -AutoSize | Out-String -Width 160 | Write-Host
  if ($good.Count -eq 0) { throw '没有通过验证的入口。' }
  $chosen = @($good | Select-Object -First $Top)
  Write-Step ("选中 {0} 个入口，落点分布：{1}" -f $chosen.Count, (($chosen | Group-Object Colo | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join ' '))
}
finally {
  if ($warpWasConnected -and -not $NoWarpChange -and $warpExe) {
    Write-Step '重新连接 WARP…'
    & $warpExe connect | Out-Null
    for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 1; $s = Get-WarpStatus; if ($s -match 'Connected' -and $s -notmatch 'Disconnected') { break } }
    Write-Step ("WARP 状态：{0}" -f (Get-WarpStatus))
  }
}

# ---------- 4. WARP 排除 ----------
$warpExcludeOk = $true
if ($warpExe -and -not $NoWarpChange -and -not $ReportOnly) {
  Write-Step '把选中入口所在 /24 加入 WARP 排除列表…'
  foreach ($cidr in ($chosen | ForEach-Object { ($_.Ip -replace '\.\d+$', '.0') + '/24' } | Select-Object -Unique)) {
    $r = (& $warpExe tunnel ip add-range $cidr 2>&1 | Out-String).Trim()
    if ($r -match 'Success') { Write-Host "  $cidr  已排除" } else { $warpExcludeOk = $false; Write-Warning "  $cidr  失败：$r" }
  }
  if (-not $warpExcludeOk) { Write-Warning '部分排除失败：通常是设备受组织 Zero Trust 策略管理。替代办法：使用 v2rayN 期间断开 WARP，或请管理员在 Split Tunnels 中排除上述网段。' }
  else { Write-Host '  可用 warp-cli tunnel ip list 查看，warp-cli tunnel ip remove-range <网段> 撤销。' }
} elseif ($warpExe) {
  Write-Host '已跳过 WARP 排除（-NoWarpChange 或 -ReportOnly）。请记住：使用 v2rayN 时 WARP 必须断开，或手动排除上述网段。' -ForegroundColor Yellow
}

# ---------- 5. 生成链接 ----------
if (-not $ReportOnly) {
  if (-not $Uuid) {
    $sec = Read-Host '请输入节点 UUID（不回显，来自管理员或后台）' -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $Uuid = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  }
  if ($Uuid -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$') { throw 'UUID 格式不正确，需要 UUIDv4；它不是 ADMIN 密码，也不是 Cloudflare API Token。' }
  $n = 0
  $links = foreach ($c in $chosen) {
    $n++
    'vless://{0}@{1}:443?security=tls&type=ws&host={2}&fp=chrome&sni={2}&path=%2F%3Fed%3D2560&encryption=none#{3}-{4}-{5:d2}' -f $Uuid, $c.Ip, $HostName, $Prefix, $c.Colo, $n
  }
  $text = ($links -join "`r`n")
  Set-Clipboard -Value $text
  if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $text -Encoding UTF8; Write-Host "链接已写入 $OutFile（含凭据，勿提交或公开）。" -ForegroundColor Yellow }
  Write-Host ''
  Write-Host ("已把 {0} 条节点链接复制到剪贴板。" -f $links.Count) -ForegroundColor Green
  Write-Host @"

接下来在 v2rayN 中：
  1. 选中你的订阅分组，按 Ctrl+V 导入（新节点备注形如 $Prefix-<落点>-01）。
  2. 全选新节点 → 右键「测试服务器延迟」(tcping)，预期约 $([math]::Round($chosen[0].TcpMedianMs))–$([math]::Round($chosen[-1].TcpMedianMs)) ms；「真连接延迟」约为 4 倍 RTT，这是物理下限。
  3. 双击最快的节点启用；删除旧的高延迟节点。
  4. 设置 → 参数设置：关闭「TLS 分片」；节点里 Mux 保持关闭。
  5. 使用 v2rayN 期间 WARP 必须断开，或已按上面排除入口网段。
"@
}
else {
  Write-Host ''
  Write-Host '推荐入口（ReportOnly）：' -ForegroundColor Green
  $chosen | Format-Table Ip, Colo, TcpMedianMs, TcpMaxMs, TlsMaxSec -AutoSize | Out-String | Write-Host
}
Write-Step '完成。'
