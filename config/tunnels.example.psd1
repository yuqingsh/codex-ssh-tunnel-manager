# Windows 本机配置模板。
# 复制为 config/tunnels.psd1 后再按本机情况修改；该文件已被 Git 忽略。
#
# RemoteProxyPort 是 Linux 侧 127.0.0.1 上的远端回环端口：
# - 同一台 Linux 开发机上，每台客户端必须使用不同端口；
# - 约定 Windows 客户端使用 17897、macOS 客户端使用 17898，更多客户端使用 17899 及以后；
# - 不同 Linux 开发机之间可以复用相同端口，因为回环端口空间相互独立；
# - 修改端口后需同步 Linux 端 ~/.config/codex-ssh-tunnel-manager/endpoints.conf 的端点列表。
# 配置结构（SchemaVersion）保持不变，旧配置可直接继续使用。
@{
    SchemaVersion = 1

    Runtime = @{
        PollSeconds = 5
        StopGraceMinutes = 10
        ProxyWaitSeconds = 120
        LocalProxyHost = '127.0.0.1'
        LocalProxyPort = 7897
        RemoteProxyHost = '127.0.0.1'
        # 同一台 Linux 开发机上每台客户端唯一；Windows 默认 17897。
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
