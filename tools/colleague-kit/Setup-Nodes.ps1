<#
.SYNOPSIS
  同事一键配置（Windows）：在你自己的网络里挑出到 Cloudflare 入口延迟最低、落点在美国的地址，
  生成 v2rayN 节点链接，并验证出口在美国。只依赖 Windows 自带的 PowerShell 5.1 与 curl.exe。

.DESCRIPTION
  依次执行：
    1. 环境检查：curl.exe、Cloudflare One (WARP) 客户端、v2rayN、xray 核心。
    2. WARP 适配：WARP 未安装 / 已断开 / 代理模式 都不用动；只有「全隧道模式且已连接」才切到代理模式
       （warp-cli mode proxy，持久生效，可用 warp-cli mode warp 改回）。切不动（受组织策略管理）时，
       测量期间临时断开，结束后重连并把选中入口网段加入 WARP 排除列表。
    3. 扫描：对 Cloudflare 公布的全部 IPv4 段每个 /24 探测一个 IP 的 TCP 建连时间（约 1 分钟）。
    4. 复测：对最快的 150 个各做 6 次，剔除丢包和重传抖动的。
    5. 验证：按延迟顺序分批（每批 40 个，最多 120 个）用真实 SNI 做 2 次 TLS 连接，必须 HTTP 200、落点机房在美国、
       TLS 耗时约 2×RTT，直到找够 -Top 个；
       对最终入选的入口再做一次 WebSocket 握手，必须返回 101 且未被安全质询。
    6. 选取：中位延迟低于 -MaxLatencyMs（默认 200 ms）的入口，最多 -Top 个；不足 -MinNodes 个时改为生成最快的
       美国落点入口并标记 PARTIAL；没有任何美国落点入口通过验证则 FAIL。
    7. 链接：输入节点 UUID（不回显，只在内存中使用），生成 VLESS / WebSocket / TLS 链接（路径 /?ed=2560），
       复制到剪贴板并写入 %LOCALAPPDATA%\smj-proxy\nodes.txt。找得到 xray 核心时，先用临时 xray 实例
       对最快入口做真连接延迟与出口国家检查。
    8. 导入后验证：你在 v2rayN 中 Ctrl+V 导入并启用最快节点后按回车，脚本经 127.0.0.1:10808 检查出口国家
       必须是 US，并测 3 次真连接延迟。
  结果写入 %LOCALAPPDATA%\smj-proxy\setup-nodes.log，最后一行是 RESULT: OK / PARTIAL / FAIL。
  脚本不含任何凭据，不改动 v2rayN 的配置与系统代理。

.PARAMETER Uuid          节点 UUID（UUIDv4）。不传时依次尝试环境变量 SMJ_NODE_UUID、脚本同目录的 uuid.txt、交互输入。
.PARAMETER Prefix        节点备注前缀，默认 CF；备注形如 CF-SJC-01。管理员分配了组别时用 -Prefix B。
.PARAMETER Top           最多生成的节点数，默认 12。
.PARAMETER MaxLatencyMs  入口中位延迟上限，默认 200。
.PARAMETER MinNodes      至少要有多少个达标入口才算 OK，默认 3。
.PARAMETER WarpPolicy    proxy（默认，全隧道时切代理模式）/ disconnect（全隧道时断开）/ keep（不动 WARP，只提示）。
.PARAMETER ReportOnly    只测量并打印结果，不问 UUID、不生成链接、不做导入后验证。
.PARAMETER NoVerify      生成链接后不等待导入验证。
.PARAMETER NoClipboard   不写剪贴板，链接打印到屏幕。
.PARAMETER OutFile       链接另存到该文件（含凭据）。默认写到 %LOCALAPPDATA%\smj-proxy\nodes.txt。
.PARAMETER NoPause       结束时不等待回车。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Nodes.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Nodes.ps1 -Prefix B -Top 12
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Setup-Nodes.ps1 -ReportOnly
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$HostName = 'dfvpn.smjtools.com',
  [string]$Path = '/?ed=2560',
  [string]$Uuid = '',
  [string]$Prefix = 'CF',
  [int]$Top = 12,
  [int]$MaxLatencyMs = 200,
  [int]$MinNodes = 3,
  [int]$ProxyPort = 10808,
  [ValidateSet('proxy', 'disconnect', 'keep')][string]$WarpPolicy = 'proxy',
  [switch]$ReportOnly,
  [switch]$NoVerify,
  [switch]$NoClipboard,
  [string]$OutFile = '',
  [string]$V2rayNPath = '',
  [int]$ScanTimeoutMs = 1500,
  [switch]$NoPause
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$script:Started = Get-Date
$script:LogDir = Join-Path $env:LOCALAPPDATA 'smj-proxy'
$script:LogFile = Join-Path $script:LogDir 'setup-nodes.log'
$script:Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $script:Curl)) { $script:Curl = 'curl.exe' }
$script:Problems = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:WarpCli = $null
$script:WarpReconnect = $false
$script:WarpNeedExclude = $false
# Cloudflare 在美国的机房代码（cdn-cgi/trace 的 colo）。不在表内的落点一律不选，日志里会显示实际 colo。
$script:UsColos = @('ABQ', 'ALB', 'ANC', 'ATL', 'AUS', 'BGR', 'BNA', 'BOS', 'BUF', 'CLE', 'CLT', 'CMH', 'DEN', 'DFW', 'DTW', 'ELP', 'EWR',
  'FSD', 'GEG', 'HNL', 'IAD', 'IAH', 'IND', 'JAX', 'LAS', 'LAX', 'LBB', 'MCI', 'MEM', 'MFE', 'MIA', 'MSP', 'OKC', 'OMA', 'ORD', 'ORF',
  'PDX', 'PHL', 'PHX', 'PIT', 'RDU', 'RIC', 'RNO', 'SAN', 'SAT', 'SEA', 'SFO', 'SJC', 'SLC', 'SMF', 'STL', 'TLH', 'TPA')

