# 架构

## 组件

| 组件 | 平台 | 职责 |
| --- | --- | --- |
| 控制器 | Windows | 检测远程 Codex SSH 会话并启动或停止对应隧道任务。 |
| 控制器 | macOS | 检测远程 Codex 或 Cursor SSH 会话，并按需启动或停止共享的 launchd 隧道任务。 |
| 无控制台任务启动器 | Windows | 通过 GUI 子系统的 Windows Script Host 启动 PowerShell，不创建可见控制台窗口。 |
| 隧道启动器 | Windows | 等待本地代理就绪，然后维持一条 SSH 反向隧道。 |
| 计划任务 | Windows | 保持控制器可恢复，并按主机隔离隧道进程。 |
| LaunchAgents | macOS | 保持控制器可恢复，同时让隧道任务保持加载但不自动启动。 |
| SSH 别名 | Windows | 将开发会话与反向转发会话分离。 |
| SSH 别名 | macOS | 将开发会话与反向转发会话分离。 |
| macOS 初始化向导 | macOS | 探测本地代理设置，生成机器本地隧道配置，可选管理专用 SSH include，并调用安装器。 |
| Codex wrapper | Linux | 读取端点列表并探测可用端点，向非交互式 Codex 进程注入代理环境变量。 |
| 端点列表 | Linux | 记录同一 Linux 主机上各客户端的回环代理端点，按顺序健康探测。 |

## 需求信号

控制器只检查 `ssh.exe`（Windows）或 `ssh`（macOS）进程。Codex 需求要求进程命令行中出现配置的精确开发别名，并在其后出现 `codex app-server proxy`。

例如 `primary-dev` 不会匹配 `primary-dev-extra`，因为正则要求别名边界。本机 Codex 使用和无关 SSH 会话不会启动隧道。

在 macOS 上，Cursor 需求还会接受 Remote SSH 的安装/保活命令：SSH 选项包含 `-T` 以及 `-D` 或 `-L`，解析出的目标等于配置的开发别名，远程命令为 `bash --login -c bash`（也接受 `/bin/bash`），并且该 SSH 进程的祖先链中存在 Cursor 应用可执行文件。选项值或远程命令中类似主机名的 token 不算目标。未知形态按失败关闭处理，可用检查脚本排查。祖先链遍历有边界，并能容忍已退出的父进程和环。

任一客户端在线都会保持现有隧道存活；只有两者都不存在时才启动宽限期。状态输出分别报告 Codex 与 Cursor 的会话数量。Cursor Remote SSH 的代理设置会为新启动的服务器注入远端回环代理。已有服务器需要重启；忽略代理变量的应用仍需单独配置。

### Cursor 原生推理

Cursor 3.21.16 的原生 AgentService 使用独立的 HTTP/2 传输。观察结果显示，即使设置了 `HTTP_PROXY` 和 `HTTPS_PROXY`，它的远端连接仍可能直连。默认的 `cursorAgentHost.remoteInferenceRoute: "auto"` 在其连通性探测成功时可能保留远端路由；连通性并不代表模型可用。

在目标远端的机器设置中把 `cursorAgentHost.remoteInferenceRoute` 设为 `"always"`，并重新加载窗口。该内置选项让 AgentService 经本地 Cursor 客户端转发，而文件访问和工具执行仍留在远端。Mac 的代理路由必须覆盖 Cursor 的服务域名。遵循代理变量的扩展和工具继续使用 SSH 反向隧道。无需修改厂商 bundle，也无需关闭 TLS 校验。

该设置已在 Cursor 3.21.16 验证，对 private-inference 远端会被忽略，因为本地跳转绕过了它们的私有推理路径。在其他版本使用前请确认该设置存在及其约束。验收需要实际的原生模型回复，并且 Agent Host 日志中出现 `route=always`、`routing inference via local client` 和 `network kind: external`；仅检查代理变量或 HTTP 健康检查不足以验收。

## 多客户端与端点选择

### 端口规划

| 客户端 | 默认远端端口 | 说明 |
| --- | --- | --- |
| Windows | `17897` | 保持原有默认值 |
| macOS | `17898` | 0.3.0 起的默认值 |
| 更多客户端 | `17899`、`17900`…… | 同一 Linux 主机上依次分配 |

