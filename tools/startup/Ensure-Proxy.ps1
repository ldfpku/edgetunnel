<#
.SYNOPSIS
  登录后静默自检并修正代理环境（Windows）。目标：浏览器出口在美国、入口延迟低于阈值、无弹窗。

.DESCRIPTION
  依次检查并修正：
    1. v2rayN 在运行（没有就启动；已有实例或端口已被监听时不重复启动）
    2. Cloudflare One / WARP 不接管系统流量（默认切到代理模式，可选断开或不动）
    3. Windows 系统代理指向 127.0.0.1:<端口>
    4. 经代理访问 ip.sb：出口国家必须是 US
    5. 直连各入口 IP 的 TCP 建连时间：低于阈值的入口数量达标
  所有结果写入 %LOCALAPPDATA%\smj-proxy\ensure-proxy.log；也可在 PowerShell 中手动运行查看。
  加 -DryRun 只检查、不做任何改动。脚本不含任何凭据，节点由 v2rayN 自己管理。

.PARAMETER WarpPolicy
  proxy      默认。把 Cloudflare One 客户端切到「代理模式」：不接管路由和 DNS，只在 127.0.0.1:40000 提供可选的 SOCKS5。
  disconnect 断开 WARP。
  keep       不改动 WARP，只记录。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Ensure-Proxy.ps1 -DryRun
#>
[CmdletBinding()]
param(
    [int]$ProxyPort = 10808,
    [string]$NodeHost = 'dfvpn.smjtools.com',
    [string[]]$EntryIPs = @('104.17.157.1', '104.17.152.1', '104.17.150.1', '104.17.151.1', '104.17.143.1', '104.17.138.1',
        '104.17.148.1', '104.17.149.1', '104.17.133.1', '104.17.135.1', '172.64.79.1', '162.159.237.1'),
    [int]$MaxLatencyMs = 250,
    [int]$MinFastEntries = 3,
    [ValidateSet('proxy', 'disconnect', 'keep')][string]$WarpPolicy = 'proxy',
    [string]$V2rayNPath = '',
    [switch]$NoSystemProxy,
    [int]$StartGraceSeconds = 60,
    [int]$NetworkWaitSeconds = 120,
    [switch]$DryRun
)

$ErrorActionPreference = 'Continue'
$script:LogDir = Join-Path $env:LOCALAPPDATA 'smj-proxy'
$script:LogFile = Join-Path $script:LogDir 'ensure-proxy.log'
$script:Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
if (-not (Test-Path $script:Curl)) { $script:Curl = 'curl.exe' }
$script:WarpCli = $null
$script:Problems = New-Object System.Collections.Generic.List[string]

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
        if ((Test-Path $script:LogFile) -and ((Get-Item $script:LogFile).Length -gt 1MB)) { Move-Item $script:LogFile ($script:LogFile + '.1') -Force }
        Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
    } catch { }
    Write-Host $line
}

function Add-Problem {
    param([string]$Text)
    $script:Problems.Add($Text)
    Write-Log $Text 'WARN'
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port, [int]$TimeoutMs = 1500)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected) { return $true }
        return $false
    } catch { return $false } finally { $client.Close() }
}

function Invoke-Curl {
    # 运行 curl.exe，失败返回 $null。是否走代理由调用方的参数决定（直连探测必须带 --noproxy "*"）。
    param([string[]]$Arguments)
    try {
        $out = & $script:Curl @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($out) -join "`n")
    } catch { return $null }
}

