# AGENTS.md

## 文件用途与适用范围

本文件是本仓库的 AI 编程代理必须遵守的长期开发约定。

在修改代码、脚本、配置、测试或文档前，必须：

1. 阅读本文件；
2. 检查当前工作区是否存在未提交修改；
3. 检查目标目录及其父级、子级是否存在其他 `AGENTS.md`；
4. 明确本次任务的修改范围、验证方式和潜在副作用。

更接近目标文件的 `AGENTS.md` 可以补充更具体的规则。系统指令、开发者指令和用户当前明确要求优先于本文件。

本文件是工程协约，不是安全边界。必须由静态检查、测试、CI 或 Git hooks 强制执行的规则，不得只依赖本文件。

## 项目目标

本项目管理 Codex App 到 Linux 开发机的按需 SSH 反向隧道，使 Linux 上运行的 Codex 能够通过本机的 Clash 或其他代理服务访问外部服务。

项目包含 Windows 和 macOS 本地控制器、Linux Codex wrapper、SSH 配置示例、安装脚本、运行文档和静态检查。

## 项目结构

保持项目结构清晰、稳定，并遵循按职责和平台组织文件的原则：

- `README.md`：项目概览、快速开始和主要使用方式；
- `docs/`：架构、部署、运维和故障排查文档；
- `config/`：可提交的配置模板；真实机器配置必须单独存放并被 Git 忽略；
- `examples/`：脱敏、可复用的 SSH 和其他示例配置；
- `scripts/windows/`：Windows PowerShell、任务计划和启动器脚本；
- `scripts/macos/`：macOS launchd、控制器和隧道管理脚本；
- `scripts/linux/`：Linux Codex wrapper 和远端验证脚本；
- `tests/`：静态检查、语法检查和不修改外部状态的测试；
- `tmp/`：临时测试输出，只允许本地存在，必须被 Git 忽略；
- `artifacts/`：明确需要保留的构建或验证产物，默认不提交；
- `runtime/`：本地运行状态，禁止提交。

新增文件前必须判断它属于源代码、配置模板、文档、测试、临时输出还是交付产物，并放入对应目录。不得把新的源代码、脚本、日志、测试输出或机器生成文件直接放在仓库根目录。

如果仓库尚未忽略 `tmp/` 或 `artifacts/`，不得直接在其中生成输出；应先补充 `.gitignore`，或优先使用操作系统的临时目录。

## 敏感信息与安全

绝不提交以下内容：

- SSH 私钥、密码、API key、访问令牌或 cookies；
- `authorized_keys`、`known_hosts` 或运行日志；
- 真实 SSH 主机名、用户名、公网端口和机器专用 alias；
- 含有用户、主机、密钥路径或其他机器信息的导出文件；
- 未经脱敏的进程列表、命令行转储或调试输出。

跟踪的示例和测试只能使用保留域名、通用用户名、占位端口和通用 alias。真实配置必须放在未跟踪的本机文件中，例如 `config/tunnels.psd1` 或 macOS 本机配置文件。

## 平台兼容性

- Windows 脚本必须兼容 Windows PowerShell 5.1；
- Linux 脚本必须兼容 POSIX `sh`，除非 shebang 明确指定 Bash；
- macOS 脚本必须使用系统可用工具，避免无必要的第三方依赖；
- 新增平台实现不得破坏现有 Windows 和 Linux 行为；
- 不得为了 macOS 实现而无必要地改动 Windows 配置格式、任务逻辑或脚本接口。

## SSH、代理和进程规则

- 远端代理端点必须绑定到 `127.0.0.1`，不得扩大到 `0.0.0.0`、`*` 或其他可被局域网访问的地址；
- 不得启用 `GatewayPorts yes`；
- Codex 远程会话必须通过精确的 SSH alias 加上 `codex app-server proxy` 识别；
- 不得使用仅按主机名子串、alias 子串或模糊正则的匹配方式；
- Windows 隧道任务必须保持为按需任务并且触发器数量为零，只有控制器可以设置自动触发器；
- Windows 任务动作必须通过仓库中的无控制台启动器运行，不得直接把 `powershell.exe` 作为任务动作；
- 任何进程终止前，必须同时确认 PID、可执行文件名称以及配置中声明的精确 alias；
- 禁止使用 `pkill ssh`、`killall ssh` 或其他宽泛的批量终止命令；
- 除非确认 Linux wrapper 尚未安装并且获得明确授权，不得修改远端 Linux 主机、远端 SSH 配置、密钥或其他文件。

