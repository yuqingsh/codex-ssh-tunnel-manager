#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnel-manager\tunnels.psd1'),

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnel-manager'),

    [switch]$RemoveInstalledFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'CodexSshTunnel.Common.psm1'
Import-Module $modulePath -Force
$configuration = Import-CodexTunnelConfiguration -Path $ConfigPath
$runtime = $configuration.Runtime

if (-not $PSCmdlet.ShouldProcess('configured scheduled tasks and tunnel processes', 'Uninstall Codex SSH tunnel manager')) {
    return
}

$taskNames = @([string]$runtime.ControllerTaskName) + @($configuration.Tunnels | ForEach-Object { [string]$_.TaskName })
foreach ($taskName in $taskNames) {
    if ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    }
}

$sshProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'")
foreach ($tunnel in $configuration.Tunnels) {
    $pattern = Get-CodexProxyTunnelPattern -ProxyAlias ([string]$tunnel.ProxyAlias)
    foreach ($process in @($sshProcesses | Where-Object {
        $null -ne $_.CommandLine -and $_.CommandLine -match $pattern
    })) {
        Stop-Process -Id $process.ProcessId -Force
    }
}

if ($RemoveInstalledFiles) {
    $resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    $allowedBase = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Codex')).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if (-not $resolvedInstallRoot.StartsWith($allowedBase + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove install root outside $allowedBase."
    }
    if (Test-Path -LiteralPath $resolvedInstallRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedInstallRoot -Recurse -Force
    }
}

Write-Host 'Codex SSH tunnel manager tasks and tunnel processes were removed.' -ForegroundColor Green
