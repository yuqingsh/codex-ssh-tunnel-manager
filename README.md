# Codex SSH Tunnel Manager

一套面向 Windows Codex App 与 Linux 开发机的按需 SSH 反向隧道管理方案。Windows 上的 Codex 远程 SSH 会话出现时，仅启动对应 Linux 主机的代理隧道；会话持续消失一段时间后自动停止。

## 核心行为

- Windows 登录后只启动轻量控制器。
- 控制器按精确 SSH 别名识别 `codex app-server proxy` 会话。
- 检测到远程会话后，在一个轮询周期内启动对应反向隧道。
- 会话连续消失 10 分钟后停止对应隧道，短暂重连不会造成抖动。
- 隧道任务没有自动触发器，无法在未检测到 Codex 远程会话时自行启动。
- 控制器和隧道任务在后台运行，不显示空白 PowerShell 窗口。
- Clash 未监听、SSH 失败或反向端口冲突时记录日志并重试。

默认示例管理以下映射：

| Codex 开发别名 | 隧道别名 | Windows 任务 | Linux 入口 |
| --- | --- | --- | --- |
| `primary-dev` | `primary-proxy` | `Codex SSH Tunnel Primary` | `127.0.0.1:17897` |
| `secondary-dev` | `secondary-proxy` | `Codex SSH Tunnel Secondary` | `127.0.0.1:17897` |

## 数据路径

```text
Linux Codex
  -> HTTP_PROXY=http://127.0.0.1:17897
  -> SSH RemoteForward
  -> Windows 127.0.0.1:7897
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
scripts/linux/          Linux Codex wrapper 与验收脚本
tests/                  不修改系统状态的静态检查
```

## 快速开始

前提：Windows PowerShell 5.1、OpenSSH Client、Clash mixed port，以及已经验证过主机指纹的 SSH 配置。

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

## 验证

静态检查不修改计划任务或远端机器：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
git diff --check
```

## 日志

默认日志目录：

```text
%LOCALAPPDATA%\Codex\ssh-tunnels
```

运行日志、实际配置、密钥和主机指纹文件均不应提交到 Git。

## 版本与许可

当前版本为 `0.2.0`，采用 [MIT License](LICENSE)。
