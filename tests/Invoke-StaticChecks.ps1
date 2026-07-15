#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$failures = [System.Collections.Generic.List[string]]::new()

function Add-Failure {
    param([Parameter(Mandatory = $true)][string]$Message)
    $failures.Add($Message)
}

function Assert-True {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Message
    )
    if (-not $Condition) {
        Add-Failure -Message $Message
    }
}

$powerShellFiles = @(
    Get-ChildItem -LiteralPath $repositoryRoot -Recurse -File |
        Where-Object Extension -In @('.ps1', '.psm1', '.psd1')
)
foreach ($file in $powerShellFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    foreach ($parseError in $parseErrors) {
        Add-Failure -Message "$($file.FullName): $($parseError.Message)"
    }
}

$hiddenLauncherPath = Join-Path $repositoryRoot 'scripts\windows\Run-CodexSshTaskHidden.vbs'
$installerPath = Join-Path $repositoryRoot 'scripts\windows\Install-CodexSshTunnelManager.ps1'
Assert-True -Condition (Test-Path -LiteralPath $hiddenLauncherPath -PathType Leaf) -Message 'The no-console task launcher is missing.'
if (Test-Path -LiteralPath $hiddenLauncherPath -PathType Leaf) {
    $hiddenLauncherContent = Get-Content -LiteralPath $hiddenLauncherPath -Raw
    Assert-True -Condition ($hiddenLauncherContent -match 'shell\.Run\(command,\s*0,\s*True\)') -Message 'The task launcher must hide the child window and wait for completion.'

    $cscriptExe = Join-Path $env:SystemRoot 'System32\cscript.exe'
    if (Test-Path -LiteralPath $cscriptExe -PathType Leaf) {
        $testPowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $cscriptExe '//B' '//NoLogo' $hiddenLauncherPath $testPowerShellExe '-NoProfile' '-Command' 'exit 0'
        Assert-True -Condition ($LASTEXITCODE -eq 0) -Message 'The task launcher did not propagate a successful child exit code.'

        & $cscriptExe '//B' '//NoLogo' $hiddenLauncherPath $testPowerShellExe '-NoProfile' '-Command' 'exit 7'
        Assert-True -Condition ($LASTEXITCODE -eq 7) -Message 'The task launcher did not wait for and propagate a nonzero child exit code.'
    }
    else {
        Add-Failure -Message "Windows Script Host was not found: $cscriptExe"
    }
}

$installerContent = Get-Content -LiteralPath $installerPath -Raw
Assert-True -Condition ($installerContent -match [regex]::Escape('System32\wscript.exe')) -Message 'Scheduled tasks must use the GUI-subsystem Windows Script Host.'
Assert-True -Condition ($installerContent -match [regex]::Escape('Run-CodexSshTaskHidden.vbs')) -Message 'The installer must deploy and use the no-console task launcher.'

$exampleConfigPath = Join-Path $repositoryRoot 'config\tunnels.example.psd1'
$modulePath = Join-Path $repositoryRoot 'scripts\windows\CodexSshTunnel.Common.psm1'
Import-Module $modulePath -Force
try {
    $configuration = Import-CodexTunnelConfiguration -Path $exampleConfigPath
}
catch {
    Add-Failure -Message "Example configuration failed validation: $($_.Exception.Message)"
    $configuration = $null
}

if ($null -ne $configuration) {
    Assert-True -Condition (@($configuration.Tunnels).Count -eq 2) -Message 'Example configuration must contain two tunnels.'

    $primaryPattern = Get-CodexRemoteSessionPattern -DevAlias 'primary-dev'
    $secondaryPattern = Get-CodexRemoteSessionPattern -DevAlias 'secondary-dev'
    $primaryCommand = 'ssh -T -v primary-dev "sh -c ... codex app-server proxy"'
    $secondaryCommand = 'ssh -T -v secondary-dev "sh -c ... codex app-server proxy"'
    $lookalikeCommand = 'ssh -T -v primary-dev-extra "sh -c ... codex app-server proxy"'
    $unrelatedCommand = 'ssh -T primary-dev hostname'

    Assert-True -Condition ($primaryCommand -match $primaryPattern) -Message 'Primary session pattern did not match its own host.'
    Assert-True -Condition (-not ($lookalikeCommand -match $primaryPattern)) -Message 'Primary session pattern incorrectly matched a lookalike host.'
    Assert-True -Condition ($secondaryCommand -match $secondaryPattern) -Message 'Secondary session pattern did not match its own host.'
    Assert-True -Condition (-not ($unrelatedCommand -match $primaryPattern)) -Message 'A non-Codex SSH command incorrectly matched the demand signal.'
}

$scanFiles = @(
    Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts'),(Join-Path $repositoryRoot 'config'),(Join-Path $repositoryRoot 'examples') -Recurse -File
)
$privateKeyPattern = '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----'
$unsafePatterns = @(
    'StrictHostKeyChecking\s+no',
    'GatewayPorts\s+yes',
    'RemoteForward\s+(0\.0\.0\.0|\*)',
    '-----BEGIN (OPENSSH |RSA |EC |DSA )?PRIVATE KEY-----',
    '(gh[pousr]_|github_pat_|glpat-|sk-)[A-Za-z0-9_-]{16,}'
)
foreach ($file in $scanFiles) {
    $content = Get-Content -LiteralPath $file.FullName -Raw
    if ($content -match $privateKeyPattern) {
        Add-Failure -Message "Private-key marker found in $($file.FullName)."
    }
    foreach ($pattern in $unsafePatterns) {
        if ($content -match $pattern) {
            Add-Failure -Message "Unsafe SSH pattern '$pattern' found in $($file.FullName)."
        }
    }
}

$gitignore = Get-Content -LiteralPath (Join-Path $repositoryRoot '.gitignore') -Raw
Assert-True -Condition ($gitignore -match '/config/tunnels\.psd1') -Message 'Machine-local config/tunnels.psd1 must be ignored.'

$exampleSshPath = Join-Path $repositoryRoot 'examples\ssh_config'
$exampleSsh = Get-Content -LiteralPath $exampleSshPath -Raw
$exampleHostNames = @(
    [regex]::Matches($exampleSsh, '(?m)^\s*HostName\s+(\S+)\s*$') |
        ForEach-Object { $_.Groups[1].Value }
)
$exampleUsers = @(
    [regex]::Matches($exampleSsh, '(?m)^\s*User\s+(\S+)\s*$') |
        ForEach-Object { $_.Groups[1].Value }
)
Assert-True -Condition ($exampleHostNames.Count -gt 0) -Message 'The SSH example must contain at least one HostName.'
Assert-True -Condition (@($exampleHostNames | Where-Object { $_ -notmatch '\.example\.com$' }).Count -eq 0) -Message 'SSH examples must use reserved example.com host names.'
Assert-True -Condition (@($exampleUsers | Where-Object { $_ -ne 'devuser' }).Count -eq 0) -Message 'SSH examples must use the generic devuser account.'

if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Warning $_ }
    throw "Static validation failed with $($failures.Count) error(s)."
}

Write-Host "Static checks passed for $($powerShellFiles.Count) PowerShell/data files." -ForegroundColor Green
