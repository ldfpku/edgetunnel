<#
.SYNOPSIS
  Windows 独立一键设置脚本。只需分发此文件；无需同目录的其他脚本。
.DESCRIPTION
  设置 v2rayN、Cloudflare WARP 策略和 Windows 系统代理，验证美国出口及入口延迟，
  并注册登录后运行的计划任务。任务会再次调用本文件自身。
.PARAMETER EnsureOnly
  内部参数：仅运行登录后自检与修正，不安装或验证计划任务。
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键设置-独立版.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键设置-独立版.ps1 -DryRun
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\一键设置-独立版.ps1 -Uninstall -RestoreWarp
#>
[CmdletBinding()]
param(
    [ValidateSet('proxy', 'disconnect', 'keep')][string]$WarpPolicy = 'proxy',
    [int]$RepeatMinutes = 0,
    [string[]]$EntryIPs = @('104.17.157.1', '104.17.152.1', '104.17.150.1', '104.17.151.1', '104.17.143.1', '104.17.138.1', '104.17.148.1', '104.17.149.1', '104.17.133.1', '104.17.135.1', '172.64.79.1', '162.159.237.1'),
    [int]$ProxyPort = 10808,
    [int]$MaxLatencyMs = 250,
    [string]$V2rayNPath = '',
    [switch]$NoSystemProxy,
    [switch]$SkipTask,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$RestoreWarp,
    [switch]$EnsureOnly
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$EntryIPs = @($EntryIPs | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
$script:TaskName = 'SMJ-EnsureProxy'
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
        return ($ar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $client.Connected)
    } catch { return $false } finally { $client.Close() }
}

