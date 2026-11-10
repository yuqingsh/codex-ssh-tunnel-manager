#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
common_path="$repository_root/scripts/macos/codex-ssh-tunnel-common.sh"
example_config="$repository_root/config/tunnels.macos.example.conf"
install_script="$repository_root/scripts/macos/install-codex-ssh-tunnel-manager.sh"
uninstall_script="$repository_root/scripts/macos/uninstall-codex-ssh-tunnel-manager.sh"
setup_script="$repository_root/scripts/macos/setup-codex-ssh-tunnel-manager.sh"
controller_script="$repository_root/scripts/macos/codex-ssh-tunnel-controller.sh"
runner_script="$repository_root/scripts/macos/codex-ssh-tunnel-runner.sh"
status_script="$repository_root/scripts/macos/get-codex-ssh-tunnel-status.sh"
failures=0
temp_root=$(printenv TMPDIR 2>/dev/null || true)
if [ -z "$temp_root" ]; then
    temp_root=/tmp
fi
check_tmp=$(mktemp -d "$temp_root/codex-ssh-tunnel-manager-XXXXXX")
trap 'rm -rf "$check_tmp"' EXIT HUP INT TERM

fail() {
    printf '失败：%s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_file_contains() {
    if ! grep -F "$2" "$1" >/dev/null 2>&1; then
        fail "$3"
    fi
}

assert_file_not_contains() {
    if grep -F "$2" "$1" >/dev/null 2>&1; then
        fail "$3"
    fi
}

