Set-StrictMode -Version Latest

function Import-CodexTunnelConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    $configuration = Import-PowerShellDataFile -LiteralPath $resolvedPath

    if ($configuration.SchemaVersion -ne 1) {
        throw "Unsupported configuration schema: $($configuration.SchemaVersion)."
    }

    if ($null -eq $configuration.Runtime -or $null -eq $configuration.Tunnels) {
        throw 'Configuration must contain Runtime and Tunnels sections.'
    }

    $requiredRuntimeKeys = @(
        'PollSeconds',
        'StopGraceMinutes',
        'ProxyWaitSeconds',
        'LocalProxyHost',
        'LocalProxyPort',
        'RemoteProxyHost',
        'RemoteProxyPort',
        'ControllerTaskName'
    )
    foreach ($key in $requiredRuntimeKeys) {
        if (-not $configuration.Runtime.ContainsKey($key)) {
            throw "Runtime configuration is missing '$key'."
        }
    }

    if ([int]$configuration.Runtime.PollSeconds -lt 2 -or [int]$configuration.Runtime.PollSeconds -gt 300) {
        throw 'PollSeconds must be between 2 and 300.'
    }
    if ([int]$configuration.Runtime.StopGraceMinutes -lt 1 -or [int]$configuration.Runtime.StopGraceMinutes -gt 1440) {
        throw 'StopGraceMinutes must be between 1 and 1440.'
    }
    if ([int]$configuration.Runtime.ProxyWaitSeconds -lt 1 -or [int]$configuration.Runtime.ProxyWaitSeconds -gt 3600) {
        throw 'ProxyWaitSeconds must be between 1 and 3600.'
    }
    if ([string]$configuration.Runtime.LocalProxyHost -ne '127.0.0.1') {
        throw 'LocalProxyHost must remain 127.0.0.1.'
    }
    if ([string]$configuration.Runtime.RemoteProxyHost -ne '127.0.0.1') {
        throw 'RemoteProxyHost must remain 127.0.0.1.'
    }
    foreach ($portKey in @('LocalProxyPort', 'RemoteProxyPort')) {
        $port = [int]$configuration.Runtime[$portKey]
        if ($port -lt 1 -or $port -gt 65535) {
            throw "$portKey must be between 1 and 65535."
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$configuration.Runtime.ControllerTaskName)) {
        throw 'ControllerTaskName cannot be empty.'
    }

    $tunnels = @($configuration.Tunnels)
    if ($tunnels.Count -eq 0) {
        throw 'At least one tunnel must be configured.'
    }

    $requiredTunnelKeys = @('Name', 'DevAlias', 'ProxyAlias', 'TaskName')
    foreach ($tunnel in $tunnels) {
        foreach ($key in $requiredTunnelKeys) {
            if (-not $tunnel.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$tunnel[$key])) {
                throw "Every tunnel must define a non-empty '$key'."
            }
        }

        foreach ($aliasKey in @('DevAlias', 'ProxyAlias')) {
            if ([string]$tunnel[$aliasKey] -notmatch '^[A-Za-z0-9._-]+$') {
                throw "$aliasKey '$($tunnel[$aliasKey])' contains unsupported characters."
            }
        }
    }

    foreach ($property in @('Name', 'DevAlias', 'ProxyAlias', 'TaskName')) {
        $duplicates = @($tunnels | Group-Object -Property { $_[$property] } | Where-Object Count -gt 1)
        if ($duplicates.Count -gt 0) {
            throw "Tunnel property '$property' must be unique. Duplicate: $($duplicates[0].Name)."
        }
    }

    return $configuration
}

function Get-CodexRemoteSessionPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DevAlias
    )

    $escapedAlias = [Regex]::Escape($DevAlias)
    return "(?i)(?:^|\s)$escapedAlias(?:\s|$).*codex app-server proxy"
}

function Get-CodexProxyTunnelPattern {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProxyAlias
    )

    $escapedAlias = [Regex]::Escape($ProxyAlias)
    return "(?i)(?:^|\s)$escapedAlias(?:\s|$)"
}

