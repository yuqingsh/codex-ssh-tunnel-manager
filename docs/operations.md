# 运行手册

macOS 用户应阅读完整的 [macOS 部署与使用指南](macos-setup.md)。以下各节保留 Windows 和 Linux 的运维细节。

## 前置条件

Windows 需要：

- Windows PowerShell 5.1；
- OpenSSH Client；
- 监听 `127.0.0.1:7897` 的 Clash 或其他 HTTP/mixed 代理；
- `~/.ssh/config` 中的 SSH 开发别名和代理别名；
- 到各开发别名的密钥登录。

Linux 需要 OpenSSH Server、`curl`、`git` 和兼容的 Codex CLI 安装。

macOS 需要系统自带 OpenSSH Client、Clash HTTP/mixed 端口、用户级 launchd 支持，以及 [macOS 部署与使用指南](macos-setup.md) 中所述的 macOS SSH 别名。

## 配置 Windows

创建未跟踪的本机配置：

```powershell
Copy-Item .\config\tunnels.example.psd1 .\config\tunnels.psd1
```

检查 `config/tunnels.psd1`，然后把 `examples/ssh_config` 中需要的配置块合并到 `~/.ssh/config`。先确认本机代理：

```powershell
Test-NetConnection 127.0.0.1 -Port 7897
ssh -o BatchMode=yes primary-dev hostname
ssh -o BatchMode=yes secondary-dev hostname
```

不要关闭 `StrictHostKeyChecking`。首次使用的主机指纹必须通过可信渠道核对。

`RemoteProxyPort` 是 Linux 侧的远端回环端口。同一台 Linux 主机上每台客户端必须使用不同端口（Windows 默认 `17897`、macOS 默认 `17898`、更多客户端从 `17899` 起）；同一客户端管理连接不同 Linux 主机的多条隧道时可以复用相同端口。修改端口后要同时更新 SSH `RemoteForward` 的远端端口和 Linux 端点列表。

## 安装或升级 Windows 任务

在仓库根目录打开管理员 PowerShell：

```powershell
.\scripts\windows\Install-CodexSshTunnelManager.ps1 `
  -ConfigPath .\config\tunnels.psd1 `
  -Verbose
```

安装器是幂等的。它会捕获当前 Codex 远程会话信号，只停止配置中声明的任务和精确匹配的隧道进程，把带版本号的脚本部署到 `%LOCALAPPDATA%\Codex\ssh-tunnel-manager`，重建任务，并恢复正在使用的隧道。

控制器和隧道任务通过 Windows Script Host 无控制台启动器运行。它们保留 SSH 密钥所需的交互式用户身份，但不会显示空白的 PowerShell 窗口。

升级后控制器会按失败类型退避。出现端口冲突时不需要也不应手动反复重启任务，应先按本文故障排查一节确认端口规划。

## 安装 Linux wrapper 与端点列表

复制 `scripts/linux` 到 Linux 主机，然后在目标主机上安装 wrapper 并登记各客户端端口：

```bash
chmod +x install-codex-wrapper.sh codex-app-proxy-wrapper.sh verify-remote-codex.sh
./install-codex-wrapper.sh \
  --endpoint http://127.0.0.1:17897 \
  --endpoint http://127.0.0.1:17898
```

`--endpoint` 可重复。安装器会校验地址必须是 `http://127.0.0.1:<端口>`，去重后原子写入端点文件；已有文件会先备份为 `<文件>.bak-<UTC 时间戳>`，新文件权限为 `600`。不传 `--endpoint` 时保留已有端点文件；文件不存在则创建仅含 `http://127.0.0.1:17897` 的默认文件。安装结束会打印端点文件路径和端点列表；只配置了一个端点时会提示多客户端需要各自端口。

端点文件默认位于：

```text
~/.config/codex-ssh-tunnel-manager/endpoints.conf
```

格式为每行一个 `http://127.0.0.1:<1-65535>`，空行与 `#` 注释被忽略，顺序即 wrapper 的探测顺序。仓库模板为 `config/tunnel-endpoints.example.conf`：

```text
# 同一台 Linux 开发机上各客户端的回环端点，按探测顺序排列
http://127.0.0.1:17897
http://127.0.0.1:17898
```