function Write-Log {
  param([string]$Message, [string]$Level = 'INFO')
  $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
  try {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) { Move-Item $script:LogFile ($script:LogFile + '.1') -Force }
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
  } catch { }
  switch ($Level) {
    'WARN' { Write-Host $line -ForegroundColor Yellow }
    'FAIL' { Write-Host $line -ForegroundColor Red }
    default { Write-Host $line }
  }
}
function Write-Step([string]$Text) { Write-Host ''; Write-Host ('==== [{0:mm\:ss}] {1} ====' -f ((Get-Date) - $script:Started), $Text) -ForegroundColor Cyan; Write-Log ('---- ' + $Text) }
function Add-Problem([string]$Text) { $script:Problems.Add($Text); Write-Log $Text 'FAIL' }
function Add-Warning([string]$Text) { $script:Warnings.Add($Text); Write-Log $Text 'WARN' }

function Invoke-Curl {
  param([string[]]$Arguments)
  $ErrorActionPreference = 'Continue'
  try { $out = & $script:Curl @Arguments 2>$null; if ($LASTEXITCODE -ne 0 -and -not $out) { return $null }; return (@($out) -join "`n") } catch { return $null }
}

function Test-TcpPort {
  param([string]$Address, [int]$Port, [int]$TimeoutMs = 1500)
  $client = New-Object System.Net.Sockets.TcpClient
  try { $ar = $client.BeginConnect($Address, $Port, $null, $null); return ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) } catch { return $false } finally { $client.Close() }
}

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

# ---------- 并发 TCP 建连探测（只用 .NET） ----------
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
  foreach ($it in $items) { try { $it.Client.Close() } catch { }; try { $it.Client.Dispose() } catch { } }
  return $items | Select-Object Ip, Ms
}

function Get-Median([double[]]$Values) {
  $s = @($Values | Sort-Object); $n = $s.Count
  if ($n -eq 0) { return $null }
  if ($n % 2 -eq 1) { return $s[[int](($n - 1) / 2)] } else { return ($s[$n / 2 - 1] + $s[$n / 2]) / 2 }
}