function Wait-Network {
    $deadline = (Get-Date).AddSeconds($NetworkWaitSeconds)
    do {
        foreach ($ip in ($EntryIPs | Select-Object -First 3)) { if (Test-TcpPort $ip 443 3000) { return $true } }
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Find-V2rayN {
    if ($V2rayNPath -and (Test-Path $V2rayNPath)) { return $V2rayNPath }
    $candidates = @()
    try {
        $p = Get-Process v2rayN -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($p -and $p.Path) { $candidates += $p.Path }
    } catch { }
    try {
        Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
            $_.Actions | Where-Object { $_.Execute -match 'v2rayN\.exe' } | ForEach-Object { $candidates += ($_.Execute -replace '"', '') }
        }
    } catch { }
    $candidates += @(
        'C:\tools\v2rayN-windows-64\v2rayN.exe',
        (Join-Path $env:ProgramFiles 'v2rayN\v2rayN.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\v2rayN\v2rayN.exe'),
        (Join-Path $env:USERPROFILE 'Desktop\v2rayN-windows-64\v2rayN.exe'),
        (Join-Path $env:USERPROFILE 'Downloads\v2rayN-windows-64\v2rayN.exe'),
        'D:\tools\v2rayN-windows-64\v2rayN.exe'
    )
    foreach ($c in $candidates) { if ($c -and (Test-Path $c)) { return $c } }
    return $null
}

function Ensure-V2rayN {
    if (Get-Process v2rayN -ErrorAction SilentlyContinue) { Write-Log 'v2rayN 已在运行'; return }
    if (Test-TcpPort '127.0.0.1' $ProxyPort) { Write-Log ('端口 {0} 已有服务在监听，不再启动 v2rayN' -f $ProxyPort); return }
    # 给其它自启动方式（例如 v2rayN 自己的开机任务）留出时间，避免启动两个实例互相抢端口
    $deadline = (Get-Date).AddSeconds($StartGraceSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (Get-Process v2rayN -ErrorAction SilentlyContinue) { Write-Log 'v2rayN 已由其它方式启动'; return }
    }
    $exe = Find-V2rayN
    if (-not $exe) { Add-Problem '找不到 v2rayN.exe，请用 -V2rayNPath 指定'; return }
    if ($DryRun) { Write-Log ('[DryRun] 将启动 {0}' -f $exe); return }
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) -WindowStyle Minimized | Out-Null
    Write-Log ('已启动 {0}' -f $exe)
}

function Get-WarpCli {
    $c = Get-Command warp-cli -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p = Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'
    if (Test-Path $p) { return $p }
    return $null
}

function Invoke-Warp {
    param([string[]]$Arguments)
    try { $o = & $script:WarpCli @Arguments 2>&1; return (@($o) -join "`n") } catch { return '' }
}

function Get-EntryRouteInterface {
    try {
        $r = Find-NetRoute -RemoteIPAddress $EntryIPs[0] -ErrorAction SilentlyContinue | Where-Object { $_.NextHop } | Select-Object -First 1
        if ($r) { return $r.InterfaceAlias }
    } catch { }
    return ''
}

