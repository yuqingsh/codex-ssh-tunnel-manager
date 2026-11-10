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
$logDir = Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnels'
$logPath = Join-Path $logDir 'watchdog.log'
$failureObservationSeconds = 2
$stableResetSeconds = 60
$targets = @(
    foreach ($tunnel in $configuration.Tunnels) {
        [PSCustomObject]@{
            DevAlias = [string]$tunnel.DevAlias
            ProxyAlias = [string]$tunnel.ProxyAlias
            TaskName = [string]$tunnel.TaskName
            ProcessPattern = Get-CodexRemoteSessionPattern -DevAlias ([string]$tunnel.DevAlias)
            LogPath = Join-Path $logDir ("{0}.log" -f [string]$tunnel.ProxyAlias)
        }
    }
)
$lastSeenUtc = @{}
$tunnelStates = @{}

New-Item -ItemType Directory -Path $logDir -Force | Out-Null

function Write-ControllerLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    "$(Get-Date -Format o) [controller:$PID] $Message" | Add-Content -LiteralPath $logPath
}

function Reset-TunnelRetryState {
    param(
        [Parameter(Mandatory = $true)]
        [PSCustomObject]$State,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [switch]$KeepStartUtc
    )

    if ($State.Failures -gt 0 -or $State.LastKind -ne '') {
        Write-ControllerLog "Resetting retry backoff for tunnel '$($State.Name)' after $Reason (last kind: $($State.LastKind), failures: $($State.Failures))."
    }

    $State.Failures = 0
    $State.NextAttemptUtc = $null
    $State.LastKind = ''
    if (-not $KeepStartUtc) {
        $State.StartUtc = $null
    }
}

foreach ($target in $targets) {
    $lastSeenUtc[$target.TaskName] = $null
    $tunnelStates[$target.TaskName] = [PSCustomObject]@{
        Name = $target.DevAlias
        Failures = 0
        NextAttemptUtc = $null
        StartUtc = $null
        LastKind = ''
    }
}

Write-ControllerLog "Demand controller started; poll=$($runtime.PollSeconds)s, stop-grace=$($runtime.StopGraceMinutes)m."

while ($true) {
    try {
        $nowUtc = [DateTime]::UtcNow
        $sshProcesses = @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'" -ErrorAction Stop
        )

        foreach ($target in $targets) {
            $state = $tunnelStates[$target.TaskName]
            $isInUse = @($sshProcesses | Where-Object {
                $null -ne $_.CommandLine -and $_.CommandLine -match $target.ProcessPattern
            }).Count -gt 0
            $task = Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop

            if ($isInUse) {
                $lastSeenUtc[$target.TaskName] = $nowUtc

                if ($task.State -eq 'Running') {
                    if ($null -eq $state.StartUtc) {
                        # Adopt a task that was already running when the controller started.
                        $state.StartUtc = $nowUtc
                    }
                    elseif (($nowUtc - [DateTime]$state.StartUtc).TotalSeconds -ge $stableResetSeconds) {
                        Reset-TunnelRetryState -State $state -Reason "running steadily for $stableResetSeconds seconds" -KeepStartUtc
                    }
                    continue
                }

                if ($null -ne $state.StartUtc) {
                    if (($nowUtc - [DateTime]$state.StartUtc).TotalSeconds -lt $failureObservationSeconds) {
                        continue
                    }

                    $failureKind = Get-CodexTunnelFailureKind -LogPath $target.LogPath
                    $state.Failures = $state.Failures + 1
                    $retryDelaySeconds = Get-CodexRetryDelay -Failures $state.Failures -Kind $failureKind
                    $state.NextAttemptUtc = $nowUtc.AddSeconds([double]$retryDelaySeconds)
                    $state.LastKind = $failureKind
                    $state.StartUtc = $null

                    $failureDetail = ''
                    if ($failureKind -eq 'port-conflict') {
                        $failureDetail = ' The remote port is already in use (possibly another client or a stale connection).'
                    }
                    Write-ControllerLog "Tunnel '$($target.TaskName)' for $($target.DevAlias) failed (failure kind: $failureKind).$failureDetail Retrying in $retryDelaySeconds seconds (failure $($state.Failures))."
                    continue
                }

                if ($null -ne $state.NextAttemptUtc -and $nowUtc -lt [DateTime]$state.NextAttemptUtc) {
                    continue
                }

                $retryNote = ''
                if ($state.Failures -gt 0) {
                    $retryNote = " after $($state.Failures) failure(s), last kind: $($state.LastKind)"
                }
                Write-ControllerLog "Detected active Codex remote session for $($target.DevAlias); starting '$($target.TaskName)'$retryNote."
                Start-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop
                $state.StartUtc = [DateTime]::UtcNow
                Start-Sleep -Milliseconds 500
                $newState = (Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop).State
                Write-ControllerLog "Task '$($target.TaskName)' state after demand start: $newState."
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
                    Reset-TunnelRetryState -State $state -Reason 'demand stop'
                    Start-Sleep -Milliseconds 500
                    $newState = (Get-ScheduledTask -TaskName $target.TaskName -ErrorAction Stop).State
                    Write-ControllerLog "Task '$($target.TaskName)' state after demand stop: $newState."
                }
                continue
            }

            $lastSeenUtc[$target.TaskName] = $null
            Reset-TunnelRetryState -State $state -Reason 'idle task'
        }
    }
    catch {
        Write-ControllerLog "Demand-controller cycle error: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds ([int]$runtime.PollSeconds)
}
