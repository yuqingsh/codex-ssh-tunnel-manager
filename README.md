# Codex SSH Tunnel Manager

一套面向 Windows/macOS Codex App 与 Linux 开发机的按需 SSH 反向隧道管理方案。多台客户端可以同时连接同一台 Linux 开发机：每台客户端使用独立的 Linux 回环端口，Linux wrapper 自动探测并选择可用端点。macOS 同时支持 Cursor Remote SSH。对应远程会话出现时启动代理隧道；会话持续消失一段时间后自动停止。

## 核心行为

- Windows 登录或 macOS 用户登录后只启动轻量控制器。
- 控制器按精确 SSH 别名识别 `codex app-server proxy` 会话。
- macOS 还识别具有精确目标 alias、转发参数及 Cursor 应用父进程的 Remote SSH 会话；Codex 和 Cursor 共用一条隧道。
- 检测到远程会话后，在一个轮询周期内启动对应反向隧道。
- 会话连续消失 10 分钟后停止对应隧道，短暂重连不会造成抖动。
- 隧道任务没有自动启动触发器，只在检测到受支持的远程会话后启动。
- 控制器和隧道任务在后台运行，不显示控制台窗口。
- 每台客户端使用独立的 Linux 回环端口：Windows 默认 `17897`、macOS 默认 `17898`、更多客户端使用 `17899` 及以后；同一台 Linux 开发机上各客户端端口必须不同。
- Linux wrapper 读取端点列表，按顺序做真实代理探测，自动选择第一个可用端点；全部不可用时回退第一个端点并在状态日志中告警。
- 控制器区分 `port-conflict`、`network`、`unknown` 三类失败并分别退避（指数退避加抖动）。端口冲突通常由残留连接或端口规划重复引起，不再被当作网络故障处理，也不会无退避地反复重试。

多客户端端口规划、wrapper 端点解析顺序和失败退避细节见 [架构文档](docs/architecture.md)。

默认示例管理以下映射：

| Codex 开发别名 | 隧道别名 | Windows 任务 / macOS label | Linux 入口（该客户端端口） |
| --- | --- | --- | --- |
| `primary-dev` | `primary-proxy` | `Codex SSH Tunnel Primary` / `com.codex.ssh-tunnel-manager.tunnel.primary` | `127.0.0.1:17897` |
| `secondary-dev` | `secondary-proxy` | `Codex SSH Tunnel Secondary` / `com.codex.ssh-tunnel-manager.tunnel.secondary` | `127.0.0.1:17897` |

表格中的 Linux 入口是 Windows 客户端的示例值（`17897`）；macOS 示例配置使用 `17898`。示例中的两个开发别名对应不同的 Linux 主机，因此同一客户端可以在两台主机上复用相同端口。如果两台客户端连接同一台 Linux 主机，必须为它们分配不同端口（见下文端口分配规则）。

## 数据路径

```text
Linux Codex
  -> HTTP_PROXY=http://127.0.0.1:<客户端端口>
  -> SSH RemoteForward
  -> 客户端 127.0.0.1:7897
  -> Clash
  -> OpenAI services
```

Windows 客户端默认把隧道建立在 Linux 的 `127.0.0.1:17897`，macOS 客户端默认使用 `127.0.0.1:17898`。`<客户端端口>` 由客户端配置的 `RemoteProxyPort`（Windows）或 `REMOTE_PROXY_PORT`（macOS）决定，并与 SSH `RemoteForward` 的远端端口保持一致；Linux wrapper 从端点列表中选择实际可用的端点。

端口分配规则：

| 客户端 | 默认远端端口 | 说明 |
| --- | --- | --- |
| Windows | `17897` | 保持原有默认值 |
| macOS | `17898` | 0.3.0 起的默认值 |
| 更多客户端 | `17899`、`17900`…… | 同一 Linux 主机上依次分配 |

- 同一台 Linux 开发机上，每台客户端的远端端口必须不同，否则后连接的客户端会 bind 失败；
- 不同 Linux 开发机之间可以复用相同端口，因为回环端口空间相互独立；
- 所有端口必须只绑定 Linux 回环地址，不得改为 `0.0.0.0` 或 `*`，也不得启用 `GatewayPorts yes`。

示例使用保留域名和通用 SSH 别名；真实主机名、用户名和公网 SSH 端口只应写入未跟踪的本机配置。

## 仓库结构

```text
config/                 可提交的配置模板（隧道配置与 Linux 端点列表）；实际配置默认忽略
docs/                   架构、运行与故障处理文档
examples/               SSH 配置示例
scripts/windows/        Windows 安装、运行、状态和卸载脚本
scripts/macos/          macOS 初始化、launchd、安装、运行、状态和卸载脚本
scripts/linux/          Linux Codex wrapper、端点安装与验收脚本
tests/                  不修改系统状态的静态检查和语法检查
```

## 快速开始

前提：对应平台的 OpenSSH Client、Clash HTTP/mixed port，以及已经验证过主机指纹的 SSH 配置。

### Windows

```powershell
Copy-Item .\config\tunnels.example.psd1 .\config\tunnels.psd1
notepad .\config\tunnels.psd1
```

Windows 模板保持 `RemoteProxyPort = 17897`。同一台 Linux 主机上如果还有 macOS 客户端，macOS 使用 `17898`，两个端口都需要写入 Linux 端点列表。

在管理员 PowerShell 中安装：

```powershell
.\scripts\windows\Install-CodexSshTunnelManager.ps1 `
  -ConfigPath .\config\tunnels.psd1
