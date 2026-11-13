#requires -Version 5.1
[CmdletBinding()]
param(
    [string]$PackageUrl,
    [string]$PackagePath,
    [string]$InstallRoot,
    [string]$ConfigRoot,
    [switch]$NonInteractive,
    [switch]$SkipCodex
)

$ErrorActionPreference = 'Stop'
$Version = '1.2.0'
$DefaultPackageUrl = 'https://github.com/yiyang0663/zentao-mcp/releases/download/v1.2.0/zentao-mcp-windows.zip'

function Get-FirstCommand {
    param([string[]]$Names)
    foreach ($name in $Names) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) { return $command }
    }
    return $null
}

function Read-TextValue {
    param(
        [string]$Prompt,
        [string]$EnvironmentName,
        [string]$ExistingValue,
        [switch]$Required
    )
    $value = [Environment]::GetEnvironmentVariable($EnvironmentName)
    if ([string]::IsNullOrWhiteSpace($value) -and $NonInteractive) {
        $value = $ExistingValue
    }
    if ([string]::IsNullOrWhiteSpace($value) -and -not $NonInteractive) {
        $suffix = if ([string]::IsNullOrWhiteSpace($ExistingValue)) { '' } else { " [$ExistingValue]" }
        $value = Read-Host "$Prompt$suffix"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $ExistingValue }
    }
    if ($Required -and [string]::IsNullOrWhiteSpace($value)) {
        throw "$Prompt 不能为空。"
    }
    return $value
}

function Read-PasswordValue {
    param([object]$ExistingCredential)
    $plain = [Environment]::GetEnvironmentVariable('ZENTAO_PASSWORD')
    if (-not [string]::IsNullOrWhiteSpace($plain)) {
        return ConvertTo-SecureString -String $plain -AsPlainText -Force
    }
    if ($NonInteractive) {
        if ($ExistingCredential -and $ExistingCredential.Password) { return $ExistingCredential.Password }
        throw 'ZENTAO_PASSWORD 不能为空。'
    }
    $password = Read-Host '禅道密码（输入内容不会显示；重复安装时直接回车保留已有密码）' -AsSecureString
    if ($password.Length -eq 0 -and $ExistingCredential -and $ExistingCredential.Password) {
        return $ExistingCredential.Password
    }
    if ($password.Length -eq 0) { throw '禅道密码不能为空。' }
    return $password
}

function Protect-CredentialFile {
    param([string]$Path)
    try {
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    }
    catch {
        Write-Warning "无法进一步收紧凭据文件 ACL，文件仍使用 Windows 用户级加密：$($_.Exception.Message)"
    }
}

if ([string]::IsNullOrWhiteSpace($PackageUrl)) {
    $PackageUrl = [Environment]::GetEnvironmentVariable('ZENTAO_MCP_WINDOWS_PACKAGE_URL')
}
if ([string]::IsNullOrWhiteSpace($PackageUrl)) { $PackageUrl = $DefaultPackageUrl }
if ([string]::IsNullOrWhiteSpace($PackagePath)) {
    $PackagePath = [Environment]::GetEnvironmentVariable('ZENTAO_MCP_WINDOWS_PACKAGE_PATH')
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
    $InstallRoot = [Environment]::GetEnvironmentVariable('ZENTAO_MCP_INSTALL_ROOT')
}
if ([string]::IsNullOrWhiteSpace($InstallRoot)) { $InstallRoot = Join-Path $env:LOCALAPPDATA 'zentao-mcp' }
if ([string]::IsNullOrWhiteSpace($ConfigRoot)) {
    $ConfigRoot = [Environment]::GetEnvironmentVariable('ZENTAO_MCP_CONFIG_ROOT')
}
if ([string]::IsNullOrWhiteSpace($ConfigRoot)) { $ConfigRoot = Join-Path $env:APPDATA 'zentao-mcp' }

$node = Get-FirstCommand @('node.exe', 'node')
if (-not $node) {
    throw '未找到 Node.js。请先安装 Node.js 18 或更高版本，例如：winget install OpenJS.NodeJS.LTS'
}
$nodeVersion = (& $node.Source --version).Trim()
if ($LASTEXITCODE -ne 0) { throw "无法读取 Node.js 版本：$nodeVersion" }
$nodeMajor = [int]($nodeVersion.TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 18) { throw "当前 Node.js 版本过低：$nodeVersion。需要 18 或更高版本。" }