function Ensure-Warp {
    $script:WarpCli = Get-WarpCli
    if (-not $script:WarpCli) { Write-Log '未安装 Cloudflare One 客户端，跳过'; return }
    $settings = Invoke-Warp @('settings')
    $status = Invoke-Warp @('status')
    $mode = 'unknown'
    if ($settings -match 'Mode:\s*(\S+)') { $mode = $Matches[1] }
    $connected = [bool]($status -match 'Status update:\s*Connected')
    $registration = Invoke-Warp @('registration', 'show')
    $managed = ($settings -match 'Daemon Teams Auth:\s*true') -or ($registration -match 'Organization|Account type:\s*Team')
    $iface = Get-EntryRouteInterface
    $connText = '未连接'
    if ($connected) { $connText = '已连接' }
    $managedText = ''
    if ($managed) { $managedText = '，由组织策略管理' }
    $ifaceText = '?'
    if ($iface) { $ifaceText = $iface }
    Write-Log ('WARP 模式 {0}，{1}{2}；节点入口当前经 {3} 路由' -f $mode, $connText, $managedText, $ifaceText)
    $tunnelMode = ($mode -notmatch 'proxy|dns|doh|dot')
    $hijacking = ($connected -and $tunnelMode) -or ($connected -and ($iface -match 'WARP'))
    if (-not $hijacking) { Write-Log 'WARP 未接管系统流量'; return }
    if ($WarpPolicy -eq 'keep') { Add-Problem 'WARP 正在接管系统流量（WarpPolicy=keep，未改动）；节点延迟会增加 100 ms 以上'; return }
    if ($managed) { Add-Problem '此 WARP 由组织策略管理，脚本不能修改；请管理员在 Zero Trust 的 Split Tunnels 中排除节点入口网段'; return }
    $cmd = @('disconnect')
    if ($WarpPolicy -eq 'proxy') { $cmd = @('mode', 'proxy') }
    if ($DryRun) { Write-Log ('[DryRun] 将执行 warp-cli {0}' -f ($cmd -join ' ')); return }
    $r = Invoke-Warp $cmd
    Write-Log ('已执行 warp-cli {0}: {1}' -f ($cmd -join ' '), (($r -replace '\s+', ' ').Trim()))
    Start-Sleep -Seconds 5
    $iface = Get-EntryRouteInterface
    if ($iface -match 'WARP') { Add-Problem '节点入口仍经 WARP 接口路由，请检查 Cloudflare One 客户端的模式' } else { Write-Log ('节点入口现经 {0} 直连' -f $iface) }
}

