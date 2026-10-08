<#
.SYNOPSIS
  一键设置（Windows）：应用代理环境 → 注册开机任务 → 立即验证任务 → 打印汇总。

.DESCRIPTION
  依次调用同目录的 Ensure-Proxy.ps1（应用并检查）和 Install-StartupTask.ps1（注册登录后静默运行的计划任务），
  然后启动一次该任务并等待它写出结果，最后汇总。各功能块的含义、手动检验命令和还原方法见 GUIDE.md。
  通常由 一键设置.cmd 双击启动；也可在 PowerShell 中带参数运行。

.PARAMETER DryRun
  只检查、不改动、不注册、不触发任务。
.PARAMETER Uninstall
  删除计划任务；再加 -RestoreWarp 同时把 Cloudflare One 客户端改回全隧道模式。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1
  powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1 -DryRun
  powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1 -RepeatMinutes 30
  powershell -ExecutionPolicy Bypass -File .\Setup-Proxy.ps1 -Uninstall -RestoreWarp
#>
[CmdletBinding()]
param(
    [ValidateSet('proxy', 'disconnect', 'keep')][string]$WarpPolicy = 'proxy',
    [int]$RepeatMinutes = 0,
    [string[]]$EntryIPs,
    [int]$ProxyPort = 10808,
    [int]$MaxLatencyMs = 250,
    [string]$V2rayNPath = '',
    [switch]$SkipTask,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$RestoreWarp
)
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$here = $PSScriptRoot
$ensure = Join-Path $here 'Ensure-Proxy.ps1'
$install = Join-Path $here 'Install-StartupTask.ps1'
$guide = Join-Path $here 'GUIDE.md'
$taskName = 'SMJ-EnsureProxy'
$log = Join-Path $env:LOCALAPPDATA 'smj-proxy\ensure-proxy.log'

function Write-Step { param([string]$Text) Write-Host ''; Write-Host ('==== ' + $Text + ' ====') -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host ('  [OK] ' + $Text) -ForegroundColor Green }
function Write-Bad { param([string]$Text) Write-Host ('  [!!] ' + $Text) -ForegroundColor Yellow }

if ($Uninstall) {
    Write-Step '卸载'
    & $install -Uninstall
    if ($RestoreWarp) {
        $w = Get-Command warp-cli -ErrorAction SilentlyContinue
        if ($w) { & $w.Source mode warp | Out-Null; Write-Ok 'Cloudflare One 客户端已改回全隧道模式（warp-cli mode warp）' }
    }
    Write-Host '  系统代理与 v2rayN 未改动；要关闭系统代理，在 v2rayN 中选择「清除系统代理」。'
    return
}

foreach ($f in @($ensure, $install)) { if (-not (Test-Path $f)) { Write-Bad ('缺少 ' + $f + '，请把整个 tools\startup 目录放在一起'); return } }

Write-Step '1/4 环境检查'
$modeText = '正式运行'
if ($DryRun) { $modeText = 'DryRun：只检查不改动' }
Write-Host ('  PowerShell {0}；用户 {1}；{2}' -f $PSVersionTable.PSVersion, $env:USERNAME, $modeText)
if (Test-Path (Join-Path $env:SystemRoot 'System32\curl.exe')) { Write-Ok 'curl.exe 可用' } else { Write-Bad '缺少 curl.exe（Windows 10 1803 以上自带），出口与延迟测试会失败' }
$v2 = @(Get-Process v2rayN -ErrorAction SilentlyContinue)
if ($v2.Count -eq 1) { Write-Ok 'v2rayN 正在运行' }
elseif ($v2.Count -gt 1) { Write-Bad ('v2rayN 有 {0} 个实例在运行，脚本会只保留持有端口的那个' -f $v2.Count) }
else { Write-Host '  v2rayN 未运行，稍后由脚本启动' }
if (Get-Command warp-cli -ErrorAction SilentlyContinue) { Write-Ok ('Cloudflare One 客户端已安装，处理策略：' + $WarpPolicy) } else { Write-Host '  未安装 Cloudflare One 客户端，跳过 WARP 处理' }

Write-Step '2/4 应用设置并检查（Ensure-Proxy.ps1）'
$p = @{ WarpPolicy = $WarpPolicy; ProxyPort = $ProxyPort; MaxLatencyMs = $MaxLatencyMs }
if ($EntryIPs) { $p.EntryIPs = $EntryIPs }
if ($V2rayNPath) { $p.V2rayNPath = $V2rayNPath }
if ($DryRun) { $p.DryRun = $true }
& $ensure @p

Write-Step '3/4 注册开机任务（Install-StartupTask.ps1）'
if ($SkipTask) { Write-Host '  已跳过（-SkipTask）' }
else {
    $ip = @{ RepeatMinutes = $RepeatMinutes }
    $extra = @()
    if ($WarpPolicy -ne 'proxy') { $extra += ('-WarpPolicy ' + $WarpPolicy) }
    if ($ProxyPort -ne 10808) { $extra += ('-ProxyPort ' + $ProxyPort) }
    if ($MaxLatencyMs -ne 250) { $extra += ('-MaxLatencyMs ' + $MaxLatencyMs) }
    if ($EntryIPs) { $extra += ('-EntryIPs ' + ($EntryIPs -join ',')) }
    if ($V2rayNPath) { $extra += ('-V2rayNPath "' + $V2rayNPath + '"') }
    if ($extra.Count -gt 0) { $ip.ScriptArgs = ($extra -join ' ') }
    if ($DryRun) { $ip.WhatIf = $true }
    & $install @ip
}

Write-Step '4/4 验证开机任务能静默运行'
if ($SkipTask -or $DryRun) { Write-Host '  已跳过' }
else {
    $before = 0
    if (Test-Path $log) { $before = @(Get-Content $log).Count }
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    Write-Host '  已触发任务，等待它写出结果（通常 30–60 秒）...'
    $result = $null
    $deadline = (Get-Date).AddSeconds(240)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        if (-not (Test-Path $log)) { continue }
        $lines = @(Get-Content $log)
        if ($lines.Count -le $before) { continue }
        $r = $lines[$before..($lines.Count - 1)] | Where-Object { $_ -match 'RESULT:' } | Select-Object -Last 1
        if ($r) { $result = $r; break }
    }
    if ($result -match 'RESULT: OK') { Write-Ok ('任务已静默跑完一次：' + ($result -replace '^\S+ \S+ \[\w+\] ', '')) }
    elseif ($result) { Write-Bad ('任务跑完但未达标：' + ($result -replace '^\S+ \S+ \[\w+\] ', '')) }
    else { Write-Bad '240 秒内任务没有写出结果：查看日志，或在「任务计划程序」里看 SMJ-EnsureProxy 的上次运行结果' }
}

Write-Step '汇总（取自最近一次检查的日志）'
if (Test-Path $log) {
    $lines = @(Get-Content $log)
    $starts = @($lines | Select-String -Pattern 'ensure-proxy 开始')
    if ($starts.Count -gt 0) {
        $from = $starts[-1].LineNumber - 1
        $run = $lines[$from..($lines.Count - 1)]
        $run | Where-Object { $_ -match 'v2rayN|WARP|warp-cli|Cloudflare|系统代理|出口|真连接延迟|入口延迟：|RESULT' } |
            ForEach-Object { Write-Host ('  ' + ($_ -replace '^\S+ \S+ ', '')) }
    }
}
Write-Host ''
Write-Host ('日志：' + $log)
Write-Host ('各功能块说明与手动检验命令：' + $guide)
