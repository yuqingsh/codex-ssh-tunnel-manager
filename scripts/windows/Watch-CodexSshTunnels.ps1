#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot 'CodexSshTunnel.Common.psm1') -Force
$configuration = Import-CodexTunnelConfiguration -Path $ConfigPath
$runtime = $configuration.Runtime
$targets = @(
    foreach ($tunnel in $configuration.Tunnels) {
        [PSCustomObject]@{
            DevAlias = [string]$tunnel.DevAlias
            TaskName = [string]$tunnel.TaskName
            ProcessPattern = Get-CodexRemoteSessionPattern -DevAlias ([string]$tunnel.DevAlias)
        }
    }
)

$logDir = Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnels'
$logPath = Join-Path $logDir 'watchdog.log'
$lastSeenUtc = @{}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-ControllerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    "$(Get-Date -Format o) [controller:$PID] $Message" | Add-Content -LiteralPath $logPath
}

foreach ($target in $targets) {
    $lastSeenUtc[$target.TaskName] = $null
}

Write-ControllerLog "Demand controller started; poll=$($runtime.PollSeconds)s, stop-grace=$($runtime.StopGraceMinutes)m."

while ($true) {
    try {
        $nowUtc = [DateTime]::UtcNow
        $sshProcesses = @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction Stop
        )

        foreach ($target in $targets) {
            $isInUse = @($sshProcesses | Where-Object {
                $null -ne $_.CommandLine -and $_.CommandLine -match $target.ProcessPattern
            }).Count -gt 0
            $task = Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop

            if ($isInUse) {
                $lastSeenUtc[$target.TaskName] = $nowUtc
                if ($task.State -ne 'Running') {
                    Write-ControllerLog "Detected active Codex remote session for $($target.DevAlias); starting '$($target.TaskName)'."
                    Start-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop
                    Start-Sleep -Milliseconds 500
                    $newState = (Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop).State
                    Write-ControllerLog "Task '$($target.TaskName)' state after demand start: $newState."
                }
                continue
            }

            if ($task.State -eq 'Running') {
                if ($null -eq $lastSeenUtc[$target.TaskName]) {
                    $lastSeenUtc[$target.TaskName] = $nowUtc
                    Write-ControllerLog "No active Codex remote session for $($target.DevAlias); starting $($runtime.StopGraceMinutes)-minute stop grace."
                    continue
                }

                $idleFor = $nowUtc - [DateTime]$lastSeenUtc[$target.TaskName]
                if ($idleFor.TotalMinutes -ge [int]$runtime.StopGraceMinutes) {
                    Write-ControllerLog "No active Codex remote session for $($target.DevAlias) for $([Math]::Floor($idleFor.TotalMinutes)) minutes; stopping '$($target.TaskName)'."
                    Stop-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop
                    $lastSeenUtc[$target.TaskName] = $null
                    Start-Sleep -Milliseconds 500
                    $newState = (Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop).State
                    Write-ControllerLog "Task '$($target.TaskName)' state after demand stop: $newState."
                }
            }
            else {
                $lastSeenUtc[$target.TaskName] = $null
            }
        }
    }
    catch {
        Write-ControllerLog "Demand-controller cycle error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds ([int]$runtime.PollSeconds)
}
