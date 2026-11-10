# Changelog

All notable changes to this project are documented in this file. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-11-10

### Added

- 支持多台客户端同时连接同一台 Linux 开发机：每台客户端使用独立的 Linux 回环端口，Windows 默认 `17897`、macOS 默认 `17898`，更多客户端使用 `17899` 及以后。
- Linux Codex wrapper 读取端点列表（`~/.config/codex-ssh-tunnel-manager/endpoints.conf`），按顺序做真实代理探测并选择第一个可用端点；全部不可用时回退第一个端点，并向状态日志追加告警。
- 新增 `config/tunnel-endpoints.example.conf` 端点模板、`install-codex-wrapper.sh --endpoint` 选项，以及覆盖环境变量优先、单端点直用、多端点探测与回退、非法行忽略、代理变量注入和参数透传的 wrapper 行为测试。
- 两平台控制器新增失败分类：区分 `port-conflict`、`network` 和 `unknown`，分别使用不同退避曲线并加入抖动；Windows 控制器补齐与 macOS 等价的指数退避，隧道稳定运行 60 秒后重置失败计数。
- macOS 状态输出新增 `RemoteProxyPort` 列，`verify-remote-codex.sh` 逐行输出 `ENDPOINT=<url> PROBE=<状态>`，便于多客户端场景定位可用端点。
- 新增 macOS Cursor Remote SSH 需求检测：精确解析 SSH 目标并校验 Cursor 进程祖先链，与现有 Codex 隧道和空闲宽限期共用。
- 状态输出分别报告 Codex 与 Cursor 会话数量；文档记录每台主机上的 Cursor 代理设置与服务器重启；新增匹配排除和控制器生命周期测试，且不修改系统状态。
- 新增 macOS 用户级 launchd 控制器与无触发器的按需隧道任务。
- 新增 macOS 配置、安装、状态、检查、卸载和静态检查脚本。
- 新增交互式 macOS 初始化向导：探测 Clash 端口、生成机器本地配置、可选管理专用 SSH include，并调用 launchd 安装器。
- 新增 macOS 部署与使用文档，同时保持 Windows 与 Linux 实现不变。

### Changed

- macOS 默认远端代理端口由 `17897` 改为 `17898`；配置模板、初始化向导、状态输出和相关文档同步更新，Windows 默认端口保持 `17897`。
- Linux wrapper 在存在多个端点时改为探测后选择，`CODEX_PROXY_URL` 显式覆盖和单端点直用行为保持不变。
- 控制器日志按失败类型区分提示：端口冲突提示检查端点规划与残留连接，网络故障保留远端防火墙封禁提示。
- Linux wrapper 安装器新增端点文件管理：`--endpoint` 可重复、校验后去重、原子写入并设置 `600` 权限，已有文件先备份为带 UTC 时间戳的 `.bak` 文件。

### Fixed

- 修复 Windows 与 macOS 争抢同一远端端口（Linux `127.0.0.1:17897`）导致反复 bind 失败与重试风暴的问题：端口冲突被单独归类并采用专用退避，不再被当作网络故障处理，Windows 控制器也不再无退避地重复启动。
- Windows 隧道任务不再由任务计划程序每分钟自动重启失败任务；失败重试完全由控制器按分类退避控制。
- 修复 macOS 控制器对不可达或重启中主机的重试风暴：统计连续启动失败次数，从 30 秒开始指数退避到 10 分钟，隧道稳定运行 60 秒后重置，并记录会在重试前提示远端防火墙 IP 封禁的诊断信息。
- 文档说明 Cursor 原生 Agent 的独立推理路由：仅设置代理环境变量不能覆盖其远端 HTTP/2 传输。按远端配置内置的本地客户端跳转，并在验收时要求实际聊天回复和路由校验。
- 修复 macOS 控制器在 POSIX shell `set -u` 下状态写入时隧道名与各字段传递不一致的问题。

## [0.2.0] - 2026-07-15

### Changed

- Publish the project under the MIT License.
- Replace machine-specific SSH endpoints, aliases, users, ports, and task names with reusable examples.
- Replace the private deployment history with a clean public release history.

## [0.1.1] - 2026-07-14

### Added

- Windows bootstrap guide for cloning the repository and installing the demand-driven behavior.

### Fixed

- Run scheduled controller and tunnel tasks through a no-console Windows Script Host launcher so background tasks do not create blank PowerShell windows.
- Handle stopped tunnels without a `ProcessId` property in the status command under strict mode.

## [0.1.0] - 2026-07-13

### Added

- Demand-driven controller for two Codex remote SSH sessions.
- On-demand reverse-tunnel launcher with Clash readiness and SSH keepalive checks.
- Idempotent Windows installer, uninstaller, status command, and public-key helper.
- Linux Codex proxy wrapper and remote transport verification script.
- Static validation for PowerShell syntax, configuration, matching rules, and secret markers.
