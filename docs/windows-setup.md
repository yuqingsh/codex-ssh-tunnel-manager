# Windows 部署指南

本文用于在已经能够 SSH 登录 Linux 开发机的 Windows 设备上部署按需隧道逻辑。示例中的域名、用户、别名和端口都是占位值，必须替换为使用者自己的配置。

## 1. 准备工具

确认以下命令可用：

```powershell
git --version
ssh -V
Test-NetConnection 127.0.0.1 -Port 7897
```

## 2. 克隆仓库

```powershell
$RepoRoot = Join-Path $HOME 'src\codex-ssh-tunnel-manager'
git clone https://github.com/yuqingsh/codex-ssh-tunnel-manager.git $RepoRoot
Set-Location $RepoRoot
```

如果 Git 仍指向过期的本地代理端口，可仅对本次克隆临时使用 Clash `7897`，不要急于修改全局配置：

```powershell
git `
  -c http.proxy=http://127.0.0.1:7897 `
  -c https.proxy=http://127.0.0.1:7897 `
  clone https://github.com/yuqingsh/codex-ssh-tunnel-manager.git $RepoRoot
```

## 3. 检查本机 SSH 配置

已经配置过 SSH 时，只需验证。不要从其他电脑或 GitHub 复制私钥：

```powershell
ssh -o BatchMode=yes primary-dev hostname
ssh -o BatchMode=yes secondary-dev hostname
```

如果任一命令失败，检查 `~/.ssh/config` 是否包含 `examples/ssh_config` 中的别名，并确认已将保留示例域名、用户名和端口替换为自己的值。缺少密钥时在本机重新生成，并只把公钥安装到 Linux：

```powershell
ssh-keygen -t ed25519 -a 64 -f "$HOME\.ssh\id_ed25519_codex_devbox" -C 'windows-codex'
.\scripts\windows\Install-CodexPublicKey.ps1 -Aliases @('primary-dev', 'secondary-dev')
```

首次连接必须通过可信渠道核对主机指纹，不要关闭主机指纹校验。

## 4. 创建本机配置

```powershell
Copy-Item .\config\tunnels.example.psd1 .\config\tunnels.psd1
notepad .\config\tunnels.psd1
```

任务名称和 SSH 别名可以按本机需要修改，但开发别名与代理别名必须一一对应。

`config/tunnels.psd1` 已被 `.gitignore` 排除，不会推送到 GitHub。

## 5. 检查旧任务

先只列出本机现有的相关任务：

```powershell
Get-ScheduledTask |
  Where-Object TaskName -Match 'Codex.*SSH.*Tunnel' |
  Select-Object TaskName, State
```

如果存在旧的“登录即启动”任务，应在确认名称后停用或删除，避免它与新控制器重复占用 Linux `17897`。不确定时不要批量删除，可直接让 Codex 根据任务定义逐个迁移。

## 6. 安装按需控制器

在仓库根目录打开管理员 PowerShell：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
.\scripts\windows\Install-CodexSshTunnelManager.ps1 `
  -ConfigPath .\config\tunnels.psd1 `
  -Verbose
```

安装器会把运行文件部署到 `%LOCALAPPDATA%\Codex\ssh-tunnel-manager`，创建一个控制器任务和两个无触发器的隧道任务。

这些任务通过无控制台窗口启动器在后台运行；即使控制器和两条隧道同时运行，也不应出现空白 PowerShell 窗口。

两台 Linux 已经安装 Codex wrapper 时，无需重新修改 Linux。

## 7. 验收

```powershell
.\scripts\windows\Get-CodexSshTunnelStatus.ps1 `
  -ConfigPath .\config\tunnels.psd1 |
  Format-Table -AutoSize
```

预期结果：

- 控制器任务为 `Running`；
- 两条隧道任务的 `TriggerCount` 都是 `0`；
- 未打开远程 Codex 项目时，隧道可以是 `Ready`；
- 打开对应远程项目后，最多约 5 秒变为 `Running`；
- 远程会话消失满 10 分钟后，对应隧道停止。
- 控制器和隧道运行期间没有空白 PowerShell 窗口。

## 8. 日常使用

以后不需要手动运行 `ssh -N -T primary-proxy`：

1. 保持 Clash mixed port `7897` 可用；
2. 打开 Codex App；
3. 选择 `primary-dev` 或 `secondary-dev` 的远程项目；
4. 控制器自动启动对应隧道；
5. 关闭远程会话后，隧道经过 10 分钟宽限期自动停止。