$credentialsFile = Join-Path $ConfigRoot 'credentials.xml'
$existing = $null
if (Test-Path -LiteralPath $credentialsFile -PathType Leaf) {
    try { $existing = Import-Clixml -LiteralPath $credentialsFile }
    catch { Write-Warning '已有凭据无法解密，将按首次安装重新配置。' }
}

$url = Read-TextValue '禅道地址（例如 http://192.168.1.212）' 'ZENTAO_URL' ([string]$existing.ZentaoUrl) -Required
$account = Read-TextValue '禅道账号' 'ZENTAO_ACCOUNT' ([string]$existing.Credential.UserName) -Required
$securePassword = Read-PasswordValue $existing.Credential

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('zentao-mcp.' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
try {
    $zipFile = Join-Path $tempRoot 'zentao-mcp-windows.zip'
    if ([string]::IsNullOrWhiteSpace($PackagePath)) {
        Write-Host "正在下载 Windows 安装包：$PackageUrl"
        Invoke-WebRequest -UseBasicParsing -Uri $PackageUrl -OutFile $zipFile
    }
    else {
        if (-not (Test-Path -LiteralPath $PackagePath -PathType Leaf)) { throw "找不到本地安装包：$PackagePath" }
        Copy-Item -LiteralPath $PackagePath -Destination $zipFile -Force
    }

    $extractRoot = Join-Path $tempRoot 'expanded'
    Expand-Archive -LiteralPath $zipFile -DestinationPath $extractRoot -Force
    $packageRoot = Join-Path $extractRoot 'package'
    if (-not (Test-Path -LiteralPath $packageRoot -PathType Container)) { $packageRoot = $extractRoot }
    $packageServer = Join-Path $packageRoot 'server'
    if (-not (Test-Path -LiteralPath (Join-Path $packageServer 'server.cjs') -PathType Leaf)) {
        throw 'Windows 安装包不完整：缺少 server/server.cjs。'
    }

    $installServer = Join-Path $InstallRoot 'server'
    New-Item -ItemType Directory -Path $installServer -Force | Out-Null
    Copy-Item -Path (Join-Path $packageServer '*') -Destination $installServer -Recurse -Force
    $packageWindows = Join-Path $packageRoot 'windows'
    if (Test-Path -LiteralPath $packageWindows -PathType Container) {
        Copy-Item -Path (Join-Path $packageWindows '*') -Destination $InstallRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Path $ConfigRoot -Force | Out-Null
    $credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $account, $securePassword
    [PSCustomObject]@{ Version = $Version; ZentaoUrl = $url; Credential = $credential } |
        Export-Clixml -LiteralPath $credentialsFile -Depth 4
    Protect-CredentialFile $credentialsFile

    $serverFile = Join-Path $InstallRoot 'server\server.cjs'
    $launcher = Join-Path $InstallRoot 'zentao-mcp.ps1'
    $cmdLauncher = Join-Path $InstallRoot 'zentao-mcp.cmd'
    if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) { throw '安装包缺少 Windows PowerShell 启动脚本。' }
    & $node.Source --check $serverFile
    if ($LASTEXITCODE -ne 0) { throw 'MCP 服务语法检查失败。' }

    $codexStatus = '未自动配置 Codex。'
    $codex = Get-FirstCommand @('codex.exe', 'codex')
    if (-not $SkipCodex -and $codex) {
        & $codex.Source mcp get zentao *> $null
        if ($LASTEXITCODE -eq 0) {
            $codexStatus = 'Codex 已存在 zentao 配置；如需切换到本次安装，请先执行 codex mcp remove zentao。'
        }
        else {
            & $codex.Source mcp add zentao -- powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher
            if ($LASTEXITCODE -eq 0) { $codexStatus = '已自动注册到 Codex（codex mcp add zentao）。' }
            else { $codexStatus = 'Codex 自动注册失败，请手动执行 codex mcp add zentao。' }
        }
    }
    elseif ($SkipCodex) {
        $codexStatus = '已跳过 Codex 自动配置。'
    }
    else {
        $codexStatus = "未找到 Codex CLI。手动注册：codex mcp add zentao -- powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$launcher`""
    }

    Write-Host ''
    Write-Host "安装完成（版本 $Version）。"
    Write-Host "PowerShell 启动命令：$launcher"
    Write-Host "CMD 启动命令：$cmdLauncher"
    Write-Host "凭据文件：$credentialsFile（Windows 用户级加密）"
    Write-Host $codexStatus
}
finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
