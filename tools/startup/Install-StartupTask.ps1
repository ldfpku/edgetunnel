<#
.SYNOPSIS
  把 Ensure-Proxy.ps1 注册为当前用户登录后静默运行的 Windows 计划任务（不弹窗、不需要管理员）。

.DESCRIPTION
  任务以当前用户、普通权限、仅在用户登录时运行；通过 wscript 无窗口启动 PowerShell，登录时不会闪出黑窗。
  -RepeatMinutes N 可让任务之后每 N 分钟复查一次。-Uninstall 删除任务。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File .\Install-StartupTask.ps1
  powershell -ExecutionPolicy Bypass -File .\Install-StartupTask.ps1 -RepeatMinutes 30
  powershell -ExecutionPolicy Bypass -File .\Install-StartupTask.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Uninstall,
    [int]$DelaySeconds = 45,
    [int]$RepeatMinutes = 0,
    [string]$TaskName = 'SMJ-EnsureProxy',
    [string]$ScriptArgs = ''
)
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Ensure-Proxy.ps1'
$dir = Join-Path $env:LOCALAPPDATA 'smj-proxy'
$vbs = Join-Path $dir 'run-hidden.vbs'

if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Output ('已删除计划任务 {0}' -f $TaskName)
    } else { Write-Output ('计划任务 {0} 不存在' -f $TaskName) }
    if (Test-Path $vbs) { Remove-Item $vbs -Force }
    return
}

if (-not (Test-Path $script)) { throw ('找不到 {0}' -f $script) }
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
Unblock-File -Path $script -ErrorAction SilentlyContinue

$psArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" {1}' -f $script, $ScriptArgs
$useVbs = $false
try {
    # 新版 Windows 可能已停用 VBScript，先试一下（用 .NET 写临时文件，不受 -WhatIf 影响）
    $t = Join-Path $env:TEMP ('smj_vbs_test_{0}.vbs' -f ([guid]::NewGuid().ToString('N')))
    [System.IO.File]::WriteAllText($t, 'WScript.Echo "ok"', [System.Text.Encoding]::ASCII)
    $r = & cscript.exe //nologo $t 2>$null
    [System.IO.File]::Delete($t)
    $useVbs = ($r -eq 'ok')
} catch { $useVbs = $false }

if ($useVbs) {
    $content = 'CreateObject("WScript.Shell").Run "powershell.exe {0}", 0, False' -f ($psArgs -replace '"', '""')
    if ($PSCmdlet.ShouldProcess($vbs, '写入无窗口启动包装')) { Set-Content -Path $vbs -Value $content -Encoding ASCII }
    $action = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('//B //Nologo "{0}"' -f $vbs)
} else {
    Write-Warning 'VBScript 不可用，改为直接启动 PowerShell；登录时可能闪一下窗口'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $psArgs
}

$user = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
$trigger.Delay = 'PT{0}S' -f $DelaySeconds
if ($RepeatMinutes -gt 0) {
    $rep = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    $trigger.Repetition = $rep.Repetition
}
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew -Hidden
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($TaskName, '注册计划任务')) {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force -Description '登录后静默自检代理环境：v2rayN、WARP、系统代理、出口国家、入口延迟' | Out-Null
    $repeatText = ''
    if ($RepeatMinutes -gt 0) { $repeatText = '，之后每 {0} 分钟复查' -f $RepeatMinutes }
    Write-Output ('已注册计划任务 {0}：登录后 {1} 秒运行{2}，无窗口。' -f $TaskName, $DelaySeconds, $repeatText)
    Write-Output ('立即试运行：Start-ScheduledTask -TaskName {0}' -f $TaskName)
    Write-Output ('日志：{0}' -f (Join-Path $dir 'ensure-proxy.log'))
}
