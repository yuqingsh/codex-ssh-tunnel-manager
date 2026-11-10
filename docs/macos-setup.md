# macOS 部署与使用指南

本文用于在 macOS Codex App / Cursor Remote SSH 与 Linux 开发机之间部署按需 SSH 反向隧道。

完成一次初始化后，日常使用不需要在 macOS 上手动选择设备或手动启动隧道：

1. 保持 Clash Verge 的 HTTP/mixed 端口可用；
2. 在 Codex App 中打开配置好的 Linux 远程项目；
3. 控制器检测到对应的 SSH 会话后自动启动隧道；
4. 关闭远程会话后，隧道经过宽限时间自动停止。

## 工作原理

~~~text
Linux Codex
  -> Linux 127.0.0.1:17898（macOS 客户端端口）
  -> SSH RemoteForward
  -> macOS 127.0.0.1:7897
  -> Clash Verge
  -> OpenAI services
~~~

Linux 端的 Codex wrapper 从端点列表 `~/.config/codex-ssh-tunnel-manager/endpoints.conf` 读取候选端点，按顺序探测后选择第一个健康的代理，并将其写入 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY 及其小写形式。单客户端时也可以只保留一个端点。

SSH 的 proxy alias 必须在 macOS 的 SSH 配置中定义 RemoteForward：

~~~text
RemoteForward 127.0.0.1:17898 127.0.0.1:7897
ExitOnForwardFailure yes
~~~

远端代理监听地址必须保持为 127.0.0.1，不能改为 0.0.0.0。

## 多客户端端口分配

同一台 Linux 开发机、同一个 Linux 用户下，每台客户端必须占用一个独立的远端回环端口。Linux 只监听客户端指定的端口，先连上的客户端独占该端口；端口相同时后连接的客户端会持续收到 `remote port forwarding failed for listen port ...`。

| 客户端 | 建议远端端口 | 说明 |
| --- | --- | --- |
| Windows | 17897 | 保持现有默认值 |
| macOS | 17898 | 本项目初始化向导的默认值 |
| 更多客户端 | 17899 及以上 | 依次递增，并加入 Linux 端点列表 |

端口只绑定在 Linux 的 127.0.0.1 上，所以不同 Linux 主机可以复用同一端口；端口分配只要求在同一台 Linux、同一个用户下唯一。Linux wrapper 的端点列表按客户端端口逐行配置，具体见后文“配置 Linux 端点列表（多客户端）”。

macOS 控制器会读取 tunnel 进程的 stderr 判断失败原因：远端端口冲突与网络故障使用不同的退避曲线。

## 前置条件

macOS 需要具备：

- 系统自带的 OpenSSH Client；
- 已登录并正常工作的 Clash Verge；
- Clash HTTP 或 mixed 端口；
- macOS SSH 配置中的开发 alias 和代理 alias，或允许初始化向导生成它们所需的主机信息；
- Linux 端已经安装 Codex wrapper，或准备在确认缺失后单独安装；
- 通过 SSH 公钥认证登录 Linux；
- 已通过可信方式确认 SSH 主机指纹。

## 推荐：一键初始化

首次部署可以直接运行交互式向导：

~~~bash
./scripts/macos/setup-codex-ssh-tunnel-manager.sh
~~~

向导会依次处理：

- 探测 `127.0.0.1:7897` 和 `127.0.0.1:33331`，并让用户确认 Clash HTTP/mixed 端口；
- 询问要管理的 Linux 设备、远端代理端口（默认 17898）、开发 alias、代理 alias、主机名、用户名、SSH 端口和 `IdentityFile`；同一台 Linux 上每台客户端端口必须不同，Windows 常用 17897、macOS 用 17898；
- 生成被 Git 忽略且权限为 `600` 的 `config/tunnels.macos.conf`；
- 在明确确认后，生成 `~/.ssh/codex-ssh-tunnel-manager.conf`，并在 `~/.ssh/config` 顶部加入指向该文件的绝对路径 `Include`；已有本项目文件和 SSH 配置会先备份到 `~/.ssh/backups/`；
- 只读验证 SSH alias、`RemoteForward`、SSH 登录和 Linux wrapper；
- 调用现有安装器加载用户级 launchd 控制器；
- 结束时打印建议的 Linux 端点配置片段，以及在 Linux 上运行 `scripts/linux/install-codex-wrapper.sh --endpoint ...` 的提示。向导不会修改远端。

