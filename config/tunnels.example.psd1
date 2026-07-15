@{
    SchemaVersion = 1

    Runtime = @{
        PollSeconds = 5
        StopGraceMinutes = 10
        ProxyWaitSeconds = 120
        LocalProxyHost = '127.0.0.1'
        LocalProxyPort = 7897
        RemoteProxyHost = '127.0.0.1'
        RemoteProxyPort = 17897
        ControllerTaskName = 'Codex SSH Tunnel Watchdog'
    }

    Tunnels = @(
        @{
            Name = 'primary'
            DevAlias = 'primary-dev'
            ProxyAlias = 'primary-proxy'
            TaskName = 'Codex SSH Tunnel Primary'
        }
        @{
            Name = 'secondary'
            DevAlias = 'secondary-dev'
            ProxyAlias = 'secondary-proxy'
            TaskName = 'Codex SSH Tunnel Secondary'
        }
    )
}