function Invoke-Curl {
    param([string[]]$Arguments)
    try {
        $out = & $script:Curl @Arguments 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return (@($out) -join "`n")
    } catch { return $null }
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
        (Join-Path ($env:SystemDrive + '\') 'tools\v2rayN-windows-64\v2rayN.exe'),
        (Join-Path $env:ProgramFiles 'v2rayN\v2rayN.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\v2rayN\v2rayN.exe'),
        (Join-Path $env:USERPROFILE 'Desktop\v2rayN-windows-64\v2rayN.exe'),
        (Join-Path $env:USERPROFILE 'Downloads\v2rayN-windows-64\v2rayN.exe')
    )
    foreach ($root in (Get-PSDrive -PSProvider FileSystem | Select-Object -ExpandProperty Root -Unique)) {
        if ($root -ne ($env:SystemDrive + '\')) { $candidates += Join-Path $root 'tools\v2rayN-windows-64\v2rayN.exe' }
    }
    foreach ($candidate in $candidates) { if ($candidate -and (Test-Path $candidate)) { return $candidate } }
    return $null
}

function Resolve-DuplicateV2rayN {
    $procs = @(Get-Process v2rayN -ErrorAction SilentlyContinue)
    if ($procs.Count -lt 2) { return }
    $ownerPid = $null
    try {
        $listen = Get-NetTCPConnection -LocalPort $ProxyPort -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($listen) {
            $core = Get-CimInstance Win32_Process -Filter ('ProcessId = {0}' -f $listen.OwningProcess) -ErrorAction SilentlyContinue
            if ($core) { $ownerPid = [int]$core.ParentProcessId }
        }
    } catch { }
    if (-not $ownerPid) { $ownerPid = ($procs | Sort-Object StartTime | Select-Object -First 1).Id }
    Write-Log ('发现 {0} 个 v2rayN 实例，保留 PID {1}' -f $procs.Count, $ownerPid)
    foreach ($process in $procs) {
        if ($process.Id -eq $ownerPid) { continue }
        if ($DryRun) { Write-Log ('[DryRun] 将关闭多余的 v2rayN 实例 PID {0}' -f $process.Id); continue }
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop; Write-Log ('已关闭多余的 v2rayN 实例 PID {0}' -f $process.Id) }
        catch { Add-Problem ('多余的 v2rayN 实例 PID {0} 无法关闭，请手动退出并只保留一个' -f $process.Id) }
    }
}

function Set-V2rayN {
    Resolve-DuplicateV2rayN
    if (Get-Process v2rayN -ErrorAction SilentlyContinue) { Write-Log 'v2rayN 已在运行'; return }
    if (Test-TcpPort '127.0.0.1' $ProxyPort) { Write-Log ('端口 {0} 已有服务监听，不再启动 v2rayN' -f $ProxyPort); return }
    $deadline = (Get-Date).AddSeconds(60)
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
    $command = Get-Command warp-cli -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }
    $path = Join-Path $env:ProgramFiles 'Cloudflare\Cloudflare WARP\warp-cli.exe'
    if (Test-Path $path) { return $path }
    return $null
}

function Invoke-Warp {
    param([string[]]$Arguments)
    try { $output = & $script:WarpCli @Arguments 2>&1; return (@($output) -join "`n") } catch { return '' }
}

function Set-Warp {
    $script:WarpCli = Get-WarpCli
    if (-not $script:WarpCli) { Write-Log '未安装 Cloudflare One 客户端，跳过'; return }
    $settings = Invoke-Warp @('settings')
    $status = Invoke-Warp @('status')
    $mode = 'unknown'
    if ($settings -match 'Mode:\s*(\S+)') { $mode = $Matches[1] }
    $connected = [bool]($status -match 'Status update:\s*Connected')
    $registration = Invoke-Warp @('registration', 'show')
    $managed = ($settings -match 'Daemon Teams Auth:\s*true') -or ($registration -match 'Organization|Account type:\s*Team')
    $route = ''
    try {
        $r = Find-NetRoute -RemoteIPAddress $EntryIPs[0] -ErrorAction SilentlyContinue | Where-Object { $_.NextHop } | Select-Object -First 1
        if ($r) { $route = $r.InterfaceAlias }
    } catch { }
    $connectedText = '未连接'
    if ($connected) { $connectedText = '已连接' }
    $managedText = ''
    if ($managed) { $managedText = '，由组织策略管理' }
    $routeText = '?'
    if ($route) { $routeText = $route }
    Write-Log ('WARP 模式 {0}，{1}{2}；入口当前经 {3} 路由' -f $mode, $connectedText, $managedText, $routeText)
    $tunnelMode = ($mode -notmatch 'proxy|dns|doh|dot')
    if (-not (($connected -and $tunnelMode) -or ($connected -and ($route -match 'WARP')))) { Write-Log 'WARP 未接管系统流量'; return }
    if ($WarpPolicy -eq 'keep') { Add-Problem 'WARP 正在接管系统流量（WarpPolicy=keep，未改动）'; return }
    if ($managed) { Add-Problem '此 WARP 由组织策略管理，请管理员在 Zero Trust 中排除节点入口网段'; return }
    $command = @('disconnect')
    if ($WarpPolicy -eq 'proxy') { $command = @('mode', 'proxy') }
    if ($DryRun) { Write-Log ('[DryRun] 将执行 warp-cli {0}' -f ($command -join ' ')); return }
    $result = Invoke-Warp $command
    Write-Log ('已执行 warp-cli {0}: {1}' -f ($command -join ' '), (($result -replace '\s+', ' ').Trim()))
    Start-Sleep -Seconds 5
}

function Set-SystemProxy {
    if ($NoSystemProxy) { return }
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $current = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
    $wanted = '127.0.0.1:{0}' -f $ProxyPort
    $server = [string]$current.ProxyServer
    if (($current.ProxyEnable -eq 1) -and (($server -match [regex]::Escape($wanted)) -or ($server -match ('localhost:{0}' -f $ProxyPort)))) {
        Write-Log ('系统代理已指向 {0}' -f $server); return
    }
    if (-not (Test-TcpPort '127.0.0.1' $ProxyPort)) { Add-Problem ('端口 {0} 无服务，未设置系统代理' -f $ProxyPort); return }
    if ($DryRun) { Write-Log ('[DryRun] 将把系统代理设为 {0}' -f $wanted); return }
    Set-ItemProperty -Path $key -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $key -Name ProxyServer -Value $wanted -Type String
    if (-not $current.ProxyOverride) {
        Set-ItemProperty -Path $key -Name ProxyOverride -Type String -Value 'localhost;127.*;10.*;172.16.*;172.17.*;172.18.*;172.19.*;172.20.*;172.21.*;172.22.*;172.23.*;172.24.*;172.25.*;172.26.*;172.27.*;172.28.*;172.29.*;172.30.*;172.31.*;192.168.*;<local>'
    }
    try {
        $signature = '[DllImport("wininet.dll", SetLastError = true)] public static extern bool InternetSetOption(IntPtr hInternet, int dwOption, IntPtr lpBuffer, int dwBufferLength);'
        $winInet = Add-Type -MemberDefinition $signature -Name WinInet -Namespace SmjProxy -PassThru
        $winInet::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0) | Out-Null
        $winInet::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0) | Out-Null
    } catch { }
    Write-Log ('已将系统代理设为 {0}' -f $wanted)
}