如果已经手动准备好 SSH alias，使用：

~~~bash
./scripts/macos/setup-codex-ssh-tunnel-manager.sh --ssh-mode existing
~~~

如果只想生成并校验配置，不加载 launchd，使用 `--no-install`。向导不会自动安装或覆盖远端 Linux wrapper；检查失败时会报告原因，但仍可以先完成本机部署。

当前模板默认使用 macOS 127.0.0.1:7897。不要仅因为 Clash UI 中显示了端口就认为端口正在监听。

检查端口：

~~~bash
lsof -nP -iTCP:7897 -sTCP:LISTEN
nc -vz 127.0.0.1 7897
curl --proxy http://127.0.0.1:7897 -I --max-time 15 https://api.openai.com/
~~~

如果实际 HTTP/mixed 端口是 33331，应同时修改本机配置的 LOCAL_PROXY_PORT 和 SSH proxy alias 中 RemoteForward 的本地目标端口，然后重新安装。不要只修改其中一处。

## 第一步：配置 SSH alias

将 examples/ssh_config 中需要的配置块合并到 macOS 的 ~/.ssh/config，并替换其中的占位值。

开发 alias 用于 Codex App 的远程会话，例如：

~~~text
Host primary-dev
    HostName dev-primary.example.com
    User devuser
    Port 22
    IdentityFile ~/.ssh/id_ed25519_codex_devbox
    IdentitiesOnly yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
~~~

代理 alias 必须指向同一台 Linux 主机，并加入 RemoteForward：

~~~text
Host primary-proxy
    HostName dev-primary.example.com
    User devuser
    Port 22
    IdentityFile ~/.ssh/id_ed25519_codex_devbox
    IdentitiesOnly yes
    RemoteForward 127.0.0.1:17898 127.0.0.1:7897
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
~~~

先验证 SSH 配置解析和登录：

~~~bash
ssh -G primary-dev
ssh -G primary-proxy
ssh -o BatchMode=yes primary-dev hostname
~~~

不要关闭 StrictHostKeyChecking，也不要从其他设备复制私钥。

## 第二步：验证 Linux wrapper

仓库不会自动修改远端 Linux。安装前只做只读检查：

~~~bash
ssh primary-dev 'test -x "$HOME/.local/bin/codex" && test -e "$HOME/.local/bin/codex.direct" && grep -q CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1 "$HOME/.local/bin/codex"'
~~~

如果检查失败，应先确认 wrapper 是否真的缺失，再由用户明确授权后执行 scripts/linux/install-codex-wrapper.sh。不要在未授权时远程安装或覆盖文件。

## 配置 Linux 端点列表（多客户端）

在让多台客户端共用同一台 Linux 之前，先在 Linux 上配置端点列表。文件固定为：

~~~text
~/.config/codex-ssh-tunnel-manager/endpoints.conf
~~~

每行一个候选端点，按探测顺序排列，空行和 `#` 注释会被忽略：

~~~text
# Windows 客户端
http://127.0.0.1:17897
# macOS 客户端
http://127.0.0.1:17898
~~~

在 Linux 上运行安装脚本（`--endpoint` 可重复；脚本会先备份旧端点文件）：

~~~bash
./scripts/linux/install-codex-wrapper.sh \
    --endpoint http://127.0.0.1:17897 \
    --endpoint http://127.0.0.1:17898
~~~

只有 macOS 客户端时，也可以只写 `http://127.0.0.1:17898`。不要修改远端 Linux，除非已经获得明确授权；macOS 初始化向导只会打印建议片段。

只读验证端点文件与探测结果：

~~~bash
ssh primary-dev 'cat ~/.config/codex-ssh-tunnel-manager/endpoints.conf'
ssh primary-dev 'curl --connect-timeout 1 --max-time 3 -s -o /dev/null -w "%{http_code}\n" --proxy http://127.0.0.1:17898 http://codex-tunnel-probe.invalid/'
~~~

需要更完整的验证时，在 Linux 仓库目录运行 `scripts/linux/verify-remote-codex.sh`，输出会逐个列出：

~~~text
ENDPOINT=http://127.0.0.1:17897 PROBE=unhealthy
ENDPOINT=http://127.0.0.1:17898 PROBE=healthy
~~~