# ---------- 真实 SNI 的 TLS 连接：HTTP 状态、落点机房、TCP/TLS 耗时 ----------
function Test-Colo([string]$Ip) {
  $ErrorActionPreference = 'Continue'
  $out = $null
  try { $out = & $script:Curl -s --noproxy '*' -m 6 --resolve "${HostName}:443:${Ip}" -w "`n%{time_connect} %{time_appconnect} %{http_code}" "https://${HostName}/cdn-cgi/trace" 2>$null } catch { }
  $lines = @((@($out) -join "`n") -split "`n"); $last = $lines[-1].Trim().Split(' ')
  $colo = (($lines | Where-Object { $_ -match '^colo=' } | Select-Object -First 1) -replace '^colo=', '')
  if (-not $colo) { $colo = '-' }
  $tcp = 0.0; $tls = 0.0
  [void][double]::TryParse($last[0], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tcp)
  if ($last.Count -gt 1) { [void][double]::TryParse($last[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$tls) }
  $code = '000'; if ($last.Count -gt 2) { $code = $last[2] }
  return [pscustomobject]@{ Ip = $Ip; Tcp = $tcp; Tls = $tls; Code = $code; Colo = $colo }
}

# ---------- WebSocket 升级握手：必须 101，且没有 cf-mitigated 质询头 ----------
function Test-WebSocket([string]$Ip) {
  # 握手成功后 curl 会等到 --max-time 才以退出码 28 结束，属正常；用 -s 避免它把超时信息写到 stderr
  $ErrorActionPreference = 'Continue'
  $out = $null
  try { $out = & $script:Curl --http1.1 --noproxy '*' --max-time 3 -s -o NUL -D - --resolve "${HostName}:443:${Ip}" -H 'Connection: Upgrade' -H 'Upgrade: websocket' -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "https://${HostName}/" 2>$null } catch { }
  $text = (@($out) -join "`n")
  $status = '000'; if ($text -match 'HTTP/\S+\s+(\d{3})') { $status = $Matches[1] }
  $mitigated = ''; if ($text -match '(?im)^cf-mitigated:\s*(\S+)') { $mitigated = $Matches[1] }
  return [pscustomobject]@{ Ip = $Ip; Status = $status; Mitigated = $mitigated }
}

# ---------- v2rayN / xray / WARP ----------
function Find-V2rayN {
  if ($V2rayNPath -and (Test-Path $V2rayNPath)) { return $V2rayNPath }
  $candidates = @()
  try { $p = Get-Process v2rayN -ErrorAction SilentlyContinue | Select-Object -First 1; if ($p -and $p.Path) { $candidates += $p.Path } } catch { }
  $candidates += @((Join-Path ($env:SystemDrive + '\') 'tools\v2rayN-windows-64\v2rayN.exe'), (Join-Path $env:ProgramFiles 'v2rayN\v2rayN.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\v2rayN\v2rayN.exe'), (Join-Path $env:USERPROFILE 'Desktop\v2rayN-windows-64\v2rayN.exe'),
    (Join-Path $env:USERPROFILE 'Downloads\v2rayN-windows-64\v2rayN.exe'))
  foreach ($root in (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root -Unique)) { $candidates += Join-Path $root 'tools\v2rayN-windows-64\v2rayN.exe' }
  foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}
function Get-WarpCli {
  $c = Get-Command warp-cli -ErrorAction SilentlyContinue; if ($c) { return $c.Source }
  $p = Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'; if (Test-Path $p) { return $p }
  return $null
}
function Invoke-Warp([string[]]$Arguments) { try { $o = & $script:WarpCli @Arguments 2>&1; return (@($o) -join "`n") } catch { return '' } }
function Get-RouteInterface([string]$Ip) {
  try { $r = Find-NetRoute -RemoteIPAddress $Ip -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias } | Select-Object -First 1; if ($r) { return $r.InterfaceAlias } } catch { }
  return ''
}
function Get-WarpState {
  $settings = Invoke-Warp @('settings'); $status = Invoke-Warp @('status'); $reg = Invoke-Warp @('registration', 'show')
  $mode = 'unknown'; if ($settings -match 'Mode:\s*(\S+)') { $mode = $Matches[1] }
  return [pscustomobject]@{
    Mode = $mode
    Connected = [bool]($status -match 'Status update:\s*Connected')
    Managed = (($settings -match 'Daemon Teams Auth:\s*true') -or ($reg -match 'Organization|Account type:\s*Team'))
    TunnelMode = ($mode -notmatch 'proxy|dns|doh|dot')
  }
}

function Step-Warp {
  $script:WarpCli = Get-WarpCli
  if (-not $script:WarpCli) { Write-Log '未安装 Cloudflare One / WARP 客户端：无需处理'; return }
  $s = Get-WarpState
  $iface = Get-RouteInterface '104.16.0.1'
  $connText = '未连接'; if ($s.Connected) { $connText = '已连接' }
  $mText = ''; if ($s.Managed) { $mText = '，由组织策略管理' }
  Write-Log ('WARP 模式 {0}，{1}{2}；到 Cloudflare 入口的路由接口：{3}' -f $s.Mode, $connText, $mText, $iface)
  $hijack = ($s.Connected -and $s.TunnelMode) -or ($iface -match 'WARP')
  if (-not $hijack) { Write-Log 'WARP 没有接管直连流量（未连接或代理/DNS 模式），测量与节点都不受影响'; return }
  if ($WarpPolicy -eq 'keep') { Add-Problem 'WARP 正在以全隧道模式接管流量（-WarpPolicy keep 未改动）：测出来的是 WARP 隧道延迟，节点也会经隧道。请改用 warp-cli mode proxy 或断开后重跑'; return }
  if (-not $s.Managed -and $WarpPolicy -eq 'proxy') {
    $r = Invoke-Warp @('mode', 'proxy'); Write-Log ('执行 warp-cli mode proxy：{0}' -f (($r -replace '\s+', ' ').Trim()))
    Start-Sleep -Seconds 4
    $iface = Get-RouteInterface '104.16.0.1'
    if ($iface -notmatch 'WARP') { Write-Log ('WARP 已切到代理模式（持久生效，warp-cli mode warp 可改回）；直连现经 {0}' -f $iface); return }
    Add-Warning '切换代理模式后路由仍经 WARP，改为测量期间临时断开'
  }
  # 受组织策略管理，或切模式无效，或 -WarpPolicy disconnect：测量期间断开，结束时重连并添加排除
  $r = Invoke-Warp @('disconnect'); Write-Log ('执行 warp-cli disconnect：{0}' -f (($r -replace '\s+', ' ').Trim()))
  for ($i = 0; $i -lt 15; $i++) { Start-Sleep -Seconds 1; if (-not (Get-WarpState).Connected) { break } }
  if ((Get-WarpState).Connected) { Add-Problem 'WARP 无法断开（受组织策略锁定）：请管理员在 Zero Trust 的 Split Tunnels 中排除 Cloudflare 入口网段，或使用 v2rayN 时手动关闭 WARP 后重跑'; return }
  $script:WarpReconnect = $true; $script:WarpNeedExclude = $true
  Write-Log 'WARP 已临时断开，脚本结束时会重连，并把选中入口的 /24 加入 WARP 排除列表'
}

function Restore-Warp([string[]]$ChosenIps) {
  if (-not $script:WarpCli -or -not $script:WarpReconnect) { return }
  if ($script:WarpNeedExclude -and $ChosenIps) {
    $ok = $true
    foreach ($cidr in ($ChosenIps | ForEach-Object { ($_ -replace '\.\d+$', '.0') + '/24' } | Select-Object -Unique)) {
      $r = (Invoke-Warp @('tunnel', 'ip', 'add-range', $cidr)).Trim()
      if ($r -match 'Success') { Write-Log ('WARP 排除 {0}：已添加' -f $cidr) } else { $ok = $false; Write-Log ('WARP 排除 {0} 失败：{1}' -f $cidr, $r) 'WARN' }
    }
    if (-not $ok) { Add-Warning 'WARP 排除列表添加失败（通常是组织策略）：使用 v2rayN 期间请断开 WARP，或请管理员在 Split Tunnels 中排除上述网段' }
  }
  Invoke-Warp @('connect') | Out-Null
  for ($i = 0; $i -lt 20; $i++) { Start-Sleep -Seconds 1; if ((Get-WarpState).Connected) { break } }
  Write-Log ('WARP 已重连：{0}' -f (Invoke-Warp @('status') -split "`n" | Select-Object -First 1))
}

function Get-FreePort { for ($p = 10905; $p -lt 10999; $p++) { if (-not (Test-TcpPort '127.0.0.1' $p 200)) { return $p } }; return 10905 }

# 用临时 xray 实例对一个入口做真连接延迟 + 出口国家检查（导入前）
function Test-ViaXray([string]$XrayExe, [string]$Ip, [string]$NodeUuid) {
  $port = Get-FreePort
  $cfg = [IO.Path]::GetTempFileName() + '.json'
  $json = @{ log = @{ loglevel = 'error' }
    inbounds = @(@{ port = $port; listen = '127.0.0.1'; protocol = 'socks'; settings = @{ udp = $false } })
    outbounds = @(@{ protocol = 'vless'; settings = @{ vnext = @(@{ address = $Ip; port = 443; users = @(@{ id = $NodeUuid; encryption = 'none' }) }) }
        streamSettings = @{ network = 'ws'; security = 'tls'; tlsSettings = @{ serverName = $HostName; fingerprint = 'chrome' }; wsSettings = @{ path = $Path; host = $HostName } } })
  } | ConvertTo-Json -Depth 8
  [IO.File]::WriteAllText($cfg, $json, (New-Object System.Text.UTF8Encoding $false))
  $proc = $null
  try {
    $proc = Start-Process -FilePath $XrayExe -ArgumentList @('run', '-c', ('"' + $cfg + '"')) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $proxy = 'socks5h://127.0.0.1:{0}' -f $port
    $times = @()
    for ($i = 0; $i -lt 3; $i++) {
      $t = Invoke-Curl @('--proxy', $proxy, '-s', '-o', 'NUL', '--max-time', '12', '-w', '%{http_code} %{time_total}', 'https://www.google.com/generate_204')
      if ($t -match '^204 ([\d.]+)') { $times += [double]$Matches[1] }
    }
    $country = ''; $desc = ''
    $g = Invoke-Curl @('--proxy', $proxy, '-s', '--max-time', '15', '-A', 'Mozilla/5.0', 'https://api.ip.sb/geoip')
    if ($g) { try { $o = $g | ConvertFrom-Json; if ($o.country_code) { $country = $o.country_code; $desc = '{0} {1}, {2}' -f $o.ip, $o.city, $o.country } } catch { } }
    if (-not $country) { $tr = Invoke-Curl @('--proxy', $proxy, '-s', '--max-time', '15', 'https://www.cloudflare.com/cdn-cgi/trace'); if ($tr -match 'loc=(\w+)') { $country = $Matches[1]; $desc = 'cloudflare trace' } }
    return [pscustomobject]@{ Times = $times; Country = $country; Desc = $desc }
  } finally {
    if ($proc) { try { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } catch { } }
    Remove-Item $cfg -Force -ErrorAction SilentlyContinue
  }
}

# 经 v2rayN 本地代理检查出口国家与真连接延迟（导入后）
function Test-ViaLocalProxy {
  if (-not (Test-TcpPort '127.0.0.1' $ProxyPort 1500)) { Add-Problem ('127.0.0.1:{0} 没有在监听：v2rayN 未运行，或本地端口不是 {0}（可用 -ProxyPort 指定）' -f $ProxyPort); return $false }
  $proxy = 'http://127.0.0.1:{0}' -f $ProxyPort
  $country = ''; $desc = ''
  $g = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', '-A', 'Mozilla/5.0', 'https://api.ip.sb/geoip')
  if ($g) { try { $o = $g | ConvertFrom-Json; if ($o.country_code) { $country = $o.country_code; $desc = '{0} {1}, {2} (ip.sb)' -f $o.ip, $o.city, $o.country } } catch { } }
  if (-not $country) { $tr = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', 'https://www.cloudflare.com/cdn-cgi/trace'); if ($tr -match 'loc=(\w+)') { $country = $Matches[1]; $colo = '?'; if ($tr -match 'colo=(\w+)') { $colo = $Matches[1] }; $desc = 'colo {0} (cloudflare trace)' -f $colo } }
  if (-not $country) { Add-Problem '经 v2rayN 代理无法访问外网：节点未启用、不可用，或系统代理端口不对'; return $false }
  if ($country -ne 'US') { Add-Problem ('出口不在美国：{0} {1}。请在 v2rayN 里启用刚导入的节点（备注 {2}-…）' -f $country, $desc, $Prefix); return $false }
  Write-Log ('出口 US：{0}' -f $desc)
  $times = @()
  for ($i = 0; $i -lt 3; $i++) {
    $t = Invoke-Curl @('--proxy', $proxy, '-sS', '-o', 'NUL', '--max-time', '15', '-w', '%{http_code} %{time_total}', 'https://www.google.com/generate_204')
    if ($t -match '^204 ([\d.]+)') { $times += [double]$Matches[1] }
  }
  if ($times.Count -gt 0) { Write-Log ('真连接延迟（经 v2rayN，3 次）：{0} s；受线路往返限制，正常 0.8–1.2 s' -f (($times | ForEach-Object { '{0:N2}' -f $_ }) -join ' / ')) } else { Add-Warning '真连接延迟测试失败（google generate_204 经代理不可达）' }
  return $true
}

# ================= 主流程 =================
Write-Log ('==== setup-nodes 开始（用户 {0}，主机 {1}，PowerShell {2}）====' -f $env:USERNAME, $env:COMPUTERNAME, $PSVersionTable.PSVersion)
$chosen = @()
$resultLevel = 'FAIL'
try {
  Write-Step '1/6 环境检查'
  if (-not (Test-Path $script:Curl) -and -not (Get-Command curl.exe -ErrorAction SilentlyContinue)) { throw '未找到 curl.exe（Windows 10 1803 以上自带）。' }
  Write-Log ('curl：{0}' -f $script:Curl)
  $v2exe = Find-V2rayN
  $v2run = @(Get-Process v2rayN -ErrorAction SilentlyContinue).Count
  if ($v2exe) { Write-Log ('v2rayN：{0}（运行中实例 {1} 个）' -f $v2exe, $v2run) } else { Add-Warning 'v2rayN 未找到：脚本仍会生成链接，但导入前的 xray 检查会跳过；可用 -V2rayNPath 指定 v2rayN.exe' }
  $xray = $null
  if ($v2exe) { $x = Join-Path (Split-Path $v2exe) 'bin\xray\xray.exe'; if (Test-Path $x) { $xray = $x; Write-Log ('xray 核心：{0}' -f $xray) } else { Add-Warning ('未找到 xray 核心（{0}）：导入前的真连接检查会跳过' -f $x) } }
  if ($env:HTTP_PROXY -or $env:HTTPS_PROXY -or $env:ALL_PROXY) { Write-Log '检测到环境变量代理设置，直连探测已显式绕过（--noproxy）' }

  Write-Step '2/6 Cloudflare One / WARP 适配'
  Step-Warp
  if ($script:Problems.Count -gt 0) { throw ('WARP 未处理完成：' + ($script:Problems -join '；')) }

  Write-Step '3/6 扫描 Cloudflare 入口（每个 /24 一个 IP，TCP 443）'
  $targets = Get-CfTargets
  Write-Log ('目标 {0} 个 /24 段，超时 {1} ms' -f $targets.Count, $ScanTimeoutMs)
  $first = @{}
  $batchSize = 256
  for ($i = 0; $i -lt $targets.Count; $i += $batchSize) {
    $end = [math]::Min($i + $batchSize - 1, $targets.Count - 1)
    foreach ($r in (Test-TcpBatch -Ips $targets[$i..$end] -TimeoutMs $ScanTimeoutMs)) { if ($r.Ms) { $first[$r.Ip] = $r.Ms } }
    Write-Progress -Activity '扫描 Cloudflare 入口' -Status ('{0}/{1}，已可达 {2}' -f ($end + 1), $targets.Count, $first.Count) -PercentComplete ((($end + 1) * 100) / $targets.Count)
  }
  Write-Progress -Activity '扫描 Cloudflare 入口' -Completed
  if ($first.Count -eq 0) { throw '没有任何入口可达：请检查网络，或 443 端口是否被 WARP / 防火墙拦截。' }
  $hist = $first.Values | Group-Object { [int][math]::Floor($_ / 25) * 25 } | Sort-Object { [int]$_.Name } | ForEach-Object { '{0}ms:{1}' -f $_.Name, $_.Count }
  Write-Log ('可达 {0} 段；TCP 建连分布 → {1}' -f $first.Count, ($hist -join '  '))

  Write-Step '4/6 稳定性复测（最快 150 个，各 6 次）'
  $top150 = @($first.GetEnumerator() | Sort-Object Value | Select-Object -First 150 | ForEach-Object { $_.Key })
  $samples = @{}; foreach ($ip in $top150) { $samples[$ip] = New-Object System.Collections.Generic.List[double] }
  for ($round = 0; $round -lt 6; $round++) {
    foreach ($r in (Test-TcpBatch -Ips $top150 -TimeoutMs 2000)) { if ($r.Ms) { $samples[$r.Ip].Add($r.Ms) } }
    Start-Sleep -Milliseconds 200
  }
  $stable = foreach ($ip in $top150) {
    $s = $samples[$ip]
    if ($s.Count -eq 6) {
      $med = Get-Median $s.ToArray(); $max = ($s | Measure-Object -Maximum).Maximum
      if ($max -le ($med * 1.5 + 30)) { [pscustomobject]@{ Ip = $ip; Median = $med; Max = $max } }
    }
  }
  $stable = @($stable | Sort-Object Median)
  if ($stable.Count -eq 0) { throw '复测后没有稳定（0 丢包、无重传）的入口：当前线路丢包严重，请稍后再试。' }
  Write-Log ('0 丢包且无重传的入口 {0} 个；最低 TCP 中位数 {1} ms' -f $stable.Count, [math]::Round($stable[0].Median))

  Write-Step '5/6 落点 / TLS / WebSocket 验证'
  # 分批验证：每批 40 个，直到找够 -Top 个美国落点入口或验证满 120 个（香港等亚洲落点常常占满最快的前几十个）
  $verified = @(); $good = @(); $offset = 0
  while ($offset -lt $stable.Count -and $offset -lt 120 -and $good.Count -lt $Top) {
    $cands = @($stable | Select-Object -Skip $offset -First 40)
    Write-Log ('对第 {0}–{1} 个入口各做 2 次真实 SNI 的 TLS 连接…' -f ($offset + 1), ($offset + $cands.Count))
    foreach ($c in $cands) {
      $v1 = Test-Colo $c.Ip; $v2 = Test-Colo $c.Ip
      $codes = @($v1.Code, $v2.Code); $ok200 = @($codes | Where-Object { $_ -eq '200' }).Count
      $tlsVals = @($v1.Tls, $v2.Tls) | Where-Object { $_ -gt 0 }
      $tls = 0.0; if ($tlsVals.Count -gt 0) { $tls = ($tlsVals | Measure-Object -Maximum).Maximum }
      $colo = $v1.Colo; if ($colo -eq '-') { $colo = $v2.Colo }
      $reason = ''
      if ($ok200 -eq 0) { $reason = 'HTTP ' + ($codes -join '/') + '，不为本域名服务或连不上' }
      elseif ($script:UsColos -notcontains $colo) { $reason = '落点 ' + $colo + ' 不在美国' }
      elseif ($tls -gt (2.6 * $c.Median / 1000 + 0.08)) { $reason = 'TLS 耗时远超 2×RTT，落点不稳定' }
      $verified += [pscustomobject]@{ Ip = $c.Ip; Colo = $colo; TcpMedianMs = [math]::Round($c.Median); TcpMaxMs = [math]::Round($c.Max); TlsMaxSec = [math]::Round($tls, 3); Code = ($codes -join '/'); Reject = $reason }
    }
    $good = @($verified | Where-Object { -not $_.Reject } | Sort-Object TcpMedianMs)
    $offset += 40
  }
  Write-Host ''
  Write-Host '验证结果（按 TCP 中位数排序；Reject 为空的为可用入口）：' -ForegroundColor Yellow
  $verified | Sort-Object TcpMedianMs | Format-Table Ip, Colo, TcpMedianMs, TcpMaxMs, TlsMaxSec, Code, Reject -AutoSize | Out-String -Width 160 | Write-Host
  foreach ($v in ($verified | Sort-Object TcpMedianMs)) { Write-Log ('  {0,-15} {1,-4} tcp {2,4}/{3,4} ms tls {4,6:N3} s http {5,-7} {6}' -f $v.Ip, $v.Colo, $v.TcpMedianMs, $v.TcpMaxMs, $v.TlsMaxSec, $v.Code, $v.Reject) }
  $good = @($verified | Where-Object { -not $_.Reject } | Sort-Object TcpMedianMs)
  $coloSummary = ($verified | Group-Object Colo | Sort-Object Count -Descending | ForEach-Object { '{0}×{1}' -f $_.Name, $_.Count }) -join ' '
  Write-Log ('通过验证 {0} 个；落点分布 {1}' -f $good.Count, $coloSummary)
  if ($good.Count -eq 0) { throw '没有落点在美国且稳定的入口通过验证。看上表 Reject 列：若全是非美国落点，这条线路当前只能到亚洲机房；稍后或换网络再试。' }
  $fast = @($good | Where-Object { $_.TcpMedianMs -lt $MaxLatencyMs })
  if ($fast.Count -ge $MinNodes) { $pool = $fast; $resultLevel = 'OK' }
  else { $pool = $good; $resultLevel = 'PARTIAL'; Add-Warning ('低于 {0} ms 的入口只有 {1} 个（目标至少 {2} 个），改为生成最快的美国落点入口（最低 {3} ms）。这是你当前线路到美国机房的延迟，换入口无法更低；白天拥塞时常见，晚间通常 160–190 ms，建议晚间重跑一次' -f $MaxLatencyMs, $fast.Count, $MinNodes, $good[0].TcpMedianMs) }

  Write-Log ('对候选入口做 WebSocket 握手（需 101 且无安全质询）…')
  $chosen = @()
  foreach ($c in ($pool | Select-Object -First ($Top + 6))) {
    if ($chosen.Count -ge $Top) { break }
    $w = Test-WebSocket $c.Ip
    if ($w.Status -eq '101' -and -not $w.Mitigated) { $chosen += $c; Write-Log ('  {0,-15} {1} 握手 101' -f $c.Ip, $c.Colo) }
    elseif ($w.Mitigated) { Write-Log ('  {0,-15} 被安全质询（cf-mitigated={1}）：域的 Under Attack 豁免规则可能缺失，请告知管理员' -f $c.Ip, $w.Mitigated) 'WARN' }
    else { Write-Log ('  {0,-15} 握手返回 {1}，剔除' -f $c.Ip, $w.Status) 'WARN' }
  }
  if ($chosen.Count -eq 0) { throw 'WebSocket 握手全部失败：入口能连但 Worker 不可达，可能是域的安全设置（Under Attack）或 Worker 故障，请联系管理员。' }
  if ($chosen.Count -lt $MinNodes -and $resultLevel -eq 'OK') { $resultLevel = 'PARTIAL'; Add-Warning ('握手通过的入口只有 {0} 个' -f $chosen.Count) }
  $n = 0
  foreach ($c in $chosen) { $n++; $c | Add-Member -NotePropertyName Remark -NotePropertyValue ('{0}-{1}-{2:d2}' -f $Prefix, $c.Colo, $n) -Force }
  Write-Host ''
  Write-Host ('选中 {0} 个入口：' -f $chosen.Count) -ForegroundColor Green
  $chosen | Format-Table Remark, Ip, Colo, TcpMedianMs, TcpMaxMs, TlsMaxSec -AutoSize | Out-String | Write-Host
  Write-Log ('选中 {0} 个入口：{1}' -f $chosen.Count, (($chosen | ForEach-Object { '{0}={1}ms' -f $_.Ip, $_.TcpMedianMs }) -join ' '))

  if ($ReportOnly) {
    Write-Step '6/6 ReportOnly：不生成链接'
  } else {
    Write-Step '6/6 生成节点链接'
    if (-not $Uuid -and $env:SMJ_NODE_UUID) { $Uuid = $env:SMJ_NODE_UUID; Write-Log 'UUID 来自环境变量 SMJ_NODE_UUID' }
    $uuidFile = Join-Path $PSScriptRoot 'uuid.txt'
    if (-not $Uuid -and (Test-Path $uuidFile)) { $Uuid = (Get-Content $uuidFile -Raw).Trim(); Write-Log ('UUID 来自 {0}' -f $uuidFile) }
    if (-not $Uuid) {
      $sec = Read-Host '请输入节点 UUID（不回显；由管理员提供，不是 ADMIN 密码）' -AsSecureString
      $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
      try { $Uuid = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr).Trim() } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    }
    $Uuid = $Uuid.Trim().ToLowerInvariant()
    if ($Uuid -notmatch '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$') { throw 'UUID 格式不正确，需要 UUIDv4（形如 xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx）。它不是 ADMIN 密码，也不是 Cloudflare API Token。' }

    if ($xray) {
      $best = $chosen[0]
      Write-Log ('用临时 xray 实例经最快入口 {0} 做真连接延迟与出口检查…' -f $best.Ip)
      try {
        $x = Test-ViaXray -XrayExe $xray -Ip $best.Ip -NodeUuid $Uuid
        if ($x.Times.Count -gt 0) { Write-Log ('真连接延迟（导入前，{0}，3 次）：{1} s' -f $best.Ip, (($x.Times | ForEach-Object { '{0:N2}' -f $_ }) -join ' / ')) } else { Add-Warning '导入前真连接测试失败：隧道能握手但经 Worker 访问 google 失败，可能是 UUID 不对或 Worker 故障' }
        if ($x.Country -eq 'US') { Write-Log ('出口 US（导入前）：{0}' -f $x.Desc) }
        elseif ($x.Country) { Add-Problem ('出口不在美国：{0} {1}。Worker 放置区域可能已变更，请联系管理员' -f $x.Country, $x.Desc) }
        else { Add-Warning '导入前出口国家查询失败（ip.sb / cloudflare trace 都不可达）' }
      } catch { Add-Warning ('临时 xray 检查异常：{0}' -f $_.Exception.Message) }
    }

    $escapedPath = [Uri]::EscapeDataString($Path)
    $links = @($chosen | ForEach-Object { 'vless://{0}@{1}:443?security=tls&type=ws&host={2}&fp=chrome&sni={2}&path={3}&encryption=none#{4}' -f $Uuid, $_.Ip, $HostName, $escapedPath, $_.Remark })
    $text = ($links -join "`r`n")
    if (-not $OutFile) { $OutFile = Join-Path $script:LogDir 'nodes.txt' }
    $full = $OutFile; if (-not [IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).ProviderPath $full }; $full = [IO.Path]::GetFullPath($full)
    [IO.File]::WriteAllText($full, $text + "`r`n", (New-Object System.Text.UTF8Encoding $false))
    Write-Log ('链接已写入 {0}（含凭据，勿公开）' -f $full)
    if ($NoClipboard) { Write-Output $links } else { Set-Clipboard -Value $text; Write-Host ('已把 {0} 条节点链接复制到剪贴板。' -f $links.Count) -ForegroundColor Green }

    Write-Host ''
    Write-Host '现在到 v2rayN：' -ForegroundColor Cyan
    Write-Host ('  1. 主窗口按 Ctrl+V 导入（备注形如 {0}-{1}-01）；可先删除旧的高延迟节点。' -f $Prefix, $chosen[0].Colo)
    Write-Host '  2. 全选新节点 → 右键「测试服务器延迟」，双击最快的启用。'
    Write-Host '  3. 节点 Mux 保持关闭；设置 → 参数设置：关闭「TLS 分片」。'
    if (-not $NoVerify) {
      $ans = Read-Host '导入并启用后按回车开始验证（输入 S 跳过）'
      if ($ans.Trim().ToUpperInvariant() -ne 'S') {
        Write-Step ('导入后验证（经 127.0.0.1:{0}）' -f $ProxyPort)
        $null = Test-ViaLocalProxy
      } else { Add-Warning '已跳过导入后验证，出口国家未经 v2rayN 实际确认' }
    }
  }
} catch {
  Add-Problem $_.Exception.Message
  $resultLevel = 'FAIL'
} finally {
  Restore-Warp -ChosenIps @($chosen | ForEach-Object { $_.Ip })
}

Write-Host ''
if ($script:Problems.Count -gt 0) { $resultLevel = 'FAIL' }
switch ($resultLevel) {
  'OK' {
    $msg = 'RESULT: OK — {0} 个入口低于 {1} ms（最低 {2} ms），{3}' -f @($chosen | Where-Object { $_.TcpMedianMs -lt $MaxLatencyMs }).Count, $MaxLatencyMs, $chosen[0].TcpMedianMs, $(if ($script:Warnings.Count -gt 0) { '提醒：' + ($script:Warnings -join '；') } else { '链接已就绪' })
    Write-Log $msg
  }
  'PARTIAL' { Write-Log ('RESULT: PARTIAL — 已生成最快的 {0} 个入口（最低 {1} ms），但未达到 {2} ms 的目标：{3}' -f $chosen.Count, $chosen[0].TcpMedianMs, $MaxLatencyMs, ($script:Warnings -join '；')) 'WARN' }
  default { Write-Log ('RESULT: FAIL — ' + ($script:Problems -join '；')) 'FAIL' }
}
Write-Host ('日志：{0}' -f $script:LogFile)
if (-not $NoPause -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') { try { Read-Host '按回车键关闭窗口' | Out-Null } catch { } }