- 同一台 Linux 开发机、同一个 Linux 用户下，每台客户端必须使用不同的远端端口，否则后连接的客户端会因端口已被占用而 bind 失败；
- 不同 Linux 开发机之间可以复用相同端口，因为回环端口空间相互独立；
- 一个客户端连接多台 Linux 主机时，可以为每台主机沿用相同端口；
- 端口由客户端的 `RemoteProxyPort`（Windows）或 `REMOTE_PROXY_PORT`（macOS）声明，并与 SSH `RemoteForward` 的远端端口保持一致；
- Linux 端的端点列表（默认 `~/.config/codex-ssh-tunnel-manager/endpoints.conf`）按顺序列出这些端口，供 wrapper 探测。

Linux 端不感知客户端身份，只按端点顺序探测；任意客户端建立的隧道都会让对应端点变为可用。因此项目不提供按会话区分客户端的精确路由，只保证各客户端端口不冲突。

### wrapper 端点解析顺序

1. `CODEX_PROXY_URL` 非空时直接使用该地址，不做探测（兼容旧用法）。
2. 读取端点文件 `${CODEX_SSH_TUNNEL_ENDPOINTS_FILE:-$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf}`。空行和 `#` 开头的行忽略；有效行必须匹配 `http://127.0.0.1:<1-65535>`；非法行忽略，`CODEX_TUNNEL_DEBUG=1` 时在 stderr 给出警告。
3. 文件不存在或没有有效行时，使用默认端点 `http://127.0.0.1:17897`。
4. 只有一个端点时直接使用，不做探测。
5. 有多个端点时按文件顺序逐个探测：`curl --proxy <url> --connect-timeout 1 --max-time <timeout> -s -o /dev/null -w '%{http_code}' <probe-target>`。超时默认 2 秒（`CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS`，仅接受 1-10 的整数）；探测目标默认 `http://codex-tunnel-probe.invalid/`（`CODEX_TUNNEL_PROBE_TARGET`）。curl 退出码为 0 且返回三位 HTTP 状态码（≥100）即视为健康；代理对不可解析域名返回 `502` 也算健康，因为它证明代理链路本身可用。`curl` 不存在时使用第一个端点。
6. 选中的端点写入 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及其小写形式和 `NO_PROXY/no_proxy`，然后 `exec "$HOME/.local/bin/codex.direct" "$@"`。

### 状态与观测

- 设置 `CODEX_TUNNEL_DEBUG=1` 时，wrapper 向 stderr 输出 `codex-wrapper: selected=<url> reason=<env|single|probe|fallback>` 以及每个端点的探测结果。
- 全部端点探测失败（或本机没有 `curl`、无法探测）时回退第一个端点，并向 `${XDG_STATE_HOME:-$HOME/.local/state}/codex/ssh-tunnel-manager/wrapper-$(date -u +%Y%m%d).log` 追加一行；写日志失败不影响 Codex 启动。
- 正常路径不写日志，避免每次启动 Codex 都产生磁盘写入。

### 失败分类与退避

控制器在隧道启动失败后对错误分类，并使用不同退避曲线：

| 分类 | 判定依据（不区分大小写） | 默认曲线 |
| --- | --- | --- |
| `port-conflict` | 包含 `remote port forwarding failed` | 基数 15 秒，上限 300 秒 |
| `network` | 包含 `timed out`、`Connection refused`、`Could not resolve hostname`、`Network is unreachable`、`No route to host`、`Connection reset by peer`、`Broken pipe`、`Permission denied` | 基数 30 秒，上限 600 秒 |
| `unknown` | 其他错误 | 基数 30 秒，上限 600 秒 |