wrapper 会按顺序选择第一个 `healthy` 端点；所有端点都不可用时回退第一个端点并在状态日志中告警。在 Linux 上设置 `CODEX_TUNNEL_DEBUG=1` 可以看到实际选择结果（`selected=<url> reason=<env|single|probe|fallback>`）。

## 第三步：验证实际 Codex SSH 命令

打开一个 Codex 远程项目后，在仓库中运行：

~~~bash
./scripts/macos/inspect-codex-ssh-sessions.sh --config config/tunnels.macos.example.conf
~~~

实际本机配置安装后，也可以将参数改为：

~~~bash
./scripts/macos/inspect-codex-ssh-sessions.sh
~~~

输出中的 Codex SSH 命令必须包含：

~~~text
primary-dev ... codex app-server proxy
~~~

必须是完整 alias token。primary-dev-extra 不能被识别为 primary-dev。

如果 Codex App 实际生成的命令行不包含配置中的 SSH alias，不要通过真实主机名、子串或模糊匹配绕过这个限制。应先调整 SSH/Codex 配置或确认新的、可验证的匹配标识。

不要把这个脚本的未脱敏输出保存到仓库。

## 第四步：复制 macOS 本机配置

在仓库根目录运行：

~~~bash
cp config/tunnels.macos.example.conf config/tunnels.macos.conf
chmod 600 config/tunnels.macos.conf
~~~

根据本机情况修改：

- LOCAL_PROXY_PORT；
- REMOTE_PROXY_PORT；
- TUNNEL_NAMES；
- 各个 TUNNEL_*_DEV_ALIAS；
- 各个 TUNNEL_*_PROXY_ALIAS。

真实配置已被 Git 忽略。模板中的主机、用户和 alias 仍然只能使用占位值。

## 第五步：手动验证反向隧道

在一个终端保持隧道运行：

~~~bash
ssh -N -T primary-proxy
~~~

在另一个终端或通过 SSH 只读验证 Linux 端口：

~~~bash
ssh primary-dev 'nc -z -w3 127.0.0.1 17898'
ssh primary-dev 'curl --proxy http://127.0.0.1:17898 -I --max-time 20 https://api.openai.com/'
~~~

未认证 API 请求返回 HTTP 401，只要 curl 的传输退出码为 0，仍然说明 TCP、TLS 和代理链路已经打通。

手动验证结束后按 Ctrl-C 停止隧道。

## 第六步：安装 launchd 控制器

确认配置文件已经准备好后运行：

~~~bash
./scripts/macos/install-codex-ssh-tunnel-manager.sh \
    --config config/tunnels.macos.conf
~~~

安装器会：

- 将脚本和本机配置复制到用户级的 Codex Application Support 目录；
- 生成并加载一个常驻 controller LaunchAgent；
- 生成每条 tunnel LaunchAgent；
- 将 tunnel LaunchAgent 设置为不自动启动；
- 启动 controller；
- 不修改 ~/.ssh/config；
- 不修改远端 Linux；
- 不需要 sudo。

默认安装目录：

~~~text
~/Library/Application Support/Codex/ssh-tunnel-manager/
~~~

控制器 label 默认是：

~~~text
com.codex.ssh-tunnel-manager.controller
~~~

检查 controller：

~~~bash
launchctl print gui/$(id -u)/com.codex.ssh-tunnel-manager.controller
~~~

检查某条隧道任务：

~~~bash
launchctl print gui/$(id -u)/com.codex.ssh-tunnel-manager.tunnel.primary
~~~

隧道任务被加载并不表示隧道已经运行。隧道只有在对应 Codex 远程会话出现后才会被 controller kickstart。

配置发生变化后，重新运行安装脚本。安装器会只处理本项目声明的 launchd label 和精确 alias 对应的隧道进程。

## 日常使用

初始化完成后：

1. 启动或保持 Clash Verge；
2. 确认 HTTP/mixed 端口仍然是本机配置中的端口；
3. 打开 Codex App 的 Linux 远程项目；
4. controller 自动识别 DevAlias；
5. 对应 ProxyAlias 的反向隧道自动建立；
6. Linux Codex 的 wrapper 从端点列表选择本机端口（macOS 默认 127.0.0.1:17898，Windows 默认 127.0.0.1:17897）；
7. 远程会话关闭后，默认等待 10 分钟再停止。

用户不需要手动执行 ssh -N -T，也不需要在 Codex 中额外选择“代理设备”。