function Test-Egress {
    $proxy = 'http://127.0.0.1:{0}' -f $ProxyPort
    $country = $null
    $description = ''
    for ($attempt = 1; $attempt -le 2 -and -not $country; $attempt++) {
        if ($attempt -gt 1) { Write-Log '出口探测暂未成功，5 秒后重试'; Start-Sleep -Seconds 5 }
        $json = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', '-A', 'Mozilla/5.0', 'https://api.ip.sb/geoip')
        if ($json) {
            try {
                $geo = $json | ConvertFrom-Json
                if ($geo.country_code) { $country = $geo.country_code; $description = '{0} {1}, {2} (ip.sb)' -f $geo.ip, $geo.city, $geo.country }
            } catch { }
        }
        if (-not $country) {
            $trace = Invoke-Curl @('--proxy', $proxy, '-sS', '--max-time', '20', 'https://www.cloudflare.com/cdn-cgi/trace')
            if ($trace -match 'loc=(\w+)') { $country = $Matches[1]; $description = 'cloudflare trace' }
        }
    }
    if (-not $country) { Add-Problem '经代理无法访问外网：检查 v2rayN、节点和代理端口'; return $false }
    if ($country -ne 'US') { Add-Problem ('出口不在美国：{0} {1}' -f $country, $description); return $false }
    Write-Log ('出口 US：{0}' -f $description)
    return $true
}

function Test-ProxyAndLatency {
    $proxyUp = $false
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        if (Test-TcpPort '127.0.0.1' $ProxyPort) { $proxyUp = $true; break }
        Start-Sleep -Seconds 3
    }
    if (-not $proxyUp) { Add-Problem ('代理端口 127.0.0.1:{0} 未监听' -f $ProxyPort) }
    Set-SystemProxy
    if ($proxyUp) {
        $null = Test-Egress
        $delay = Invoke-Curl @('--proxy', ('http://127.0.0.1:{0}' -f $ProxyPort), '-sS', '-o', 'NUL', '--max-time', '15', '-w', '%{http_code} %{time_total}', 'https://www.google.com/generate_204')
        if ($delay -match '^204 ([\d.]+)') { Write-Log ('真连接延迟 {0:N2} s' -f [double]$Matches[1]) }
        else { Write-Log '真连接延迟测试失败' 'WARN' }
    }
    $results = @()
    foreach ($ip in $EntryIPs) {
        $out = Invoke-Curl @('--noproxy', '*', '-sS', '-o', 'NUL', '--max-time', '6', '--resolve', ('dfvpn.smjtools.com:443:{0}' -f $ip), '-w', '%{http_code} %{time_connect}', ('https://dfvpn.smjtools.com/'))
        if ($out -match '^(\d{3}) ([\d.]+)') { $results += [pscustomobject]@{ IP = $ip; Ms = [int][math]::Round([double]$Matches[2] * 1000); Code = $Matches[1] } }
        else { $results += [pscustomobject]@{ IP = $ip; Ms = $null; Code = 'fail' } }
    }
    foreach ($result in $results) {
        if ($null -ne $result.Ms) { Write-Log ('入口 {0,-15} {1,4} ms (http {2})' -f $result.IP, $result.Ms, $result.Code) }
        else { Write-Log ('入口 {0,-15} 连接失败' -f $result.IP) }
    }
    $reachable = @($results | Where-Object { $null -ne $_.Ms })
    if ($reachable.Count -eq 0) { Add-Problem '所有入口都连不上：检查网络或入口 IP'; return }
    $fast = @($reachable | Where-Object { $_.Ms -le $MaxLatencyMs })
    $sorted = @($reachable | Sort-Object Ms)
    $median = $sorted[[int][math]::Floor($sorted.Count / 2)].Ms
    Write-Log ('入口延迟：最低 {0} ms，中位 {1} ms，{2}/{3} 个低于 {4} ms' -f $sorted[0].Ms, $median, $fast.Count, $results.Count, $MaxLatencyMs)
    if ($fast.Count -lt 3) { Add-Problem ('低于 {0} ms 的入口不足 3 个' -f $MaxLatencyMs) }
}