## 输出、日志和运行文件

### 存放位置

应用长期运行日志必须放在操作系统的用户级日志目录，不得写入 Git 仓库：

- macOS：`~/Library/Logs/Codex/<component>/`；
- Windows：`%LOCALAPPDATA%\Codex\<component>\`；
- Linux：`${XDG_STATE_HOME:-$HOME/.local/state}/codex/<component>/`。

测试产生的临时文件统一放到系统临时目录，或放到被 Git 忽略的目录：

```text
tmp/test-output/<run-id>-<platform>-<purpose>/
```

需要明确保留的结果才可以放到：

```text
artifacts/<category>/<run-id>-<purpose>/
```

不得在仓库根目录生成 `output.txt`、`debug.log`、`test.log`、`result.json`、`dump.txt` 等无归属文件。

### 命名规范

目录和文件名使用小写 `kebab-case`。运行批次使用不含空格和冒号的 UTC 时间戳：

```text
YYYYMMDD-HHMMSSZ
```

临时输出目录格式为：

```text
<run-id>-<platform>-<purpose>
```

例如：

```text
20260802-083000Z-macos-static-checks/
```

测试输出文件必须包含组件和输出流，例如：

```text
macos-static-checks.stdout.log
macos-static-checks.stderr.log
plist-rendered.xml
process-snapshot.txt
```

运行日志使用组件名和日期命名，例如：

```text
controller-20260802.log
primary-tunnel-20260802.log
```

禁止使用 `new.log`、`tmp1.txt`、`final-final.json` 等含义不明确的名称。新增长时间运行的日志必须考虑按日分文件、大小限制或保留周期，避免无限增长。

### 清理规范

每次测试必须使用独立的 run directory。测试结束后必须：

1. 阅读并确认必要结果；
2. 删除本次运行创建的临时输出；
3. 保留测试开始前已经存在的用户文件；
4. 如需长期保留，将结果移动到 `artifacts/` 并说明原因；
5. 用 `git status` 确认没有遗留的临时文件。

Shell 脚本应使用 `trap`，PowerShell 脚本应使用 `try/finally` 或等价机制清理临时文件。删除操作必须针对本次运行创建的明确路径，禁止对仓库根目录或宽泛目录执行递归删除。

日志和测试输出中不得包含未脱敏的密钥、令牌、密码或真实机器信息。若必须记录命令行，提交前必须脱敏。

## 开发准则

- 修改前先阅读相关源码、配置、文档和测试；
- 保留用户已有的未提交修改，不得覆盖或重置无关文件；
- 保持修改范围最小，优先复用已有接口和行为；
- 不引入不必要的新依赖；
- 行为变更必须同步更新文档、测试和 `CHANGELOG.md`；
- 调试代码、临时补丁和测试输出不得提交；
- 涉及系统任务、launchd、任务计划、SSH 配置或远端主机的测试，必须明确说明副作用和清理方式；
- 用户未明确要求时，不创建提交、不推送分支、不修改远端仓库。

## 验证要求

静态检查和测试必须尽量不修改计划任务、launchd、SSH 配置、远端主机或用户数据。

提交前至少运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-StaticChecks.ps1
git diff --check
git status
```

修改 Linux 脚本时还必须运行：

```bash
bash -n scripts/linux/*.sh
```

修改 macOS 脚本时必须运行对应的 POSIX shell 语法检查和 macOS 静态测试。若当前环境不是 Windows，必须在可用的 Windows PowerShell 5.1 环境或 CI 中验证原有 Windows 静态检查。

最终报告必须说明：

- 修改了哪些文件和行为；
- 使用了哪些假设；
- 执行了哪些验证；
- 哪些验证未执行以及原因；
- 是否残留临时文件、日志或外部系统状态。