```

查看状态：

```powershell
.\scripts\windows\Get-CodexSshTunnelStatus.ps1
```

Linux 端安装 wrapper 前请先阅读 [运行手册](docs/operations.md)。安装脚本不会编辑 `~/.ssh/config`、复制私钥或关闭主机指纹校验。

在 Windows 设备上部署时，按 [Windows 部署指南](docs/windows-setup.md) 操作。

### macOS

推荐使用交互式初始化向导完成一次性配置：

```bash
./scripts/macos/setup-codex-ssh-tunnel-manager.sh
```

向导会探测本机 Clash 端口，生成 `config/tunnels.macos.conf`，可选写入受本项目管理的 SSH alias，检查 `RemoteForward`，并安装 launchd 控制器。远端代理端口默认 `17898`（Windows 客户端保持 `17897`）。真实主机名、用户名和密钥路径只会写入本机配置与 `~/.ssh`，不会写入 Git 跟踪文件。远端 Linux wrapper 只做只读检查，不会被向导自动修改。

如果 SSH alias 已经存在，可复用已有配置：

```bash
./scripts/macos/setup-codex-ssh-tunnel-manager.sh --ssh-mode existing
```

只生成和校验本机配置、不加载 launchd：

```bash
./scripts/macos/setup-codex-ssh-tunnel-manager.sh --no-install
```

也可以继续使用底层安装器，适用于已经准备好配置文件的场景：

复制并编辑 macOS 本机配置：

```bash
cp config/tunnels.macos.example.conf config/tunnels.macos.conf
chmod 600 config/tunnels.macos.conf
```

在确认 SSH alias、Clash 端口和 Linux wrapper 后安装用户级 launchd 控制器：

```bash
./scripts/macos/install-codex-ssh-tunnel-manager.sh \
  --config config/tunnels.macos.conf
```

详细步骤、状态查询、日志位置和卸载方法见 [macOS 部署与使用指南](docs/macos-setup.md)。

Cursor 用户还需按该指南配置远端代理并重新启动 Cursor Server。Cursor 原生 Agent 另需配置 `cursorAgentHost.remoteInferenceRoute: "always"`，让模型请求通过 Mac 客户端出网；仅检查代理变量或 `curl` 成功不能验证原生聊天。详见指南中的原生 Agent 配置和实际聊天验收。Windows 的 Cursor 会话识别暂不包含在本次适配中。

### Linux 端点列表与 wrapper

在 Linux 开发机上安装 wrapper，并登记同一台主机上各客户端的回环端口。端点列表只影响 Codex 进程使用的代理地址，与控制器是否启动隧道无关；wrapper 在 Codex 启动时选择可用端点：

```bash
# 在 Linux 开发机的仓库 scripts/linux 目录中执行
chmod +x install-codex-wrapper.sh codex-app-proxy-wrapper.sh verify-remote-codex.sh
./install-codex-wrapper.sh \
  --endpoint http://127.0.0.1:17897 \
  --endpoint http://127.0.0.1:17898
```

端点列表默认位于：

```text
~/.config/codex-ssh-tunnel-manager/endpoints.conf
```

格式为每行一个 `http://127.0.0.1:<端口>`，空行和 `#` 开头的注释被忽略，行的顺序就是 wrapper 的探测顺序。仓库提供 `config/tunnel-endpoints.example.conf` 模板，也可以手工编辑该文件：

```text
# 同一台 Linux 主机上各客户端的回环端点，按探测顺序排列
http://127.0.0.1:17897
http://127.0.0.1:17898
```

`--endpoint` 可以重复；省略时保留已有文件，文件不存在则创建仅含 `http://127.0.0.1:17897` 的默认文件。同一台 Linux 主机上端点端口必须互不重复；不同 Linux 主机分别安装 wrapper、各自维护端点列表。

验证：

```bash
./verify-remote-codex.sh
```

输出会逐行给出 `ENDPOINT=<url> PROBE=healthy|unhealthy|skipped`，随后给出 `ENDPOINT_SELECTED=<url>`，并用选中的端点检查端口、传输和环境变量。交互排查时可设置 `CODEX_TUNNEL_DEBUG=1`，wrapper 会在 stderr 输出选择端点的原因（`env`、`single`、`probe`、`fallback`）以及每个端点的探测结果。完整说明见 [运行手册](docs/operations.md)。

## 验证

静态检查不修改计划任务或远端机器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
git diff --check
```

macOS 静态检查：

```bash
tests/Invoke-MacOSStaticChecks.sh
```

Linux 脚本语法检查：

```bash
bash -n scripts/linux/*.sh
```

Linux wrapper 行为测试（使用临时的 fake `curl` 和 Codex 入口，不依赖真实网络）：

```bash
sh tests/test-linux-wrapper.sh
```

## 日志

Windows 默认日志目录：

```text
%LOCALAPPDATA%\Codex\ssh-tunnels
```

macOS 日志目录：

```text
~/Library/Logs/Codex/ssh-tunnels
```

Linux wrapper 端点回退状态日志：

```text
${XDG_STATE_HOME:-$HOME/.local/state}/codex/ssh-tunnel-manager/wrapper-YYYYMMDD.log
```

该日志只在全部端点探测失败（或本机没有 `curl`、无法探测）并回退第一个端点时写入；正常启动路径不写日志。

运行日志、实际配置、密钥和主机指纹文件均不应提交到 Git。

## 版本与许可

当前版本为 `0.3.0`，采用 [MIT License](LICENSE)。