同一台 Linux 主机上，端点端口必须互不重复；不同 Linux 主机分别维护各自的端点列表。端点列表只使用回环地址，不得写入 `0.0.0.0`、`*` 或其他可被局域网访问的地址。

wrapper 的选择顺序：`CODEX_PROXY_URL` 非空时直接使用；只有单个端点时直接使用；多个端点时按顺序探测，选择第一个健康端点；全部不可用时回退第一个端点并写入状态日志。设置 `CODEX_TUNNEL_DEBUG=1` 可在 stderr 查看选择原因和每个端点的探测结果。

wrapper 只在进程启动时选择一次端点；已经在运行的 Codex/Cursor 远程进程会一直使用启动时的端点。如果该端点对应的客户端隧道失效（例如那台机器休眠或断网），请重开远程会话（或重启对应的 app-server / Cursor Server），让新进程重新探测端点。

wrapper 通过大小写两套代理环境变量暴露反向隧道，并委托给 `~/.local/bin/codex.direct`。Codex CLI 升级可能替换 `~/.local/bin/codex`；升级后如果网络错误再次出现，请重新安装 wrapper。

## 状态与验证

Windows：

```powershell
& "$env:LOCALAPPDATA\Codex\ssh-tunnel-manager\Get-CodexSshTunnelStatus.ps1" |
  Format-Table -AutoSize
```

预期不变量：

- 控制器为 `Running`；
- 每条隧道任务的 `TriggerCount=0`；
- 只有对应远程 Codex 会话存在或仍处于宽限期时，隧道才是 `Running`；
- Clash 可用时 `LocalProxyReachable=True`；
- 控制器和活动隧道任务不显示空白 PowerShell 窗口。

macOS 状态输出额外包含 `RemoteProxyPort` 列（取自配置的 `REMOTE_PROXY_PORT`），可直接确认该客户端使用的远端端口。

Linux：

```bash
./verify-remote-codex.sh
```

脚本先逐个端点输出探测结果：

```text
ENDPOINT=http://127.0.0.1:17897 PROBE=healthy
ENDPOINT=http://127.0.0.1:17898 PROBE=unhealthy
ENDPOINT_SELECTED=http://127.0.0.1:17897
```

`PROBE=healthy` 表示该端点通过对应客户端隧道成功代理了探测请求；`unhealthy` 表示该端点当前没有可用转发；`skipped` 表示该端点未被探测（设置了 `CODEX_PROXY_URL`、只有一个端点或本机没有 `curl`）。随后脚本用 `ENDPOINT_SELECTED` 的端点检查端口（`TUNNEL=tunnel-ok|tunnel-missing`）、传输 curl 退出码、HTTP 状态码，以及 `APP_SERVER_PROXY_*`、`CODE_MODE_HOST_*` 进程的代理环境变量。

即使未认证的 API 请求返回 HTTP `401`，只要 `TRANSPORT_CURL_EXIT=0`，仍说明 TCP、TLS 和代理传输链路是通的。传输 curl 失败时脚本退出码非 0。

## 日志

Windows：

```text
%LOCALAPPDATA%\Codex\ssh-tunnels\watchdog.log
%LOCALAPPDATA%\Codex\ssh-tunnels\<proxy-alias>.log
```

macOS：

```text
~/Library/Logs/Codex/ssh-tunnels/
```

控制器日志按失败分类记录退避原因和等待时间。任务计划程序事件位于 `Microsoft-Windows-TaskScheduler/Operational`。

Linux wrapper 端点回退状态日志：

```text
${XDG_STATE_HOME:-$HOME/.local/state}/codex/ssh-tunnel-manager/wrapper-YYYYMMDD.log
```

该日志只在全部端点探测失败（或本机没有 `curl`、无法探测）并回退第一个端点时写入；正常启动路径不写日志。

## 故障排查

### `remote port forwarding failed for listen port <port>`

多客户端改造后这个错误应该很少出现：每台客户端使用独立的远端回环端口。如果仍然出现，通常是以下两类原因：

