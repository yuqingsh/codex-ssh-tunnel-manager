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
Assert-True -Condition (@([regex]::Matches($installerContent, '-RestartCount 999')).Count -eq 1) -Message 'Only the controller task may restart itself; tunnel retries must stay under the controller backoff.'

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

$controllerScriptPath = Join-Path $repositoryRoot 'scripts\windows\Watch-CodexSshTunnels.ps1'
Assert-True -Condition (Test-Path -LiteralPath $controllerScriptPath -PathType Leaf) -Message 'The demand-controller script is missing.'
if (Test-Path -LiteralPath $controllerScriptPath -PathType Leaf) {
    $controllerContent = Get-Content -LiteralPath $controllerScriptPath -Raw
    Assert-True -Condition ($controllerContent -match 'Get-CodexTunnelFailureKind') -Message 'The demand controller must classify tunnel failures.'
    Assert-True -Condition ($controllerContent -match 'Get-CodexRetryDelay') -Message 'The demand controller must compute retry delays.'
    Assert-True -Condition ($controllerContent -match '\$tunnelStates') -Message 'The demand controller must keep in-memory retry state per tunnel.'
    Assert-True -Condition ($controllerContent -match 'NextAttemptUtc') -Message 'The demand controller must track the next allowed attempt per tunnel.'
    Assert-True -Condition ($controllerContent -match 'StartUtc') -Message 'The demand controller must track tunnel start times.'
    Assert-True -Condition ($controllerContent -match 'LastKind') -Message 'The demand controller must remember the last failure kind.'
    Assert-True -Condition ($controllerContent -match '\$stableResetSeconds\s*=\s*60') -Message 'Stable tunnels must reset their retry state after 60 seconds.'
    Assert-True -Condition ($controllerContent -match '\$failureObservationSeconds\s*=\s*2') -Message 'Failure detection must wait at least 2 seconds after a start.'
    Assert-True -Condition ($controllerContent -match 'failure kind:') -Message 'The demand controller must log the classified failure kind.'
    Assert-True -Condition ($controllerContent -notmatch 'New-ScheduledTaskTrigger') -Message 'The demand controller must not create scheduled-task triggers.'
    Assert-True -Condition ($controllerContent -match 'StopGraceMinutes') -Message 'The demand controller must keep the stop-grace logic.'
    Assert-True -Condition ($controllerContent -match 'Start-ScheduledTask') -Message 'The demand controller must still start tunnel tasks on demand.'
    Assert-True -Condition ($controllerContent -match 'Stop-ScheduledTask') -Message 'The demand controller must still stop tunnel tasks after the stop grace.'
}

$failureKindCommand = Get-Command -Name 'Get-CodexTunnelFailureKind' -ErrorAction SilentlyContinue
$retryDelayCommand = Get-Command -Name 'Get-CodexRetryDelay' -ErrorAction SilentlyContinue
Assert-True -Condition ($null -ne $failureKindCommand) -Message 'Get-CodexTunnelFailureKind must be exported by the common module.'
Assert-True -Condition ($null -ne $retryDelayCommand) -Message 'Get-CodexRetryDelay must be exported by the common module.'

$backoffTestRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-ssh-tunnel-static-checks-' + ([Guid]::NewGuid().ToString('N')))
try {
    New-Item -ItemType Directory -Path $backoffTestRoot -Force | Out-Null

    $conflictLogPath = Join-Path $backoffTestRoot 'tunnel-port-conflict.log'
    $conflictLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:100] Launcher started for primary-proxy.'
        '2026-01-01T00:00:01.0000000Z [launcher:100] remote port forwarding failed for listen port 17897'
        '2026-01-01T00:00:01.0000000Z [launcher:100] Launcher finishing for primary-proxy with code 1.'
    )
    [IO.File]::WriteAllText($conflictLogPath, ($conflictLogLines -join "`r`n"))
    $conflictKind = Get-CodexTunnelFailureKind -LogPath $conflictLogPath
    Assert-True -Condition ($conflictKind -eq 'port-conflict') -Message "A remote-port conflict log must classify as port-conflict, got '$conflictKind'."

    $networkLogPath = Join-Path $backoffTestRoot 'tunnel-network-timeout.log'
    $networkLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:200] Launcher started for primary-proxy.'
        'ssh: connect to host devbox.example.com port 22: Connection timed out'
        '2026-01-01T00:00:15.0000000Z [launcher:200] ssh.exe for primary-proxy exited with code 255.'
    )
    [IO.File]::WriteAllText($networkLogPath, ($networkLogLines -join "`n"))
    $networkKind = Get-CodexTunnelFailureKind -LogPath $networkLogPath
    Assert-True -Condition ($networkKind -eq 'network') -Message "A timed-out connection log must classify as network, got '$networkKind'."

    $resolveLogPath = Join-Path $backoffTestRoot 'tunnel-network-resolve.log'
    $resolveLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:300] Launcher started for primary-proxy.'
        'ssh: Could not resolve hostname devbox.example.com: Name or service not known'
        '2026-01-01T00:00:02.0000000Z [launcher:300] Launcher finishing for primary-proxy with code 255.'
    )
    [IO.File]::WriteAllText($resolveLogPath, ($resolveLogLines -join "`n"))
    $resolveKind = Get-CodexTunnelFailureKind -LogPath $resolveLogPath
    Assert-True -Condition ($resolveKind -eq 'network') -Message "A hostname-resolution failure must classify as network, got '$resolveKind'."

    $unknownLogPath = Join-Path $backoffTestRoot 'tunnel-unknown.log'
    $unknownLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:400] Launcher started for primary-proxy.'
        '2026-01-01T00:00:01.0000000Z [launcher:400] Launcher finishing for primary-proxy with code 1.'
    )
    [IO.File]::WriteAllText($unknownLogPath, ($unknownLogLines -join "`n"))
    $unknownKind = Get-CodexTunnelFailureKind -LogPath $unknownLogPath
    Assert-True -Condition ($unknownKind -eq 'unknown') -Message "An unclassified launcher log must classify as unknown, got '$unknownKind'."

    $missingLogPath = Join-Path $backoffTestRoot 'tunnel-missing.log'
    $missingLogKind = Get-CodexTunnelFailureKind -LogPath $missingLogPath
    Assert-True -Condition ($missingLogKind -eq 'unknown') -Message "A missing log file must classify as unknown, got '$missingLogKind'."

    $segmentedLogPath = Join-Path $backoffTestRoot 'tunnel-segmented.log'
    $segmentedLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:500] Launcher started for primary-proxy.'
        'remote port forwarding failed for listen port 17897'
        '2026-01-01T00:00:05.0000000Z [launcher:501] Launcher started for primary-proxy.'
        'ssh: connect to host devbox.example.com port 22: Connection refused'
        '2026-01-01T00:00:06.0000000Z [launcher:501] Launcher finishing for primary-proxy with code 255.'
    )
    [IO.File]::WriteAllText($segmentedLogPath, ($segmentedLogLines -join "`n"))
    $segmentedKind = Get-CodexTunnelFailureKind -LogPath $segmentedLogPath
    Assert-True -Condition ($segmentedKind -eq 'network') -Message "Only text after the last launcher marker must be classified, got '$segmentedKind'."

    $legacyLogPath = Join-Path $backoffTestRoot 'tunnel-legacy.log'
    $legacyLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:600] ssh: connect to host devbox.example.com port 22: Connection refused'
    )
    [IO.File]::WriteAllText($legacyLogPath, ($legacyLogLines -join "`n"))
    $legacyKind = Get-CodexTunnelFailureKind -LogPath $legacyLogPath
    Assert-True -Condition ($legacyKind -eq 'network') -Message "A log without a launcher marker must fall back to the tail, got '$legacyKind'."

    $caseLogPath = Join-Path $backoffTestRoot 'tunnel-case.log'
    $caseLogLines = @(
        '2026-01-01T00:00:00.0000000Z [launcher:700] Launcher started for primary-proxy.'
        'REMOTE PORT FORWARDING FAILED FOR LISTEN PORT 17897'
    )
    [IO.File]::WriteAllText($caseLogPath, ($caseLogLines -join "`n"))
    $caseKind = Get-CodexTunnelFailureKind -LogPath $caseLogPath
    Assert-True -Condition ($caseKind -eq 'port-conflict') -Message "Failure classification must be case-insensitive, got '$caseKind'."

    $conflictDelay1 = Get-CodexRetryDelay -Failures 1 -Kind 'port-conflict'
    Assert-True -Condition ($conflictDelay1 -is [int]) -Message 'Get-CodexRetryDelay must return an integer number of seconds.'
    Assert-True -Condition ($conflictDelay1 -ge 15 -and $conflictDelay1 -le 18) -Message "The first port-conflict retry must be 15..18 seconds, got $conflictDelay1."
    $conflictDelay2 = Get-CodexRetryDelay -Failures 2 -Kind 'port-conflict'
    Assert-True -Condition ($conflictDelay2 -ge 30 -and $conflictDelay2 -le 33) -Message "The second port-conflict retry must be 30..33 seconds, got $conflictDelay2."
    $conflictDelay3 = Get-CodexRetryDelay -Failures 3 -Kind 'port-conflict'
    Assert-True -Condition ($conflictDelay3 -ge 60 -and $conflictDelay3 -le 63) -Message "The third port-conflict retry must be 60..63 seconds, got $conflictDelay3."
    $conflictDelay5 = Get-CodexRetryDelay -Failures 5 -Kind 'port-conflict'
    Assert-True -Condition ($conflictDelay5 -ge 240 -and $conflictDelay5 -le 243) -Message "The fifth port-conflict retry must be 240..243 seconds, got $conflictDelay5."
    $conflictDelayCapped = Get-CodexRetryDelay -Failures 50 -Kind 'port-conflict'
    Assert-True -Condition ($conflictDelayCapped -ge 300 -and $conflictDelayCapped -le 303) -Message "Port-conflict retries must be capped at 300 seconds plus jitter, got $conflictDelayCapped."
    $networkDelay1 = Get-CodexRetryDelay -Failures 1 -Kind 'network'
    Assert-True -Condition ($networkDelay1 -ge 30 -and $networkDelay1 -le 37) -Message "The first network retry must be 30..37 seconds, got $networkDelay1."
    $unknownDelay1 = Get-CodexRetryDelay -Failures 1 -Kind 'unknown'
    Assert-True -Condition ($unknownDelay1 -ge 30 -and $unknownDelay1 -le 37) -Message "Unknown failures must use the network retry defaults, got $unknownDelay1."
    $otherDelay1 = Get-CodexRetryDelay -Failures 1 -Kind 'something-else'
    Assert-True -Condition ($otherDelay1 -ge 30 -and $otherDelay1 -le 37) -Message "An unrecognized failure kind must fall back to the network defaults, got $otherDelay1."
    $networkDelayCapped = Get-CodexRetryDelay -Failures 50 -Kind 'network'
    Assert-True -Condition ($networkDelayCapped -ge 600 -and $networkDelayCapped -le 607) -Message "Network retries must be capped at 600 seconds plus jitter, got $networkDelayCapped."
    $minimumDelay = Get-CodexRetryDelay -Failures 1 -Kind 'network' -BaseSeconds 2 -MaxSeconds 10
    Assert-True -Condition ($minimumDelay -eq 5) -Message "Retry delays must never be shorter than 5 seconds, got $minimumDelay."

    for ($sample = 1; $sample -le 20; $sample++) {
        $jitteredDelay = Get-CodexRetryDelay -Failures 5 -Kind 'port-conflict'
        Assert-True -Condition ($jitteredDelay -ge 240 -and $jitteredDelay -le 243) -Message "Jitter must stay within 0..base/4 seconds, got $jitteredDelay."
    }
}
finally {
    if (Test-Path -LiteralPath $backoffTestRoot) {
        Remove-Item -LiteralPath $backoffTestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
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
