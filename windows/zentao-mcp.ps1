#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$CredentialsFile,
    [string]$ServerFile
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CredentialsFile)) {
    $CredentialsFile = Join-Path $env:APPDATA 'zentao-mcp\credentials.xml'
}
if ([string]::IsNullOrWhiteSpace($ServerFile)) {
    $ServerFile = Join-Path $env:LOCALAPPDATA 'zentao-mcp\server\server.cjs'
}

if (-not (Test-Path -LiteralPath $CredentialsFile -PathType Leaf)) {
    throw "缺少禅道凭据文件：$CredentialsFile。请重新运行 install.ps1。"
}
if (-not (Test-Path -LiteralPath $ServerFile -PathType Leaf)) {
    throw "缺少 MCP 服务文件：$ServerFile。请重新运行 install.ps1。"
}

$node = Get-Command node.exe -ErrorAction SilentlyContinue
if (-not $node) {
    $node = Get-Command node -ErrorAction SilentlyContinue
}
if (-not $node) {
    throw '未找到 Node.js。请安装 Node.js 18 或更高版本后重试。'
}

$config = Import-Clixml -LiteralPath $CredentialsFile
if (-not $config.Credential -or -not $config.Credential.Password) {
    throw "禅道凭据文件格式无效：$CredentialsFile。请重新运行 install.ps1。"
}

$env:ZENTAO_URL = [string]$config.ZentaoUrl
$env:ZENTAO_ACCOUNT = [string]$config.Credential.UserName
$passwordPointer = [IntPtr]::Zero
try {
    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($config.Credential.Password)
    $env:ZENTAO_PASSWORD = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
    & $node.Source $ServerFile @args
    exit $LASTEXITCODE
}
finally {
    if ($passwordPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
    }
    Remove-Item Env:ZENTAO_PASSWORD -ErrorAction SilentlyContinue
}
