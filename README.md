# Codex SSH Tunnel Manager

一套面向 Windows/macOS Codex App 与 Linux 开发机的按需 SSH 反向隧道管理方案。macOS 同时支持 Cursor Remote SSH。对应远程会话出现时启动代理隧道；会话持续消失一段时间后自动停止。

## 核心行为

- Windows 登录或 macOS 用户登录后只启动轻量控制器。
- 控制器按精确 SSH 别名识别 `codex app-server proxy` 会话。
- macOS 还识别具有精确目标 alias、转发参数及 Cursor 应用父进程的 Remote SSH 会话；Codex 和 Cursor 共用一条隧道。
- 检测到远程会话后，在一个轮询周期内启动对应反向隧道。
- 会话连续消失 10 分钟后停止对应隧道，短暂重连不会造成抖动。
- 隧道任务没有自动启动触发器，只在检测到受支持的远程会话后启动。
- 控制器和隧道任务在后台运行，不显示控制台窗口。
- Clash 未监听、SSH 失败或反向端口冲突时记录日志并重试。

默认示例管理以下映射：

| Codex 开发别名 | 隧道别名 | Windows 任务 / macOS label | Linux 入口 |
| --- | --- | --- | --- |
| `primary-dev` | `primary-proxy` | `Codex SSH Tunnel Primary` / `com.codex.ssh-tunnel-manager.tunnel.primary` | `127.0.0.1:17897` |
| `secondary-dev` | `secondary-proxy` | `Codex SSH Tunnel Secondary` / `com.codex.ssh-tunnel-manager.tunnel.secondary` | `127.0.0.1:17897` |

## 数据路径

```text
Linux Codex
  -> HTTP_PROXY=http://127.0.0.1:17897
  -> SSH RemoteForward
  -> Windows/macOS 127.0.0.1:7897
  -> Clash
  -> OpenAI services
```

`17897` 必须只绑定 Linux 回环地址。多个 Linux 主机可以同时使用相同端口，因为它们拥有独立网络命名空间。示例使用保留域名和通用 SSH 别名；真实主机名、用户名和公网 SSH 端口只应写入未跟踪的本机配置。

## 仓库结构

```text
config/                 可提交的配置模板；实际配置默认忽略
docs/                   架构、运行与故障处理文档
examples/               SSH 配置示例
scripts/windows/        Windows 安装、运行、状态和卸载脚本
scripts/macos/          macOS 初始化、launchd、安装、运行、状态和卸载脚本
scripts/linux/          Linux Codex wrapper 与验收脚本
tests/                  不修改系统状态的静态检查和语法检查
```

## 快速开始

前提：对应平台的 OpenSSH Client、Clash HTTP/mixed port，以及已经验证过主机指纹的 SSH 配置。

### Windows

```powershell
Copy-Item .\config\tunnels.example.psd1 .\config\tunnels.psd1
notepad .\config\tunnels.psd1
```

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

向导会探测本机 Clash 端口，生成 `config/tunnels.macos.conf`，可选写入受本项目管理的 SSH alias，检查 `RemoteForward`，并安装 launchd 控制器。真实主机名、用户名和密钥路径只会写入本机配置与 `~/.ssh`，不会写入 Git 跟踪文件。远端 Linux wrapper 只做只读检查，不会被向导自动修改。

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

Cursor 用户还需按该指南配置远端代理并重新启动 Cursor Server。隧道存在本身不会使 Cursor 自动使用代理。Windows 的 Cursor 会话识别暂不包含在本次适配中。

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

## 日志

默认日志目录：

```text
%LOCALAPPDATA%\Codex\ssh-tunnels
```

macOS 日志目录：

```text
~/Library/Logs/Codex/ssh-tunnels
```

运行日志、实际配置、密钥和主机指纹文件均不应提交到 Git。

## 版本与许可

当前版本为 `0.2.0`，采用 [MIT License](LICENSE)。
