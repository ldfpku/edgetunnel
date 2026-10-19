<#
.SYNOPSIS
  管理员打包：把同事一键配置包连同节点 UUID 压成一个 zip，同事解压后零输入即可运行。

.DESCRIPTION
  从本机被 Git 忽略的 V2RAYN-PRIVATE.md 读取节点 UUID（或用 -Uuid 指定），写成 uuid.txt，
  与 README.md、Setup-Nodes.ps1、setup-nodes.cmd、setup-nodes.command、setup-nodes.sh 一起压缩。
  uuid.txt 只写进临时目录和 zip，不会留在仓库里。zip 含凭据，只通过私下渠道发送。

.PARAMETER Uuid       节点 UUID；不传则从 -PrivateDoc 读取第一个 UUIDv4。
.PARAMETER PrivateDoc 私密文件路径，默认仓库根目录的 V2RAYN-PRIVATE.md。
.PARAMETER OutFile    输出 zip，默认桌面上的 smj-colleague-kit.zip。
.PARAMETER NoUuid     不放入 uuid.txt（同事运行时自行输入 UUID）。

.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pack-Kit.ps1
.EXAMPLE
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Pack-Kit.ps1 -OutFile D:\发给同事\smj-colleague-kit.zip
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
  [string]$Uuid = '',
  [string]$PrivateDoc = '',
  [string]$OutFile = '',
  [switch]$NoUuid
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$kit = $PSScriptRoot
$files = @('README.md', 'Setup-Nodes.ps1', 'setup-nodes.cmd', 'setup-nodes.command', 'setup-nodes.sh')
foreach ($f in $files) { if (-not (Test-Path (Join-Path $kit $f))) { throw "缺少 $f，请在仓库的 tools\colleague-kit 目录运行。" } }
if (-not $PrivateDoc) { $PrivateDoc = Join-Path $kit '..\..\V2RAYN-PRIVATE.md' }
if (-not $OutFile) { $OutFile = Join-Path ([Environment]::GetFolderPath('Desktop')) 'smj-colleague-kit.zip' }
if (-not [IO.Path]::IsPathRooted($OutFile)) { $OutFile = Join-Path (Get-Location).ProviderPath $OutFile }
$OutFile = [IO.Path]::GetFullPath($OutFile)

$uuidRe = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}'
if (-not $NoUuid) {
  if (-not $Uuid) {
    if (-not (Test-Path $PrivateDoc)) { throw "找不到 $PrivateDoc；用 -Uuid 指定 UUID，或 -NoUuid 不放入。" }
    $m = [regex]::Match((Get-Content $PrivateDoc -Raw), $uuidRe)
    if (-not $m.Success) { throw "在 $PrivateDoc 中没有找到 UUIDv4。" }
    $Uuid = $m.Value
  }
  $Uuid = $Uuid.Trim().ToLowerInvariant()
  if ($Uuid -notmatch ('^' + $uuidRe + '$')) { throw 'UUID 格式不正确，需要 UUIDv4。' }
}

$staging = Join-Path ([IO.Path]::GetTempPath()) ('smj-kit-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $staging | Out-Null
try {
  foreach ($f in $files) { Copy-Item (Join-Path $kit $f) (Join-Path $staging $f) }
  if (-not $NoUuid) { [IO.File]::WriteAllText((Join-Path $staging 'uuid.txt'), $Uuid + "`n", (New-Object System.Text.UTF8Encoding $false)) }
  if (Test-Path $OutFile) { Remove-Item $OutFile -Force }
  Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $OutFile -CompressionLevel Optimal
} finally {
  Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
$entries = @($files)
if (-not $NoUuid) { $entries += 'uuid.txt' }
Write-Host ('已生成 {0}（{1:N0} KB）：{2}' -f $OutFile, ((Get-Item $OutFile).Length / 1KB), ($entries -join '、')) -ForegroundColor Green
if ($NoUuid) { Write-Host '未放入 uuid.txt，同事运行时需要自行输入 UUID。' }
else { Write-Host '包内 uuid.txt 含节点凭据：只通过私下渠道发给同事，不要上传到公开位置。' -ForegroundColor Yellow }
Write-Host '同事侧：Windows 解压后双击 setup-nodes.cmd；macOS 按 README 第 1 节在终端运行一次。'