## 查看状态

安装完成后运行：

~~~bash
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/get-codex-ssh-tunnel-status.sh"
~~~

输出字段包括：

- controller 或 tunnel 类型；
- DevAlias、ProxyAlias 和配置中的远端代理端口（RemoteProxyPort）；
- launchd 状态和 PID；
- 当前 Codex SSH 会话数量；
- 当前隧道 SSH 进程数量；
- 隧道进程 PID；
- Clash 本地端口是否可达。

## 日志和状态文件

运行日志位于：

~~~text
~/Library/Logs/Codex/ssh-tunnels/
~~~

常见文件包括：

~~~text
controller-YYYYMMDD.log
primary-tunnel-YYYYMMDD.log
controller.stdout.log
controller.stderr.log
primary-tunnel.stdout.log
primary-tunnel.stderr.log
~~~

`<name>-tunnel.stderr.log` 里的 `[runner-marker]` 行标记每次 runner 启动。控制器只读取最后一次 marker 之后的文本，用来区分“远端端口冲突”和“网络故障”；更早的历史错误不会影响当前分类。

宽限期和重试状态位于：

~~~text
~/Library/Application Support/Codex/ssh-tunnels/
~~~

日志、状态、私钥和本机配置都不应提交到 Git。

## 故障排查

### Clash 不可用

检查：

~~~bash
lsof -nP -iTCP:7897 -sTCP:LISTEN
nc -vz 127.0.0.1 7897
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/get-codex-ssh-tunnel-status.sh"
~~~

controller 会记录不可用状态，并按退避间隔重试。

### 没有检测到 Codex 会话

运行：

~~~bash
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/inspect-codex-ssh-sessions.sh"
~~~

确认命令行中存在精确的 DevAlias 和 codex app-server proxy。

### 隧道没有启动

按顺序检查：

~~~bash
ssh -G primary-proxy
ssh -o BatchMode=yes primary-dev hostname
nc -vz 127.0.0.1 7897
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/get-codex-ssh-tunnel-status.sh"
~~~

然后查看 primary-tunnel-YYYYMMDD.log 和对应的 launchd stderr 日志。

### 网络故障或来源 IP 被远端防火墙封禁

无法连接、超时、拒绝连接、DNS 解析失败等网络类失败使用指数退避：连续失败从 30 秒开始翻倍，最长 600 秒；隧道稳定运行 60 秒后失败计数清零。日志可能出现：

~~~text
[controller] 隧道 primary 启动失败（连续第 3 次）；120 秒后重试
[controller] 提示：连续启动失败可能由服务器未就绪、网络中断或远端防火墙封禁本机公网 IP 引起；请勿手动高频重试
~~~

部分服务器防火墙（fail2ban、云安全组或连接频率限制）会在短时间内出现大量 SSH 连接失败后封禁来源 IP。典型现象是目标端口 TCP 超时、但 ICMP 仍可 ping 通。处理顺序：

1. 确认服务器已启动、sshd 正常监听、服务商端口映射有效；
2. 不要手动反复执行 ssh，也不要缩短控制器退避间隔；
3. 联系服务商确认封禁策略，解封并把常用出口 IP 加入白名单，或放宽 SSH 连接频率限制；
4. 保持 SSH 控制通道直连：不要把 Clash 设为全局代理或让 TUN 接管 SSH。需要透明代理时，可对 SSH 入口 IP 配置 DIRECT 规则，或关闭 TUN 模式。

### 远端端口冲突（remote port forwarding failed）

日志或 tunnel stderr 中出现 `remote port forwarding failed for listen port <端口>` 时，表示 Linux 上该回环端口已经被占用，通常来自另一台客户端或远端残留的旧 SSH 连接。端口冲突和网络故障的退避是分开的：

- 端口冲突：首次约 15 秒，按 2 倍递增，上限 300 秒，另加 0..25% 的抖动；日志会明确写出“远端端口被占用（可能来自另一台客户端或残留连接）；N 秒后重试”；
- 连续第 2 次冲突起，日志会提示检查本机 `REMOTE_PROXY_PORT` 是否与其他客户端重复，并清理远端旧连接；
- 网络/未知故障：保持 30 秒起步、600 秒上限的退避，并保留远端防火墙封禁提示。

排查顺序：