for script_path in "$repository_root"/scripts/macos/*.sh; do
    if [ ! -x "$script_path" ]; then
        fail "macOS 脚本没有执行权限：$script_path"
    fi
    if ! sh -n "$script_path"; then
        fail "shell 语法检查失败：$script_path"
    fi
done

# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$common_path"

if ! codex_config_validate "$example_config"; then
    fail 'macOS 示例配置校验失败'
fi

if [ "$(codex_retry_delay 1 30 600)" != '30' ] || \
    [ "$(codex_retry_delay 2 30 600)" != '60' ] || \
    [ "$(codex_retry_delay 4 30 600)" != '240' ] || \
    [ "$(codex_retry_delay 6 30 600)" != '600' ] || \
    [ "$(codex_retry_delay 9 30 600)" != '600' ] || \
    [ "$(codex_retry_delay 1 5 300)" != '5' ]; then
    fail '启动失败退避计算不正确'
fi

jitter_first=$(codex_jittered_delay 30 1000)
if [ "$jitter_first" != "$(codex_jittered_delay 30 1000)" ]; then
    fail 'codex_jittered_delay 不是确定性的'
fi
if [ "$jitter_first" -lt 30 ] || [ "$jitter_first" -gt 37 ]; then
    fail "codex_jittered_delay 抖动超出 base + 0..base/4 范围：$jitter_first"
fi
if [ "$(codex_jittered_delay 1 3)" -lt 5 ] || [ "$(codex_jittered_delay 4 9)" -lt 5 ]; then
    fail 'codex_jittered_delay 没有应用 5 秒下限'
fi
jitter_values=
for jitter_now in 1000 1001 1002 1003 1004 1005; do
    jitter_values="$jitter_values $(codex_jittered_delay 30 "$jitter_now")"
done
jitter_distinct=$(printf '%s\n' $jitter_values | sort -u | wc -l | tr -d ' ')
if [ "$jitter_distinct" -lt 2 ]; then
    fail 'codex_jittered_delay 对不同 now 没有产生抖动'
fi

assert_classify() {
    classify_expected=$1
    classify_text=$2
    classify_actual=$(codex_classify_tunnel_error "$classify_text")
    if [ "$classify_actual" != "$classify_expected" ]; then
        fail "失败分类不正确：期望 $classify_expected，实际 $classify_actual（文本：$classify_text）"
    fi
}
assert_classify port-conflict 'Warning: remote port forwarding failed for listen port 17898'
assert_classify port-conflict 'REMOTE PORT FORWARDING FAILED for listen port 17898'
for network_text in \
    'ssh: connect to host example.invalid port 22: timed out' \
    'ssh: connect to host example.invalid port 22: Connection refused' \
    'ssh: Could not resolve hostname example.invalid' \
    'ssh: connect to host example.invalid port 22: Network is unreachable' \
    'ssh: connect to host example.invalid port 22: No route to host' \
    'Connection reset by peer' \
    'write: Broken pipe' \
    'Permission denied (publickey)'; do
    assert_classify network "$network_text"
done
assert_classify unknown 'ssh: some unexpected failure'
assert_classify unknown ''

error_log_root="$check_tmp/tunnel-stderr-logs"
CODEX_SSH_TUNNEL_LOG_ROOT="$error_log_root"
export CODEX_SSH_TUNNEL_LOG_ROOT
error_log=$(codex_tunnel_stderr_log primary)
case "$error_log" in
    "$error_log_root"/primary-tunnel.stderr.log) ;;
    *)
        fail "codex_tunnel_stderr_log 路径不正确：$error_log"
        ;;
esac
mkdir -p "$error_log_root"
printf '%s\n' \
    '[runner-marker] 2026-01-01T00:00:00Z alias=primary-proxy' \
    'stale failure from an earlier attempt' \
    '[runner-marker] 2026-01-01T00:00:05Z alias=primary-proxy' \
    'Warning: remote port forwarding failed for listen port 17898' > "$error_log"
if [ "$(codex_last_tunnel_error primary)" != 'Warning: remote port forwarding failed for listen port 17898' ]; then
    fail 'codex_last_tunnel_error 没有截取最后一次 marker 之后的文本'
fi
if [ -n "$(codex_last_tunnel_error no-such-tunnel)" ]; then
    fail 'codex_last_tunnel_error 对不存在的日志没有输出空字符串'
fi
awk 'BEGIN { for (i = 1; i <= 55; i++) printf "line-%d\n", i }' > "$error_log"
if [ "$(codex_last_tunnel_error primary | wc -l | tr -d ' ')" != '50' ]; then
    fail 'codex_last_tunnel_error 在没有 marker 时没有回退到尾部 50 行'
fi
if [ "$(codex_last_tunnel_error primary | sed -n '1p')" != 'line-6' ]; then
    fail 'codex_last_tunnel_error 在没有 marker 时的 tail 起始行不正确'
fi
unset CODEX_SSH_TUNNEL_LOG_ROOT

tunnel_names=$(codex_config_tunnel_names "$example_config" | tr '\n' ' ' | sed 's/[[:space:]]*$//')
if [ "$tunnel_names" != 'primary secondary' ]; then
    fail "macOS 示例隧道列表不正确：$tunnel_names"
fi
tunnel_count=0
for tunnel_name in $(codex_config_tunnel_names "$example_config"); do
    tunnel_count=$((tunnel_count + 1))
done
if [ "$tunnel_count" -ne 2 ]; then
    fail "配置校验污染了调用方 IFS，隧道数量为：$tunnel_count"
fi

if [ "$(codex_tunnel_config_get "$example_config" primary DEV_ALIAS)" != 'primary-dev' ]; then
    fail 'primary DevAlias 不正确'
fi
if [ "$(codex_tunnel_config_get "$example_config" secondary PROXY_ALIAS)" != 'secondary-proxy' ]; then
    fail 'secondary ProxyAlias 不正确'
fi

if ! codex_command_has_session_signature primary-dev 'ssh -T primary-dev sh -c codex app-server proxy'; then
    fail '精确 DevAlias 没有匹配自身 Codex 会话'
fi
if codex_command_has_session_signature primary-dev 'ssh -T primary-dev-extra sh -c codex app-server proxy'; then
    fail 'DevAlias 错误匹配了 lookalike alias'
fi
if codex_command_has_session_signature primary-dev 'ssh -T primary-dev hostname'; then
    fail '普通 SSH 命令错误触发了 Codex 会话匹配'
fi
if ! codex_command_has_tunnel_flags 'ssh -N -T primary-proxy'; then
    fail '隧道 SSH 参数没有被识别'
fi
if codex_command_has_tunnel_flags 'ssh primary-proxy hostname'; then
    fail '普通 SSH 命令错误被识别为隧道'
fi

unsafe_config="$check_tmp/unsafe.conf"
sed 's/^LOCAL_PROXY_HOST=127\.0\.0\.1$/LOCAL_PROXY_HOST=0.0.0.0/' "$example_config" > "$unsafe_config"
if codex_config_validate "$unsafe_config" >/dev/null 2>&1; then
    fail '配置校验允许非 loopback 代理地址'
fi

duplicate_config="$check_tmp/duplicate.conf"
sed 's/^TUNNEL_SECONDARY_PROXY_ALIAS=secondary-proxy$/TUNNEL_SECONDARY_PROXY_ALIAS=primary-proxy/' "$example_config" > "$duplicate_config"
if codex_config_validate "$duplicate_config" >/dev/null 2>&1; then
    fail '配置校验允许重复 ProxyAlias'
fi

for mac_script in "$repository_root"/scripts/macos/*.sh; do
    assert_file_not_contains "$mac_script" 'pkill ssh' "发现宽泛 pkill ssh：$mac_script"
    assert_file_not_contains "$mac_script" 'killall ssh' "发现宽泛 killall ssh：$mac_script"
    assert_file_not_contains "$mac_script" '0.0.0.0' "发现非 loopback 地址：$mac_script"
    assert_file_not_contains "$mac_script" 'GatewayPorts yes' "发现 GatewayPorts yes：$mac_script"
done

assert_file_contains "$install_script" '<key>RunAtLoad</key>' '安装器未生成 RunAtLoad 设置'
assert_file_contains "$install_script" '<key>KeepAlive</key>' '安装器未生成 KeepAlive 设置'
assert_file_contains "$install_script" '<true/>' '控制器未设置自动恢复/启动'
assert_file_contains "$install_script" '<false/>' '隧道任务未显式关闭自动启动语义'
assert_file_contains "$install_script" 'launchctl kickstart' '控制器未按需 kickstart 隧道'
assert_file_contains "$install_script" 'launchctl bootstrap' '安装器未加载 launchd 任务'
assert_file_contains "$install_script" 'codex_stop_validated_pid' '安装器未在终止前验证 PID、可执行文件和 alias'
assert_file_contains "$uninstall_script" 'codex_stop_validated_pid' '卸载器未在终止前验证 PID、可执行文件和 alias'
assert_file_contains "$setup_script" 'mktemp -d' '初始化向导未使用独立临时目录'
assert_file_contains "$setup_script" 'trap' '初始化向导未清理临时目录'
assert_file_contains "$setup_script" 'RemoteForward 127.0.0.1:' '初始化向导未生成 loopback RemoteForward'
assert_file_contains "$setup_script" 'codex_config_validate' '初始化向导未校验生成的配置'
assert_file_contains "$setup_script" 'gsub(/\]:/, ":", remote)' '初始化向导未兼容 ssh -G 的括号化回环地址'
assert_file_contains "$controller_script" 'state_write "$start_name" "$start_now" 0 0 "$start_now"' 'controller 未按隧道名称写入已存在隧道状态'
assert_file_contains "$controller_script" 'state_write "$start_name" "$start_now" "$start_failures" "$start_retry_at" 0' 'controller 未按隧道名称写入启动失败状态'
assert_file_contains "$controller_script" 'state_write "$cycle_name" "$cycle_now" "$state_failures" "$state_retry_at" 0' 'controller 未按隧道名称写入会话状态'
assert_file_contains "$controller_script" 'codex_retry_delay "$cycle_failures" "$cycle_retry_base" "$cycle_retry_max"' 'controller 未对隧道启动失败应用指数退避'
assert_file_contains "$controller_script" 'CODEX_SSH_TUNNEL_CONFLICT_BASE_SECONDS:-15' 'controller 缺少远端端口冲突退避基数（默认 15 秒）'
assert_file_contains "$controller_script" 'CODEX_SSH_TUNNEL_CONFLICT_MAX_SECONDS:-300' 'controller 缺少远端端口冲突退避上限（默认 300 秒）'
assert_file_contains "$controller_script" 'codex_last_tunnel_error' 'controller 未读取 tunnel stderr 判断失败原因'
assert_file_contains "$controller_script" 'codex_classify_tunnel_error' 'controller 未对失败原因分类'
assert_file_contains "$controller_script" 'codex_jittered_delay "$cycle_retry_delay" "$cycle_now"' 'controller 未在退避时间上叠加抖动'
assert_file_contains "$controller_script" '远端端口被占用（可能来自另一台客户端或残留连接）；' 'controller 端口冲突日志缺少明确原因'
assert_file_contains "$controller_script" '连续端口冲突' 'controller 连续端口冲突时缺少检查提示'
assert_file_contains "$controller_script" '远端防火墙封禁本机公网 IP' 'controller 网络故障日志丢失原有封禁提示'
assert_file_contains "$runner_script" '[runner-marker]' 'tunnel runner 未写 [runner-marker] 标记'
assert_file_contains "$runner_script" 'alias=$proxy_alias' 'tunnel runner marker 未包含 proxy alias'
runner_marker_line=$(grep -n -F '[runner-marker]' "$runner_script" | sed -n '1p' | cut -d: -f1)
runner_exec_line=$(grep -n -F 'exec /usr/bin/ssh' "$runner_script" | sed -n '1p' | cut -d: -f1)
if [ -z "$runner_marker_line" ] || [ -z "$runner_exec_line" ] || \
    [ "$runner_marker_line" -ge "$runner_exec_line" ]; then
    fail "tunnel runner marker 没有写在 exec ssh 之前：marker=$runner_marker_line exec=$runner_exec_line"
fi
assert_file_contains "$status_script" 'ProxyAlias\tRemoteProxyPort' '状态输出表头缺少 ProxyAlias 之后的 RemoteProxyPort 列'
assert_file_contains "$status_script" 'remote_proxy_port=$(codex_config_get "$config_path" REMOTE_PROXY_PORT)' '状态脚本未从配置读取 REMOTE_PROXY_PORT'
assert_file_contains "$setup_script" '17898' '初始化向导缺少远端端口默认值 17898'
assert_file_contains "$setup_script" '每台客户端端口必须不同' '初始化向导缺少多客户端端口唯一性提示'
assert_file_contains "$setup_script" 'endpoints.conf' '初始化向导缺少 Linux 端点文件名提示'
assert_file_contains "$setup_script" 'install-codex-wrapper.sh' '初始化向导缺少 Linux wrapper 安装命令提示'
if ! grep -E 'setup_remote_proxy_port=\$\(prompt_default .* 17898\)' "$setup_script" >/dev/null 2>&1; then
    fail '初始化向导的远端端口默认值不是 17898'
fi
assert_file_contains "$controller_script" 'tunnel_healthy_seconds' 'controller 未定义稳定运行阈值'
assert_file_contains "$common_path" 'codex_retry_delay()' 'common 缺少退避计算函数'
if grep -E 'state_write "\$(start_now|cycle_now)"' "$controller_script" >/dev/null 2>&1; then
    fail 'controller 存在缺少隧道名称参数的 state_write 调用'
fi
if ! "$setup_script" --help >/dev/null 2>&1; then
    fail '初始化向导帮助命令失败'
fi

if [ ! -x /usr/bin/plutil ]; then
    fail 'macOS plutil 不可用，无法验证 launchd plist'
else
    render_root="$check_tmp/rendered"
    if ! "$install_script" --config "$example_config" --render-only "$render_root" >/dev/null 2>&1; then
        fail '安装器 render-only 模式失败'
    else
        controller_plist="$render_root/LaunchAgents/com.codex.ssh-tunnel-manager.controller.plist"
        primary_plist="$render_root/LaunchAgents/com.codex.ssh-tunnel-manager.tunnel.primary.plist"
        controller_run_at_load=$(/usr/bin/plutil -extract RunAtLoad raw -o - "$controller_plist")
        controller_keep_alive=$(/usr/bin/plutil -extract KeepAlive raw -o - "$controller_plist")
        tunnel_run_at_load=$(/usr/bin/plutil -extract RunAtLoad raw -o - "$primary_plist")
        tunnel_keep_alive=$(/usr/bin/plutil -extract KeepAlive raw -o - "$primary_plist")
        if [ "$controller_run_at_load" != 'true' ] || [ "$controller_keep_alive" != 'true' ]; then
            fail 'controller plist 没有设置 RunAtLoad=true 和 KeepAlive=true'
        fi
        if [ "$tunnel_run_at_load" != 'false' ] || [ "$tunnel_keep_alive" != 'false' ]; then
            fail 'tunnel plist 没有保持无自动启动语义'
        fi
    fi
fi

if ! sh "$repository_root/tests/test-cursor-sessions.sh"; then
    fail 'Cursor 会话识别或控制器生命周期测试失败'
fi

if [ ! -f "$repository_root/tests/test-linux-wrapper.sh" ]; then
    fail '缺少 tests/test-linux-wrapper.sh（Linux 端点契约测试）'
elif ! sh "$repository_root/tests/test-linux-wrapper.sh"; then
    fail 'Linux wrapper 端点契约测试失败'
fi

if [ "$failures" -gt 0 ]; then
    printf 'macOS 静态检查失败：%s 项。\n' "$failures" >&2
    exit 1
fi

printf 'macOS 静态检查通过。\n'