function Invoke-EnsureRun {
    $runText = ''
    if ($DryRun) { $runText = '，DryRun' }
    Write-Log ('==== ensure-proxy 开始（用户 {0}，主机 {1}{2}）====' -f $env:USERNAME, $env:COMPUTERNAME, $runText)
    try {
        $deadline = (Get-Date).AddSeconds(120)
        $networkReady = $false
        while ((Get-Date) -lt $deadline -and -not $networkReady) {
            foreach ($ip in ($EntryIPs | Select-Object -First 3)) {
                if (Test-TcpPort $ip 443 3000) { $networkReady = $true; break }
            }
            if (-not $networkReady) { Start-Sleep -Seconds 5 }
        }
        if (-not $networkReady) { Add-Problem '等待网络 120 秒仍不可用' }
        Set-V2rayN
        Set-Warp
        Test-ProxyAndLatency
    } catch { Add-Problem ('脚本异常：{0}' -f $_.Exception.Message) }
    if ($script:Problems.Count -eq 0) { Write-Log 'RESULT: OK — 出口美国，入口延迟达标' }
    else { Write-Log ('RESULT: FAIL — ' + ($script:Problems -join '；')) 'WARN' }
}

function Get-TaskArguments {
    $parts = @('-NoProfile', '-ExecutionPolicy Bypass', '-WindowStyle Hidden', '-File', ('"{0}"' -f $PSCommandPath), '-EnsureOnly', '-WarpPolicy', $WarpPolicy, '-ProxyPort', [string]$ProxyPort, '-MaxLatencyMs', [string]$MaxLatencyMs)
    if ($EntryIPs) { $parts += @('-EntryIPs', ('"{0}"' -f ($EntryIPs -join ','))) }
    if ($V2rayNPath) { $parts += @('-V2rayNPath', ('"{0}"' -f $V2rayNPath)) }
    if ($NoSystemProxy) { $parts += '-NoSystemProxy' }
    return ($parts -join ' ')
}

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    Remove-ItemProperty -Path $runKey -Name $script:TaskName -ErrorAction SilentlyContinue
    Write-Host ('已删除计划任务及登录启动项（如存在）：{0}' -f $script:TaskName)
    if ($RestoreWarp) {
        $warp = Get-WarpCli
        if ($warp) { & $warp mode warp | Out-Null; Write-Host 'Cloudflare WARP 已改回全隧道模式' }
    }
    Write-Host '系统代理与 v2rayN 未改动；可在 v2rayN 中选择“清除系统代理”。'
    return
}

if ($EnsureOnly) {
    Invoke-EnsureRun
    exit 0
}

Write-Host ('PowerShell {0}；用户 {1}' -f $PSVersionTable.PSVersion, $env:USERNAME)
if (-not (Test-Path $script:Curl)) { Write-Warning '未找到 curl.exe；出口及延迟验证可能失败' }
if (Get-Process v2rayN -ErrorAction SilentlyContinue) { Write-Host 'v2rayN 正在运行' }
else { Write-Host 'v2rayN 未运行，将尝试启动' }
if (Get-Command warp-cli -ErrorAction SilentlyContinue) { Write-Host ('检测到 Cloudflare WARP，策略：{0}' -f $WarpPolicy) }

