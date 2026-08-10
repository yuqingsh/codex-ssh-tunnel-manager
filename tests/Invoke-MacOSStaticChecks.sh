#!/bin/sh

set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
common_path="$repository_root/scripts/macos/codex-ssh-tunnel-common.sh"
example_config="$repository_root/config/tunnels.macos.example.conf"
install_script="$repository_root/scripts/macos/install-codex-ssh-tunnel-manager.sh"
uninstall_script="$repository_root/scripts/macos/uninstall-codex-ssh-tunnel-manager.sh"
setup_script="$repository_root/scripts/macos/setup-codex-ssh-tunnel-manager.sh"
controller_script="$repository_root/scripts/macos/codex-ssh-tunnel-controller.sh"
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
assert_file_contains "$controller_script" 'state_write "$start_name" "$start_now" 0 0' 'controller 未按隧道名称写入已存在隧道状态'
assert_file_contains "$controller_script" 'state_write "$start_name" "$start_now" "$start_failures" "$start_retry_at"' 'controller 未按隧道名称写入启动失败状态'
assert_file_contains "$controller_script" 'state_write "$cycle_name" "$cycle_now" "$state_failures" "$state_retry_at"' 'controller 未按隧道名称写入会话状态'
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

if [ "$failures" -gt 0 ]; then
    printf 'macOS 静态检查失败：%s 项。\n' "$failures" >&2
    exit 1
fi

printf 'macOS 静态检查通过。\n'