1. 该 Linux 主机上还有残留连接持有端口，例如手动启动且未退出的 `ssh -N -T <proxy-alias>`、上一次异常退出后尚未释放的转发，或旧客户端/旧任务仍在使用同一端口；
2. 端口规划重复：同一台 Linux 主机上两台客户端配置了相同端口，或客户端的 `RemoteProxyPort` / `REMOTE_PROXY_PORT` 与 SSH `RemoteForward` 的远端端口、Linux 端点列表不一致。

多客户端端口分配：

| 客户端 | 默认远端端口 | Linux 端点 |
| --- | --- | --- |
| Windows | `17897` | `http://127.0.0.1:17897` |
| macOS | `17898` | `http://127.0.0.1:17898` |
| 更多客户端 | `17899`、`17900`…… | `http://127.0.0.1:17899` 等 |

定位顺序：

1. 查看控制器日志，确认失败被分类为 `port-conflict` 还是 `network`。端口冲突使用独立曲线：基数 15 秒、指数增长、上限 300 秒，另叠加抖动；日志会提示端口被占用：
   - Windows：`%LOCALAPPDATA%\Codex\ssh-tunnels\watchdog.log`
   - macOS：`~/Library/Logs/Codex/ssh-tunnels/controller-YYYYMMDD.log`
2. 在 Linux 端确认端点状态：

   ```bash
   ./verify-remote-codex.sh
   ```

   重点看 `ENDPOINT=<url> PROBE=healthy|unhealthy` 和 `ENDPOINT_SELECTED=<url>`。只有对应客户端的隧道已建立时，该端点才可能为 `healthy`；`unhealthy` 说明该端口当前没有可用转发，应先确认对应平台的控制器和隧道任务是否在运行。

3. 查看 wrapper 状态日志：

   ```bash
   tail -n 20 "${XDG_STATE_HOME:-$HOME/.local/state}/codex/ssh-tunnel-manager/wrapper-$(date -u +%Y%m%d).log"
   ```

   该日志只在全部端点探测失败（或本机没有 `curl`）并回退第一个端点时写入。如果反复出现，说明 Linux 端在探测时刻没有任何客户端隧道在线。

4. 如果确认是残留连接，只处理本项目管理的精确进程。Windows：

   ```powershell
   Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
     Where-Object CommandLine -Match 'primary-proxy|secondary-proxy'
   ```

   macOS：

   ```bash
   ps -axo pid=,comm=,args= | grep '[p]rimary-proxy\|[s]econdary-proxy'
   ```

   终止前必须同时确认 PID、可执行文件名称和配置中声明的精确别名，或重新运行安装器做范围受控的交接。禁止使用 `pkill ssh`、`killall ssh` 或其他宽泛的批量终止命令。

5. 如果确认是端口规划重复，为每台客户端分配不同端口，并同时更新三处：客户端配置、SSH `RemoteForward` 的远端端口、Linux `endpoints.conf` 端点列表，然后重新运行对应平台的安装器。

不建议手动高频重试 `ssh`。控制器已经区分失败类型并按曲线退避，手动重试只会加重远端负载，甚至触发防火墙封禁。

### 控制器在运行但隧道已停止

检查对应的开发会话是否存在：

```powershell
Get-CimInstance Win32_Process -Filter "Name='ssh.exe'" |
  Where-Object CommandLine -Match 'codex app-server proxy'
```

然后检查启动器日志中的 Clash 就绪、SSH 认证或远端转发冲突信息。端口冲突会以 `port-conflict` 分类退避，不会高频重试。

### `stream disconnected before completion`

在 Linux 上按顺序验证。端口使用该客户端的实际远端端口，可从 `endpoints.conf` 或 `verify-remote-codex.sh` 的选定端点获得：

```bash
nc -z -w3 127.0.0.1 <客户端端口>
curl --proxy http://127.0.0.1:<客户端端口> -I --max-time 15 https://api.openai.com/
```

如果端口和传输可用，确认运行中的 Codex 进程继承了 wrapper 注入的 `HTTPS_PROXY`；远程会话应通过 wrapper 启动的 Codex 运行。

## 卸载

在管理员 PowerShell 中：

```powershell
& "$env:LOCALAPPDATA\Codex\ssh-tunnel-manager\Uninstall-CodexSshTunnelManager.ps1" `
  -RemoveInstalledFiles
```

卸载不会编辑 SSH 配置、吊销公钥或修改 Linux 文件。