function Ensure-SystemProxy {
    if ($NoSystemProxy) { return }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $cur = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $want = '127.0.0.1:{0}' -f $ProxyPort
    $server = [string]$cur.ProxyServer
    $ok = ($cur.ProxyEnable -eq 1) -and (($server -match [regex]::Escape($want)) -or ($server -match ('localhost:{0}' -f $ProxyPort)))
    if ($ok) { Write-Log ('系统代理已指向 {0}' -f $server); return }
    if (-not (Test-TcpPort '127.0.0.1' $ProxyPort)) { Add-Problem ('端口 {0} 无服务，未设置系统代理' -f $ProxyPort); return }
    if ($DryRun) { Write-Log ('[DryRun] 将把系统代理设为 {0}（当前 ProxyEnable={1} ProxyServer={2}）' -f $want, $cur.ProxyEnable, $server); return }
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name ProxyServer -Value $want -Type String
    if (-not $cur.ProxyOverride) {
        Set-ItemProperty -Path $key -Name ProxyOverride -Type String -Value 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'
    }
    # 通知 WinINet 立即生效，浏览器不必重启
    try {
        $sig = '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
        $w = Add-Type -MemberDefinition $sig -Name WinInet -Namespace SmjProxy -PassThru
        $w::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        $w::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch { }
    Write-Log ('已将系统代理设为 {0}' -f $want)
}

function Test-Egress {
    $proxy = 'http://127.0.0.1:{0}' -f $ProxyPort
    $country = $null
    $desc = ''
    $json = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', '-A', 'Mozilla/5.0', 'https://api.ip.sb/geoip')
    if ($json) {
        try {
            $g = $json | ConvertFrom-Json
            if ($g.country_code) { $country = $g.country_code; $desc = '{0} {1}, {2} (ip.sb)' -f $g.ip, $g.city, $g.country }
        } catch { }
    }
    if (-not $country) {
        $trace = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', 'https://www.cloudflare.com/cdn-cgi/trace')
        if ($trace -match 'loc=(\w+)') {
            $country = $Matches[1]
            $colo = '?'
            if ($trace -match 'colo=(\w+)') { $colo = $Matches[1] }
            $desc = 'colo {0} (cloudflare trace)' -f $colo
        }
    }
    if (-not $country) { Add-Problem '经代理无法访问外网：v2rayN 未运行、节点不可用或系统代理端口不对'; return $false }
    if ($country -ne 'US') { Add-Problem ('出口不在美国：{0} {1}。请在 v2rayN 中选择美国出口的节点或策略组' -f $country, $desc); return $false }
    Write-Log ('出口 US：{0}' -f $desc)
    return $true
}

function Test-RealDelay {
    $t = Invoke-Curl @('--proxy', ('http://127.0.0.1:{0}' -f $ProxyPort), '-sS', '-o', 'NUL', '--max-time', '15', '-w', '%{http_code} %{time_total}', 'https://www.google.com/generate_204')
    if ($t -match '^204 ([\d.]+)') { Write-Log ('真连接延迟 {0:N2} s（经代理访问 google generate_204；受往返次数限制，正常 0.8–1.2 s）' -f [double]$Matches[1]) }
    else { Write-Log '真连接延迟测试失败' 'WARN' }
}

function Test-Latency {
    $results = @()
    foreach ($ip in $EntryIPs) {
        $out = Invoke-Curl @('--noproxy', '*', '-sS', '-o', 'NUL', '--max-time', '6', '--resolve', ('{0}:443:{1}' -f $NodeHost, $ip), '-w', '%{http_code} %{time_connect}', ('https://{0}/' -f $NodeHost))
        if ($out -and ($out -match '^(\d{3}) ([\d.]+)')) {
            $results += [pscustomobject]@{ IP = $ip; Ms = [int][math]::Round([double]$Matches[2] * 1000); Code = $Matches[1] }
        } else {
            $results += [pscustomobject]@{ IP = $ip; Ms = $null; Code = 'fail' }
        }
    }
    foreach ($r in $results) {
        if ($r.Ms -ne $null) { Write-Log ('入口 {0,-15} {1,4} ms (http {2})' -f $r.IP, $r.Ms, $r.Code) } else { Write-Log ('入口 {0,-15} 连接失败' -f $r.IP) }
    }
    $ok = @($results | Where-Object { $_.Ms -ne $null })
    if ($ok.Count -eq 0) { Add-Problem '所有入口都连不上：网络未就绪，或入口被拦截'; return $false }
    $fast = @($ok | Where-Object { $_.Ms -le $MaxLatencyMs })
    $sorted = @($ok | Sort-Object Ms)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)].Ms
    Write-Log ('入口延迟：最低 {0} ms，中位 {1} ms，{2}/{3} 个低于 {4} ms' -f $sorted[0].Ms, $median, $fast.Count, $results.Count, $MaxLatencyMs)
    if ($fast.Count -lt $MinFastEntries) {
        Add-Problem ('低于 {0} ms 的入口不足 {1} 个。若入口流量仍经 WARP，先处理 WARP；否则运行 tools\latency\Optimize-Colleague.ps1 在本网络重新选入口' -f $MaxLatencyMs, $MinFastEntries)
        return $false
    }
    return $true
}

$runText = ''
if ($DryRun) { $runText = '，DryRun' }
Write-Log ('==== ensure-proxy 开始（用户 {0}，主机 {1}{2}）====' -f $env:USERNAME, $env:COMPUTERNAME, $runText)
try {
    if (-not (Wait-Network)) { Add-Problem ('等待网络 {0} 秒仍不可用' -f $NetworkWaitSeconds) }
    Ensure-V2rayN
    Ensure-Warp
    $portUp = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort '127.0.0.1' $ProxyPort) { $portUp = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $portUp) { Add-Problem ('代理端口 127.0.0.1:{0} 未监听（v2rayN 未启动，或端口被另一个实例占用）' -f $ProxyPort) }
    Ensure-SystemProxy
    if ($portUp) { $null = Test-Egress; Test-RealDelay }
    $null = Test-Latency
} catch {
    Add-Problem ('脚本异常：{0}' -f $_.Exception.Message)
}
if ($script:Problems.Count -eq 0) { Write-Log 'RESULT: OK — 出口美国，入口延迟达标' }
else { Write-Log ('RESULT: FAIL — ' + ($script:Problems -join '；')) 'WARN' }
exit 0