function Test-CodexTcpEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [int]$Port,

        [int]$TimeoutMilliseconds = 1000
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $connection = $client.ConnectAsync($HostName, $Port)
        return $connection.Wait($TimeoutMilliseconds) -and $client.Connected
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-CodexTunnelFailureKind {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$LogPath
    )

    if ([string]::IsNullOrWhiteSpace($LogPath) -or -not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
        return 'unknown'
    }

    $logText = $null
    try {
        $logText = Get-Content -LiteralPath $LogPath -Raw -ErrorAction Stop
    }
    catch {
        return 'unknown'
    }

    if ([string]::IsNullOrEmpty($logText)) {
        return 'unknown'
    }

    $marker = 'Launcher started for'
    $markerIndex = $logText.LastIndexOf($marker, [StringComparison]::OrdinalIgnoreCase)
    if ($markerIndex -ge 0) {
        $segment = $logText.Substring($markerIndex + $marker.Length)
    }
    else {
        # Older logs have no launcher marker; only inspect the last 50 lines.
        $lines = @($logText -split "\r?\n")
        $tailStart = $lines.Count - [Math]::Min(50, $lines.Count)
        $segment = (@($lines[$tailStart..($lines.Count - 1)]) -join "`n")
    }

    if ($segment -match 'remote port forwarding failed') {
        return 'port-conflict'
    }
    if ($segment -match 'timed out|Connection refused|Could not resolve hostname|Network is unreachable|No route to host|Connection reset by peer|Broken pipe|Permission denied') {
        return 'network'
    }

    return 'unknown'
}

function Get-CodexRetryDelay {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)]
        [int]$Failures,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Kind,

        [int]$BaseSeconds = 0,

        [int]$MaxSeconds = 0
    )

    $normalizedKind = ''
    if (-not [string]::IsNullOrWhiteSpace($Kind)) {
        $normalizedKind = $Kind.Trim().ToLowerInvariant()
    }

    if ($normalizedKind -eq 'port-conflict') {
        $defaultBase = 15
        $defaultMax = 300
    }
    else {
        $defaultBase = 30
        $defaultMax = 600
    }

    # PowerShell variable names are case-insensitive, so the effective values
    # must use names that differ from the -BaseSeconds/-MaxSeconds parameters.
    $effectiveBase = $defaultBase
    if ($BaseSeconds -gt 0) {
        $effectiveBase = $BaseSeconds
    }
    $effectiveMax = $defaultMax
    if ($MaxSeconds -gt 0) {
        $effectiveMax = $MaxSeconds
    }
    if ($effectiveMax -lt $effectiveBase) {
        $effectiveMax = $effectiveBase
    }

    $failureCount = $Failures
    if ($failureCount -lt 1) {
        $failureCount = 1
    }

    # Exponential backoff: base * 2^(failures - 1), capped at max seconds.
    $delaySeconds = [long]$effectiveBase
    $step = 1
    while ($step -lt $failureCount -and $delaySeconds -lt $effectiveMax) {
        $delaySeconds = $delaySeconds * 2
        if ($delaySeconds -gt $effectiveMax) {
            $delaySeconds = $effectiveMax
        }
        $step = $step + 1
    }

    # Add 0..base/4 seconds of jitter so clients do not retry in lockstep.
    $jitterMaximum = [int][Math]::Floor($effectiveBase / 4)
    $jitterSeconds = 0
    if ($jitterMaximum -gt 0) {
        $jitterSeconds = Get-Random -Minimum 0 -Maximum ($jitterMaximum + 1)
    }
    $delaySeconds = $delaySeconds + $jitterSeconds

    $minimumDelaySeconds = 5
    if ($delaySeconds -lt $minimumDelaySeconds) {
        $delaySeconds = $minimumDelaySeconds
    }
    if ($delaySeconds -gt [int]::MaxValue) {
        $delaySeconds = [int]::MaxValue
    }

    return [int]$delaySeconds
}

Export-ModuleMember -Function @(
    'Import-CodexTunnelConfiguration',
    'Get-CodexRemoteSessionPattern',
    'Get-CodexProxyTunnelPattern',
    'Test-CodexTcpEndpoint',
    'Get-CodexTunnelFailureKind',
    'Get-CodexRetryDelay'
)
