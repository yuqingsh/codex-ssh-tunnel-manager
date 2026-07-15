#Requires -Version 5.1

[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnel-manager\tunnels.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodexSshTunnel.Common.psm1') -Force
$configuration = Import-CodexTunnelConfiguration -Path $ConfigPath
$runtime = $configuration.Runtime
$sshProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'")

$controllerTask = Get-ScheduledTask -TaskName $runtime.ControllerTaskName -ErrorAction SilentlyContinue
[PSCustomObject]@{
    Type = 'Controller'
    Name = [string]$runtime.ControllerTaskName
    DevAlias = $null
    ProxyAlias = $null
    TaskState = if ($null -eq $controllerTask) { 'Missing' } else { [string]$controllerTask.State }
    TriggerCount = if ($null -eq $controllerTask) {
        $null
    }
    elseif ($null -eq $controllerTask.Triggers) {
        0
    }
    else {
        $controllerTask.Triggers.Count
    }
    ActiveCodexSessions = $null
    TunnelProcesses = $null
    ProcessIds = $null
    LocalProxyReachable = Test-CodexTcpEndpoint -HostName ([string]$runtime.LocalProxyHost) -Port ([int]$runtime.LocalProxyPort)
}

foreach ($tunnel in $configuration.Tunnels) {
    $sessionPattern = Get-CodexRemoteSessionPattern -DevAlias ([string]$tunnel.DevAlias)
    $tunnelPattern = Get-CodexProxyTunnelPattern -ProxyAlias ([string]$tunnel.ProxyAlias)
    $activeSessions = @($sshProcesses | Where-Object {
        $null -ne $_.CommandLine -and $_.CommandLine -match $sessionPattern
    })
    $tunnelProcesses = @($sshProcesses | Where-Object {
        $null -ne $_.CommandLine -and $_.CommandLine -match $tunnelPattern
    })
    $task = Get-ScheduledTask -TaskName $tunnel.TaskName -ErrorAction SilentlyContinue

    [PSCustomObject]@{
        Type = 'Tunnel'
        Name = [string]$tunnel.Name
        DevAlias = [string]$tunnel.DevAlias
        ProxyAlias = [string]$tunnel.ProxyAlias
        TaskState = if ($null -eq $task) { 'Missing' } else { [string]$task.State }
        TriggerCount = if ($null -eq $task) {
            $null
        }
        elseif ($null -eq $task.Triggers) {
            0
        }
        else {
            $task.Triggers.Count
        }
        ActiveCodexSessions = $activeSessions.Count
        TunnelProcesses = $tunnelProcesses.Count
        ProcessIds = @($tunnelProcesses | ForEach-Object { $_.ProcessId }) -join ','
        LocalProxyReachable = $null
    }
}