1. 在 macOS 上确认本机配置的远端端口：

   ~~~bash
   grep REMOTE_PROXY_PORT \
       "$HOME/Library/Application Support/Codex/ssh-tunnel-manager/tunnels.macos.conf"
   ~~~

2. 在 Linux 上只读查看回环端口占用和端点列表：

   ~~~bash
   ss -ltnp | grep -E '127\.0\.0\.1:1789[0-9]'
   cat ~/.config/codex-ssh-tunnel-manager/endpoints.conf
   ~~~

3. 对照端口分配表确认没有两台客户端使用同一个端口；需要改端口时，同时修改本机 `REMOTE_PROXY_PORT` 和 SSH proxy alias 的 `RemoteForward`，再重新运行安装器，并更新 Linux 端点列表。
4. 对远端残留连接只做只读确认，不要使用 pkill ssh 或 killall ssh；终止进程前必须同时确认 PID、可执行文件名称和配置中的精确 alias。
5. Linux 上已有的 Codex 会话可能需要重开，wrapper 才会再次探测端点列表。

### SSH 断开或重复隧道

确认是否存在重复的 proxy alias 隧道：

~~~bash
ps -axo pid=,comm=,args= | grep '[s]sh'
~~~

只处理命令行中包含配置的精确 ProxyAlias 且由本项目管理的 PID。不要使用 pkill ssh 或 killall ssh。

### Linux wrapper 缺失

安装器不会自动修改远端 Linux。确认缺失后，先获得授权，再按 Linux 运行手册执行 wrapper 安装。

## 卸载

卸载 launchd 任务并保留日志和状态：

~~~bash
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/uninstall-codex-ssh-tunnel-manager.sh"
~~~

同时删除本项目安装脚本和本机已复制配置：

~~~bash
"$HOME/Library/Application Support/Codex/ssh-tunnel-manager/uninstall-codex-ssh-tunnel-manager.sh" \
    --remove-installed-files
~~~

卸载不会删除：

- ~/.ssh/config；
- SSH 私钥；
- 远端 Linux 文件；
- 运行日志；
- 状态目录。

## 验收标准

macOS 部署完成后应满足：

- 登录 macOS 后 controller 自动恢复；
- 无 Codex 或 Cursor 远程会话时隧道保持停止；
- 打开对应远程项目后隧道自动建立；
- Linux 端能通过本机端点（macOS 默认 127.0.0.1:17898）经 Clash 出网；
- Clash 暂停后会记录并重试；
- SSH 断开后不会产生重复隧道；
- 远程会话关闭后经过宽限时间停止；
- Windows 原有实现和静态检查不受影响。

## Cursor Remote SSH 适配

Cursor 与 Codex 使用配置中同一个开发 alias，例如 `primary-dev`。控制器检查 SSH 的准确目标、`-T`、`-D`/`-L`、`bash --login -c bash` 登录命令，以及来自 Cursor 应用的父进程链。普通终端的相似命令、其他主机和代理 alias 不触发 Cursor 需求。当前适配针对 macOS 正式版 `Cursor.app` 和 Anysphere Remote SSH；其他启动方式需要单独验证。

在 **Mac 的 Cursor 用户设置 JSON** 中合并以下设置（保留已有其他设置和其他主机条目）：

```json
{
  "remote.SSH.httpProxy": { "primary-dev": "http://127.0.0.1:17898" },
  "remote.SSH.httpsProxy": { "primary-dev": "http://127.0.0.1:17898" },
  "remote.SSH.noProxy": { "primary-dev": "127.0.0.1,localhost,::1" }
}
```

这些地址是 **Linux 端** 的代理地址，端口必须与本机 macOS 客户端的远端端口一致（默认 17898）。不要把 Linux 的 `17898` 直接当作 Mac 本地 `http.proxy`；Mac 本地代理端口仍由 Clash 决定。若已有字符串形式的全主机代理设置，先保留备份，再按仍需使用它的主机转换为映射，不要丢弃原来的用途。

已检查的 Anysphere Remote SSH 1.1.16 会将上述配置导出为大小写 HTTP/HTTPS/NO_PROXY 环境变量，并用于启动远端服务。该适配不需要修改 Linux 的登录脚本或现有 Codex wrapper。只配置终端环境变量不能覆盖已经启动的扩展和 Agent。

### 配置远端服务及扩展的代理

首次配置后：

