#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$Root,
    [string]$Output
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($Output)) { $Output = Join-Path $Root 'release\zentao-mcp-windows.zip' }

$server = Join-Path $Root 'server'
$windows = Join-Path $Root 'windows'
if (-not (Test-Path -LiteralPath (Join-Path $server 'package.json') -PathType Leaf)) { throw '缺少 server/package.json。' }
if (-not (Test-Path -LiteralPath (Join-Path $windows 'zentao-mcp.ps1') -PathType Leaf)) { throw '缺少 windows/zentao-mcp.ps1。' }

$nodeModules = Join-Path $server 'node_modules'
if (-not (Test-Path -LiteralPath $nodeModules -PathType Container)) {
    $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $npm) { $npm = Get-Command npm -ErrorAction SilentlyContinue }
    if (-not $npm) { throw '缺少 npm。请先安装 Node.js 18 或更高版本。' }
    & $npm.Source ci --prefix $server
    if ($LASTEXITCODE -ne 0) { throw 'npm ci 失败。' }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('zentao-mcp-build.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $work 'package') -Force | Out-Null
try {
    Copy-Item -Path $server -Destination (Join-Path $work 'package') -Recurse -Force
    Copy-Item -Path $windows -Destination (Join-Path $work 'package') -Recurse -Force
    $outputParent = Split-Path -Parent $Output
    New-Item -ItemType Directory -Path $outputParent -Force | Out-Null
    Compress-Archive -Path (Join-Path $work 'package') -DestinationPath $Output -Force
    Write-Host "已生成：$Output"
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
