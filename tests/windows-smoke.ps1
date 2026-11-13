#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$InstallScript,
    [Parameter(Mandatory = $true)][string]$PackagePath,
    [Parameter(Mandatory = $true)][string]$ToolsListScript,
    [Parameter(Mandatory = $true)][string]$ErrorSmokeScript
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'zentao mcp smoke'
$installRoot = Join-Path $root 'local app data\zentao-mcp'
$configRoot = Join-Path $root 'roaming app data\zentao-mcp'
$fakeBin = Join-Path $root 'fake bin'
$codexState = Join-Path $root 'codex-state.txt'
$codexLog = Join-Path $root 'codex-log.txt'
New-Item -ItemType Directory -Path $fakeBin -Force | Out-Null

@"
@echo off
if "%2"=="get" if exist "$codexState" exit /b 0
if "%2"=="add" (
  echo %*>>"$codexLog"
  type nul >"$codexState"
  exit /b 0
)
exit /b 2
"@ | Set-Content -LiteralPath (Join-Path $fakeBin 'codex.cmd') -Encoding ASCII

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) { $node = Get-Command node -ErrorAction Stop }
$oldPath = $env:PATH
$env:PATH = "$(Split-Path -Parent $node.Source);$fakeBin;$oldPath"
$env:ZENTAO_URL = 'http://127.0.0.1:9'
$env:ZENTAO_ACCOUNT = 'smoke-user'
$env:ZENTAO_PASSWORD = 'smoke-password'

try {
    & $InstallScript -PackagePath $PackagePath -InstallRoot $installRoot -ConfigRoot $configRoot -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw '首次安装失败。' }
    & $InstallScript -PackagePath $PackagePath -InstallRoot $installRoot -ConfigRoot $configRoot -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw '重复安装失败。' }

    $serverFile = Join-Path $installRoot 'server\server.cjs'
    $launcher = Join-Path $installRoot 'zentao-mcp.ps1'
    $cmdLauncher = Join-Path $installRoot 'zentao-mcp.cmd'
    $credentials = Join-Path $configRoot 'credentials.xml'
    foreach ($file in @($serverFile, $launcher, $cmdLauncher, $credentials)) {
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "安装产物缺失：$file" }
    }

    & node $ToolsListScript $serverFile
    if ($LASTEXITCODE -ne 0) { throw 'tools/list 检查失败。' }
    if (-not (Test-Path -LiteralPath $codexState -PathType Leaf)) { throw 'Codex 自动注册没有发生。' }

    & node $ErrorSmokeScript 'wrong-password' $serverFile
    if ($LASTEXITCODE -ne 0) { throw '错误密码处理检查失败。' }
    & node $ErrorSmokeScript 'unavailable' $serverFile
    if ($LASTEXITCODE -ne 0) { throw '禅道服务器不可用处理检查失败。' }

    $noCodexRoot = Join-Path $root 'no codex install'
    $noCodexConfig = Join-Path $root 'no codex config'
    $env:PATH = "$(Split-Path -Parent $node.Source);$env:SystemRoot\System32"
    if (Get-Command codex -ErrorAction SilentlyContinue) { throw 'no-Codex 场景仍然发现 Codex。' }
    & $InstallScript -PackagePath $PackagePath -InstallRoot $noCodexRoot -ConfigRoot $noCodexConfig -NonInteractive
    if ($LASTEXITCODE -ne 0) { throw '没有 Codex 时安装失败。' }

    Remove-Item Env:ZENTAO_URL, Env:ZENTAO_ACCOUNT, Env:ZENTAO_PASSWORD -ErrorAction SilentlyContinue
    Write-Host 'Windows smoke test passed: first install, repeat install, path with spaces, Codex present/absent, credentials, wrong password, unavailable server, tools/list.'
}
finally {
    $env:PATH = $oldPath
}