1. 保存工作，结束需要保留的 Cursor 远端任务。
2. 在对应远端窗口的命令面板执行 `Remote-SSH: Kill Remote Server and Reload Window`。
3. 重新连接 **同一个 alias**，打开原来的项目；控制器通常在 5 秒内建立隧道。
4. 在新的远端终端检查 `printf '%s\n' "$HTTPS_PROXY"`，应为 `http://127.0.0.1:17898`（若使用端点列表，wrapper 可能选择其他健康端点）；再运行 `curl --max-time 15 https://api2.cursor.sh` 验证继承的代理。需要时检查远端进程的代理环境。
5. 在 Mac 运行状态脚本，确认 `ActiveCursorSessions` 至少为 1。Cursor 独立连接时也应保持隧道运行。

普通 Reload Window 或仅关闭窗口可能复用旧服务器，不能保证已有进程获得新环境。以上只验证环境变量和普通 HTTP 请求；原生 Agent 还需要下面的配置和实际聊天验收。

### 配置 Cursor 原生 Agent 的模型请求

已在 Cursor 3.21.16 中确认：原生 Agent 的远端 HTTP/2 连接可能绕过 HTTP/HTTPS 代理变量。此时 Codex 扩展能聊天、`curl` 返回 200，原生 GPT 仍可能报告 `Model not available`。应检查完整错误和实际连接，不能据此直接判断为额度或模型名称问题。

连接目标远端窗口，执行 `Preferences: Open Remote Settings (JSON)`，在现有设置中合并：

```json
{
  "cursorAgentHost.remoteInferenceRoute": "always"
}
```

标准 Linux 安装通常将该设置存放在 `~/.cursor-server/data/Machine/settings.json`。保留其他设置；优先放在目标远端的设置中，以免改变其他主机的行为。

该选项来自 Cursor 内置 Agent Host 扩展：`auto` 会探测远端连接后选择路由，`always` 将模型请求经本地 Cursor 客户端发出，`never` 保留远端出网。文件访问和工具执行仍在 Linux；支持代理环境变量的扩展和命令继续使用反向隧道。它只在 Agent Host 启动时读取，保存工作后执行一次 `Developer: Reload Window` 即可生效。这里重载的是推理路由；前一节修改服务器环境变量时仍需重启远端服务。

Mac 的 Clash 也必须覆盖 Cursor 的服务域名，并使用可用的代理出口。可在持久前置规则中将 `cursor.sh`、`cursor.com`、`cursorapi.com`、`cursor-cdn.com` 分配给已有的 AI 代理组。不要直接编辑生成的运行时配置，也不要把 Linux 的回环代理端口填给 Mac。更多域名及网络要求见 [Cursor 网络配置](https://cursor.com/docs/enterprise/network-configuration)。

该设置已在 Cursor 3.21.16 验证；其他版本先确认内置设置是否存在。Cursor 会在 private-inference 远端忽略 `always`，因为本地转发不经过其私有推理路径；此类部署应沿用自身的网络配置。

验收需同时满足：

1. 原生聊天选择目标模型，发送简短测试，实际收到回复。Codex 扩展的回复不能替代此项。
2. 远端 `Cursor Agent Host` 日志显示 `route=always`、`routing inference via local client` 和 `network kind: external`。通常位于 `~/.cursor-server/data/logs/<session>/exthost*/anysphere.cursor-agent-host/`。
3. Mac 代理连接记录中能看到原生模型服务域名（例如 `agentn.global.api5.cursor.sh`）走预期代理。必要时按进程核查远端连接，避免把 Mac 本地的 API 健康检查误当作远端 Agent 的模型请求。

如果实际请求仍返回地区限制，保留完整错误和请求 ID，继续排查出口与模型可用性；不要反复重启或关闭 TLS 验证。参见 [Cursor 地区说明](https://cursor.com/docs/account/regions)。

每日使用只需保持 Mac 在线、Clash 可用，再正常连接 Cursor；不必同时打开 Codex。两种客户端都断开约 10 分钟后隧道自动停止。Mac 休眠或代理关闭期间，远端代理不可用。

回退原生推理路由时，只恢复或删除本次添加的 `cursorAgentHost.remoteInferenceRoute` 键，再重载窗口，保留其他远端设置。回退代理环境时先恢复备份的 Cursor 用户设置，再重启对应远端服务。恢复旧控制器脚本后，只重启控制器即可恢复原来的 Codex 专用检测；不必终止正在使用的隧道。
