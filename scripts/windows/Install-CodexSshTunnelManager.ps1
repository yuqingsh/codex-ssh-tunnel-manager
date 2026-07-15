#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$ConfigPath,

    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'Codex\ssh-tunnel-manager')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path $PSScriptRoot '..\..\config\tunnels.psd1'
}

$modulePath = Join-Path $PSScriptRoot 'CodexSshTunnel.Common.psm1'
Import-Module $modulePath -Force
$configuration = Import-CodexTunnelConfiguration -Path $ConfigPath
$runtime = $configuration.Runtime
$resolvedInstallRoot = [IO.Path]::GetFullPath($InstallRoot)

if ($resolvedInstallRoot.IndexOf('"') -ge 0) {
    throw 'InstallRoot cannot contain a double quote.'
}
if (-not $PSCmdlet.ShouldProcess($resolvedInstallRoot, 'Install Codex SSH tunnel manager and replace configured scheduled tasks')) {
    return
}

function ConvertTo-CodexTaskArgument {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ($Value.IndexOf('"') -ge 0) {
        throw 'Scheduled-task arguments cannot contain a double quote.'
    }

    return '"' + $Value + '"'
}

function Join-CodexTaskArguments {
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ArgumentList
    )

    return (@($ArgumentList | ForEach-Object { ConvertTo-CodexTaskArgument -Value $_ }) -join ' ')
}

$sshProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'")
$activeCodexHosts = @{}
foreach ($tunnel in $configuration.Tunnels) {
    $pattern = Get-CodexRemoteSessionPattern -DevAlias ([string]$tunnel.DevAlias)
    $activeCodexHosts[[string]$tunnel.DevAlias] = @($sshProcesses | Where-Object {
        $null -ne $_.CommandLine -and $_.CommandLine -match $pattern
    }).Count -gt 0
}

New-Item -ItemType Directory -Path $resolvedInstallRoot -Force | Out-Null
$backupRoot = Join-Path $resolvedInstallRoot 'backups'
$installedConfigPath = Join-Path $resolvedInstallRoot 'tunnels.psd1'
if (Test-Path -LiteralPath $installedConfigPath -PathType Leaf) {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    Copy-Item -LiteralPath $installedConfigPath -Destination (Join-Path $backupRoot "tunnels-$stamp.psd1")
}

$filesToInstall = @(
    'CodexSshTunnel.Common.psm1',
    'Run-CodexSshTaskHidden.vbs',
    'Start-CodexSshTunnel.ps1',
    'Watch-CodexSshTunnels.ps1',
    'Get-CodexSshTunnelStatus.ps1',
    'Uninstall-CodexSshTunnelManager.ps1'
)
foreach ($file in $filesToInstall) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $resolvedInstallRoot $file) -Force
}
Copy-Item -LiteralPath (Resolve-Path -LiteralPath $ConfigPath).Path -Destination $installedConfigPath -Force

$taskNames = @([string]$runtime.ControllerTaskName) + @($configuration.Tunnels | ForEach-Object { [string]$_.TaskName })
foreach ($taskName in $taskNames) {
    if ($null -ne (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 2

$sshProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'ssh.exe'")
foreach ($tunnel in $configuration.Tunnels) {
    $pattern = Get-CodexProxyTunnelPattern -ProxyAlias ([string]$tunnel.ProxyAlias)
    $orphanedProcesses = @($sshProcesses | Where-Object {
        $null -ne $_.CommandLine -and $_.CommandLine -match $pattern
    })
    foreach ($process in $orphanedProcesses) {
        Write-Verbose "Stopping old tunnel process $($process.ProcessId) for $($tunnel.ProxyAlias)."
        Stop-Process -Id $process.ProcessId -Force
    }
}

$powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
$hiddenLauncherPath = Join-Path $resolvedInstallRoot 'Run-CodexSshTaskHidden.vbs'
foreach ($requiredExecutable in @($powerShellExe, $wscriptExe)) {
    if (-not (Test-Path -LiteralPath $requiredExecutable -PathType Leaf)) {
        throw "Required executable not found: $requiredExecutable"
    }
}
$userId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType Interactive -RunLevel Limited
$tunnelSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

foreach ($tunnel in $configuration.Tunnels) {
    $launcherPath = Join-Path $resolvedInstallRoot 'Start-CodexSshTunnel.ps1'
    $arguments = Join-CodexTaskArguments -ArgumentList @(
        '//B',
        '//NoLogo',
        $hiddenLauncherPath,
        $powerShellExe,
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $launcherPath,
        '-ConfigPath',
        $installedConfigPath,
        '-ProxyAlias',
        [string]$tunnel.ProxyAlias
    )
    $action = New-ScheduledTaskAction -Execute $wscriptExe -Argument $arguments

    Register-ScheduledTask `
        -TaskName ([string]$tunnel.TaskName) `
        -Action $action `
        -Settings $tunnelSettings `
        -Principal $principal `
        -Description "On-demand Codex SSH reverse tunnel for $($tunnel.DevAlias)." `
        -Force | Out-Null
}

$controllerPath = Join-Path $resolvedInstallRoot 'Watch-CodexSshTunnels.ps1'
$controllerArguments = Join-CodexTaskArguments -ArgumentList @(
    '//B',
    '//NoLogo',
    $hiddenLauncherPath,
    $powerShellExe,
    '-NoProfile',
    '-NonInteractive',
    '-WindowStyle',
    'Hidden',
    '-ExecutionPolicy',
    'Bypass',
    '-File',
    $controllerPath,
    '-ConfigPath',
    $installedConfigPath
)
$controllerAction = New-ScheduledTaskAction -Execute $wscriptExe -Argument $controllerArguments
$logonTrigger = New-ScheduledTaskTrigger -AtLogOn
$recoveryTrigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 1)
$controllerSettings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero) `
    -RestartCount 999 `
    -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask `
    -TaskName ([string]$runtime.ControllerTaskName) `
    -Action $controllerAction `
    -Trigger @($logonTrigger, $recoveryTrigger) `
    -Settings $controllerSettings `
    -Principal $principal `
    -Description 'Starts and stops Codex SSH reverse tunnels according to active remote Codex app-server sessions.' `
    -Force | Out-Null

& wevtutil.exe set-log 'Microsoft-Windows-TaskScheduler/Operational' /enabled:true /quiet:true
if ($LASTEXITCODE -ne 0) {
    Write-Warning "Task Scheduler history could not be enabled; wevtutil exit code: $LASTEXITCODE."
}

foreach ($tunnel in $configuration.Tunnels) {
    if ($activeCodexHosts[[string]$tunnel.DevAlias]) {
        Start-ScheduledTask -TaskName ([string]$tunnel.TaskName)
    }
}
Start-ScheduledTask -TaskName ([string]$runtime.ControllerTaskName)

Write-Host "Installed Codex SSH tunnel manager in $resolvedInstallRoot" -ForegroundColor Green
Write-Host "Controller task: $($runtime.ControllerTaskName)" -ForegroundColor Green
