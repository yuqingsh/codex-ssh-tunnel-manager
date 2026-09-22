#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s [--config 配置文件] [--install-root 目录]\n' "$0" >&2
}

config_path=$(codex_default_install_root)/tunnels.macos.conf
install_root=$(codex_default_install_root)
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            config_path=$2
            shift 2
            ;;
        --install-root)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            install_root=$2
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 64
            ;;
    esac
done

case "$install_root" in
    *'/../'*|*/..|../*)
        printf '拒绝使用包含父目录跳转的安装路径：%s\n' "$install_root" >&2
        exit 65
        ;;
    "$HOME/Library/Application Support/Codex"/*)
        ;;
    *)
        printf '拒绝使用安装目录（必须位于用户的 Codex Application Support 目录）：%s\n' "$install_root" >&2
        exit 65
        ;;
esac

codex_config_validate "$config_path"

tunnel_label_prefix=$(codex_config_get "$config_path" TUNNEL_LABEL_PREFIX)
controller_label=$(codex_config_get "$config_path" CONTROLLER_LABEL)
runner_path="$install_root/codex-ssh-tunnel-runner.sh"
local_proxy_host=$(codex_config_get "$config_path" LOCAL_PROXY_HOST)
local_proxy_port=$(codex_config_get "$config_path" LOCAL_PROXY_PORT)

count_lines() {
    printf '%s\n' "$1" | awk 'NF { count += 1 } END { print count + 0 }'
}

launchd_state() {
    status_label=$1
    status_pid=$(codex_launchd_job_pid "$status_label")
    if [ -n "$status_pid" ] && codex_pid_alive "$status_pid"; then
        printf 'Running\t%s' "$status_pid"
        return 0
    fi
    if codex_launchd_job_loaded "$status_label"; then
        printf 'Loaded\t-'
    else
        printf 'Missing\t-'
    fi
}

printf 'Type\tName\tDevAlias\tProxyAlias\tLaunchdState\tLaunchdPID\tActiveCodexSessions\tTunnelSSHProcesses\tProcessIDs\tLocalProxyReachable\tActiveCursorSessions\n'
controller_status=$(launchd_state "$controller_label")
controller_state=$(printf '%s' "$controller_status" | awk -F '\t' '{print $1}')
controller_pid=$(printf '%s' "$controller_status" | awk -F '\t' '{print $2}')
local_proxy_reachable=false
if codex_tcp_ready "$local_proxy_host" "$local_proxy_port"; then
    local_proxy_reachable=true
fi
printf 'Controller\t%s\t-\t-\t%s\t%s\t-\t-\t-\t%s\t-\n' \
    "$controller_label" "$controller_state" "$controller_pid" "$local_proxy_reachable"

for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
    dev_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" DEV_ALIAS)
    proxy_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" PROXY_ALIAS)
    tunnel_label=$(codex_tunnel_label "$tunnel_label_prefix" "$tunnel_name")
    tunnel_status=$(launchd_state "$tunnel_label")
    tunnel_state=$(printf '%s' "$tunnel_status" | awk -F '\t' '{print $1}')
    tunnel_pid=$(printf '%s' "$tunnel_status" | awk -F '\t' '{print $2}')
    session_pids=$(codex_find_session_pids "$dev_alias" codex)
    cursor_session_pids=$(codex_find_session_pids "$dev_alias" cursor)
    tunnel_pids=$(codex_find_tunnel_pids "$proxy_alias")
    session_count=$(count_lines "$session_pids")
    cursor_session_count=$(count_lines "$cursor_session_pids")
    tunnel_count=$(count_lines "$tunnel_pids")
    if [ -n "$tunnel_pid" ] && [ "$tunnel_pid" != '-' ]; then
        case " $tunnel_pids " in
            *" $tunnel_pid "*)
                ;;
            *)
                tunnel_count=$((tunnel_count + 1))
                ;;
        esac
    fi
    if [ -n "$tunnel_pids" ]; then
        process_ids=$(printf '%s' "$tunnel_pids" | tr '\n' ',' | sed 's/,$//')
    else
        process_ids=-
    fi
    printf 'Tunnel\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t-\t%s\n' \
        "$tunnel_name" "$dev_alias" "$proxy_alias" "$tunnel_state" "$tunnel_pid" \
        "$session_count" "$tunnel_count" "$process_ids" "$cursor_session_count"
done