Write-Host "`n==== 1/3 应用设置并检查 ===="
$childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, '-EnsureOnly', '-WarpPolicy', $WarpPolicy, '-ProxyPort', [string]$ProxyPort, '-MaxLatencyMs', [string]$MaxLatencyMs)
if ($EntryIPs) { $childArgs += @('-EntryIPs', ($EntryIPs -join ',')) }
if ($V2rayNPath) { $childArgs += @('-V2rayNPath', $V2rayNPath) }
if ($NoSystemProxy) { $childArgs += '-NoSystemProxy' }
if ($DryRun) { $childArgs += '-DryRun' }
& powershell.exe @childArgs

Write-Host "`n==== 2/3 注册登录后计划任务 ===="
$taskInstalled = $false
$startupFallback = $false
if ($SkipTask) { Write-Host '已按 -SkipTask 跳过计划任务' }
elseif ($DryRun) { Write-Host 'DryRun：未注册计划任务' }
else {
    try {
        $user = '{0}\\{1}' -f $env:USERDOMAIN, $env:USERNAME
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT45S'
        if ($RepeatMinutes -gt 0) {
            $repetition = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
            $trigger.Repetition = $repetition.Repetition
        }
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-TaskArguments)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -Description '登录后自检并修正 v2rayN、WARP、系统代理及连接状态' -ErrorAction Stop | Out-Null
        $taskInstalled = $true
        Write-Host ('计划任务已注册：{0}，登录后 45 秒运行' -f $script:TaskName)
    } catch {
        Write-Warning ('计划任务注册失败：{0}' -f $_.Exception.Message)
        try {
            $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            $runCommand = 'powershell.exe ' + (Get-TaskArguments)
            Set-ItemProperty -Path $runKey -Name $script:TaskName -Value $runCommand -Type String -ErrorAction Stop
            $startupFallback = $true
            Write-Warning '已改用当前用户登录启动项；此方式不支持定时复查。'
            if ($RepeatMinutes -gt 0) { Write-Warning ('-RepeatMinutes {0} 未启用，因为计划任务注册失败。' -f $RepeatMinutes) }
        } catch {
            Write-Error ('登录启动项也未能创建：{0}' -f $_.Exception.Message)
        }
    }
}

Write-Host "`n==== 3/3 验证与汇总 ===="
if ($SkipTask -or $DryRun -or $startupFallback -or -not $taskInstalled) { Write-Host '计划任务验证已跳过' }
else {
    if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null }
    $before = 0
    if (Test-Path $script:LogFile) { $before = @(Get-Content $script:LogFile).Count }
    $taskStarted = $false
    try {
        Start-ScheduledTask -TaskName $script:TaskName -ErrorAction Stop
        $taskStarted = $true
        Write-Host '已触发刚注册的任务，等待检查结果（最长 240 秒）...'
    } catch {
        Write-Warning ('无法启动计划任务进行验证：{0}' -f $_.Exception.Message)
    }
    if ($taskStarted) {
        $taskResult = $null
        $deadline = (Get-Date).AddSeconds(240)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 5
            if (-not (Test-Path $script:LogFile)) { continue }
            $lines = @(Get-Content $script:LogFile)
            if ($lines.Count -le $before) { continue }
            $taskResult = $lines[$before..($lines.Count - 1)] | Where-Object { $_ -match 'RESULT:' } | Select-Object -Last 1
            if ($taskResult) { break }
        }
        if ($taskResult) { Write-Host ('任务结果：{0}' -f $taskResult) }
        else { Write-Warning '240 秒内未检测到任务结果，请检查计划任务和日志。' }
    }
}

Write-Host ('日志：{0}' -f $script:LogFile)
Write-Host ('卸载命令：powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}" -Uninstall' -f $PSCommandPath)
