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

### 多客户端端口分配

Windows 与 macOS 等客户端连接同一台 Linux 开发机、同一个 Linux 用户时，Linux 上每个客户端各占一个回环端口。端口被另一台客户端占用时，后连的客户端会收到 `remote port forwarding failed`，因此每台客户端的 `RemoteProxyPort` 必须唯一：

| 客户端 | `RemoteProxyPort` | 备注 |
| --- | --- | --- |
| Windows（本机） | `17897` | 本项目默认值，保持不变 |
| macOS | `17898` | macOS 安装向导的默认值 |
| 第 3 台及以后 | `17899`、`17900`…… | 依次递增，并避开 Linux 上已占用的端口 |

`config/tunnels.example.psd1` 中的 `RemoteProxyPort` 保持 `17897`，不要为了让位于 macOS 而修改 Windows 配置格式。远端端口必须绑定到 `127.0.0.1`，不得改为 `0.0.0.0`，也不得启用 `GatewayPorts`。

Linux 端会按端点列表依次探测各客户端的隧道，配置方法见“在 Linux 上配置端点列表”。

## 5. 检查旧任务

先只列出本机现有的相关任务：

```powershell
Get-ScheduledTask |
  Where-Object TaskName -Match 'Codex.*SSH.*Tunnel' |
  Select-Object TaskName, State
```

如果存在旧的“登录即启动”任务，应在确认名称后停用或删除，避免它与新控制器重复占用本客户端配置的远端端口（默认 `17897`）。不确定时不要批量删除，可直接让 Codex 根据任务定义逐个迁移。

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

### 升级后重新运行安装器

安装器会把 `CodexSshTunnel.Common.psm1`、`Watch-CodexSshTunnels.ps1` 等运行文件复制到 `%LOCALAPPDATA%\Codex\ssh-tunnel-manager`，控制器实际运行的是这份副本。更新仓库（例如 `git pull`）只更新仓库文件，必须重新运行上面的安装命令，否则控制器仍是旧版本，不具备失败分类和退避逻辑。重新安装会覆盖运行文件、备份旧配置并重建任务。

## 7. 在 Linux 上配置端点列表

Linux 上的 Codex wrapper 会按顺序探测端点列表，选择第一个健康的客户端隧道，因此需要为每台客户端登记一个远端回环端口。

在 Linux 开发机上执行（仓库目录以实际克隆位置为准）：

```sh
sh scripts/linux/install-codex-wrapper.sh \
  --endpoint http://127.0.0.1:17897 \
  --endpoint http://127.0.0.1:17898
```

- 端点必须是 `http://127.0.0.1:<端口>`，不得写主机名、公网地址或 `0.0.0.0`；
- 端点文件默认位于 `$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf`，安装脚本会以 `600` 权限原子写入，并为旧文件保留 `<文件名>.bak-<UTC 时间戳>` 备份；
- 只有一个端点时 wrapper 直接使用、不做探测；多个端点时依次探测，全部不可用时回退第一个并在状态日志中告警；
- 以后新增客户端时，重新运行安装脚本并追加对应端点，或直接编辑端点文件。端点顺序不影响正确性，只影响多台客户端同时健康时优先使用哪一个。

## 8. 端口冲突与退避行为

控制器会读取隧道日志、区分失败原因，并按不同节奏重试，不再每 5 秒重启隧道任务：

| 失败分类 | 判定依据 | 退避 |
| --- | --- | --- |
| `port-conflict` | 最后一次启动之后出现 `remote port forwarding failed` | 15 秒起，每次失败翻倍，上限 300 秒 |
| `network` | 连接超时、拒绝连接、域名解析失败、网络不可达、连接被重置等 | 30 秒起，每次失败翻倍，上限 600 秒 |
| `unknown` | 其他错误 | 30 秒起，每次失败翻倍，上限 600 秒 |

- 每次重试额外叠加 0 到 base/4 秒的随机抖动，最短 5 秒，避免多台客户端同时重试再次撞车；
- 隧道稳定运行 60 秒后，失败计数和退避自动重置；
- 退避期间控制器不会重复启动任务，日志只记录一次分类结果和本次重试间隔；
- 端口冲突说明另一台客户端正在占用同一端口，或上次连接在 Linux 上仍有残留。先核对每台客户端的 `RemoteProxyPort` 是否唯一、Linux 端点列表是否包含该端口；配置正确后等待退避即可，不要反复手动启动任务；
- 控制器与隧道日志位于 `%LOCALAPPDATA%\Codex\ssh-tunnels\`，其中 `watchdog.log` 记录控制器决策，`<代理别名>.log` 记录每条隧道及其 ssh 输出。

## 9. 验收

```powershell
.\scripts\windows\Get-CodexSshTunnelStatus.ps1 `
  -ConfigPath .\config\tunnels.psd1 |
  Format-Table -AutoSize
```

预期结果：

- 控制器任务为 `Running`；
- 两条隧道任务的 `TriggerCount` 都是 `0`；
- 未打开远程 Codex 项目时，隧道可以是 `Ready`；
- 打开对应远程项目后，最多约一个轮询周期（5 秒）变为 `Running`，失败后的自动重试则遵循退避间隔；
- 远程会话消失满 10 分钟后，对应隧道停止；
- 隧道失败时 `watchdog.log` 记录失败分类（`port-conflict`/`network`/`unknown`）和下次重试秒数，不会每 5 秒反复启动；
- 控制器和隧道运行期间没有空白 PowerShell 窗口。

## 10. 日常使用

以后不需要手动运行 `ssh -N -T primary-proxy`：

1. 保持 Clash mixed port `7897` 可用；
2. 打开 Codex App；
3. 选择 `primary-dev` 或 `secondary-dev` 的远程项目；
4. 控制器自动启动对应隧道；
5. 关闭远程会话后，隧道经过 10 分钟宽限期自动停止。
