#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $true)]
    [string]$ProxyAlias
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodexSshTunnel.Common.psm1') -Force
$configuration = Import-CodexTunnelConfiguration -Path $ConfigPath
$matches = @($configuration.Tunnels | Where-Object { $_.ProxyAlias -eq $ProxyAlias })
if ($matches.Count -ne 1) {
    throw "Proxy alias '$ProxyAlias' must match exactly one configured tunnel."
}

$runtime = $configuration.Runtime
$sshExe = Join-Path $env:WINDIR 'System32\OpenSSH\ssh.exe'
$logDir = Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnels'
$logPath = Join-Path $logDir "$ProxyAlias.log"
$exitCode = 1

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-TunnelLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    "$(Get-Date -Format o) [launcher:$PID] $Message" | Add-Content -LiteralPath $logPath
}

try {
    if (-not (Test-Path -LiteralPath $sshExe -PathType Leaf)) {
        throw "OpenSSH client was not found at $sshExe."
    }

    Write-TunnelLog "Launcher started for $ProxyAlias."

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$runtime.ProxyWaitSeconds)
    $proxyReady = $false
    while ([DateTime]::UtcNow -lt $deadline) {
        if (Test-CodexTcpEndpoint -HostName ([string]$runtime.LocalProxyHost) -Port ([int]$runtime.LocalProxyPort)) {
            $proxyReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }

    if (-not $proxyReady) {
        Write-TunnelLog "Local proxy $($runtime.LocalProxyHost):$($runtime.LocalProxyPort) was not ready after $($runtime.ProxyWaitSeconds) seconds."
        $exitCode = 2
    }
    else {
        $sshArguments = @(
            '-N'
            '-T'
            '-o', 'BatchMode=yes'
            '-o', 'ConnectTimeout=15'
            '-o', 'ServerAliveInterval=30'
            '-o', 'ServerAliveCountMax=3'
            '-o', 'ExitOnForwardFailure=yes'
            $ProxyAlias
        )

        Write-TunnelLog "Starting ssh.exe for $ProxyAlias."
        & $sshExe @sshArguments 2>> $logPath
        $exitCode = $LASTEXITCODE
        Write-TunnelLog "ssh.exe for $ProxyAlias exited with code $exitCode."
    }
}
catch {
    Write-TunnelLog "Launcher error for ${ProxyAlias}: $($_.Exception.Message)"
    $exitCode = 1
}
finally {
    Write-TunnelLog "Launcher finishing for $ProxyAlias with code $exitCode."
}

exit $exitCode