- 延迟按连续失败次数指数增长：`base * 2^(n-1)`，受上限约束，再叠加 `0..base/4` 的抖动，最小 5 秒；macOS 的抖动由基数和当前时间确定，便于测试且能让多台客户端错开重试，Windows 使用随机抖动；
- Windows 与 macOS 使用相同的分类规则和曲线；macOS 可通过 `CODEX_SSH_TUNNEL_CONFLICT_BASE_SECONDS` 与 `CODEX_SSH_TUNNEL_CONFLICT_MAX_SECONDS` 覆盖端口冲突曲线的基数和上限，非法值回退默认；
- 端口冲突日志会提示远端端口被占用（可能来自另一台客户端或残留连接），并在连续出现时提示检查端点规划与旧连接；网络故障日志保留远端防火墙封禁提示；
- 失败状态只保存在内存（Windows）或原有状态文件（macOS 仍为 4 字段）中，不新增持久化格式。

### 健康重置

- 隧道启动后稳定运行 60 秒即视为健康：失败计数和下次重试时间清零；
- Windows 控制器在任务处于 `Running` 且运行时间 ≥60 秒时重置；macOS 控制器沿用原有健康重置逻辑；
- 无会话而停止隧道、或隧道任务被判定为已停止时，同样重置退避状态，避免下一次正常启动被旧的失败计数影响。

## 状态模型

| 当前状态 | 信号 | 动作 | 下一状态 |
| --- | --- | --- | --- |
| 已停止 | 出现匹配会话 | 启动对应隧道任务 | 运行中 |
| 运行中 | 匹配会话仍在 | 刷新最后出现时间 | 运行中 |
| 运行中 | 信号消失 | 启动宽限计时器 | 宽限期 |
| 宽限期 | 信号恢复 | 取消停止并刷新最后出现时间 | 运行中 |
| 宽限期 | 宽限期结束 | 停止隧道任务 | 已停止 |
| 任意 | 控制器退出 | 任务计划程序重启控制器 | 已恢复 |

宽限计时器保存在内存中。如果控制器在隧道运行但会话信号消失时重启，会重新开始一个宽限期。该设计优先保证连续性，而不是激进关闭。

## 计划任务不变量

- 每条隧道任务没有触发器，只能按需启动。
- 隧道任务不设置任务计划程序的自动重启；启动失败由控制器按失败类型退避后重新按需启动，避免绕过退避曲线。
- 控制器具有登录触发器和一个重复恢复触发器。
- `MultipleInstances=IgnoreNew` 防止重复的控制器和隧道。
- 任务动作通过 `wscript.exe` 和无控制台启动器运行，同时保留交互式用户主体，以便使用用户持有的 SSH 密钥和网络设置。
- 隧道启动器使用 `ExitOnForwardFailure=yes` 和 SSH keepalive。
- 安装器在允许时启用任务计划程序的操作历史。

## macOS launchd 不变量

- 控制器是位于 `~/Library/LaunchAgents` 下的用户级 LaunchAgent。
- 控制器使用 `RunAtLoad=true` 和 `KeepAlive=true`，在登录后或意外退出后恢复。
- 每条隧道有独立的 LaunchAgent label，但隧道任务使用 `RunAtLoad=false` 和 `KeepAlive=false`。
- 控制器只有在检测到匹配的 Codex 或 Cursor 会话后，才通过 `launchctl kickstart` 启动隧道。
- 运行中的隧道通过精确配置的代理别名和已核验的 PID 识别。
- 终止前会同时检查可执行文件名称、PID 和精确配置的别名。
- launchd 输出和控制器日志写入用户级 macOS 日志目录，不写入仓库。

macOS 配置是非可执行的 `KEY=VALUE` 文件，因为 Windows PowerShell 数据文件不是安全的 POSIX shell 配置格式。初始化向导以 `600` 权限写入真实文件，并保持其不在 Git 跟踪内容中。Windows `tunnels.psd1` 契约保持不变。

## 安全边界

安全边界是每客户端回环端口：Windows 默认 `127.0.0.1:17897`，macOS 默认 `127.0.0.1:17898`，更多客户端从 `17899` 起。所有端点都只绑定 Linux 回环地址，无法从局域网或公网访问；不得启用 `GatewayPorts yes`，也不得把 `RemoteForward` 的远端绑定地址改为 `0.0.0.0` 或 `*`。

macOS 本地代理端点同样限制在 `127.0.0.1`。控制器和基础安装器不会修改远端 Linux 文件或用户的 SSH 配置；只有显式选择的初始化向导模式才可能创建专用的本地 SSH include。
