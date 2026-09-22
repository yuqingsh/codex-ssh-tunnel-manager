#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s --config 配置文件 [--once]\n' "$0" >&2
}

config_path=
controller_marker_alias=
run_once=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            config_path=$2
            shift 2
            ;;
        --once)
            run_once=1
            shift
            ;;
        --controller-marker-alias)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            controller_marker_alias=$2
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

if [ -z "$config_path" ]; then
    usage
    exit 64
fi

codex_config_validate "$config_path"

if [ -n "$controller_marker_alias" ] && ! codex_validate_alias "$controller_marker_alias"; then
    printf 'controller marker alias 无效：%s\n' "$controller_marker_alias" >&2
    exit 65
fi

poll_seconds=$(codex_config_get "$config_path" POLL_SECONDS)
stop_grace_minutes=$(codex_config_get "$config_path" STOP_GRACE_MINUTES)
local_proxy_host=$(codex_config_get "$config_path" LOCAL_PROXY_HOST)
local_proxy_port=$(codex_config_get "$config_path" LOCAL_PROXY_PORT)
tunnel_label_prefix=$(codex_config_get "$config_path" TUNNEL_LABEL_PREFIX)
install_root=${CODEX_SSH_TUNNEL_INSTALL_ROOT:-$(codex_default_install_root)}
state_root=${CODEX_SSH_TUNNEL_STATE_ROOT:-$(codex_default_state_root)}
runner_path="$install_root/codex-ssh-tunnel-runner.sh"
stop_grace_seconds=$((stop_grace_minutes * 60))

mkdir -p "$state_root" || {
    printf '无法创建状态目录：%s\n' "$state_root" >&2
    exit 1
}
chmod 700 "$state_root" 2>/dev/null || true

state_path() {
    printf '%s/%s.state\n' "$state_root" "$1"
}

state_reset() {
    state_file=$(state_path "$1")
    printf '0\n0\n0\n' > "$state_file"
    chmod 600 "$state_file" 2>/dev/null || true
}

state_read() {
    state_file=$(state_path "$1")
    if [ ! -f "$state_file" ]; then
        state_reset "$1"
    fi
    state_last_seen=$(sed -n '1p' "$state_file" 2>/dev/null || printf '0')
    state_failures=$(sed -n '2p' "$state_file" 2>/dev/null || printf '0')
    state_retry_at=$(sed -n '3p' "$state_file" 2>/dev/null || printf '0')
    case "$state_last_seen" in ''|*[!0-9]*) state_last_seen=0 ;; esac
    case "$state_failures" in ''|*[!0-9]*) state_failures=0 ;; esac
    case "$state_retry_at" in ''|*[!0-9]*) state_retry_at=0 ;; esac
}

state_write() {
    state_file=$(state_path "$1")
    printf '%s\n%s\n%s\n' "$2" "$3" "$4" > "$state_file"
    chmod 600 "$state_file" 2>/dev/null || true
}

count_lines() {
    printf '%s\n' "$1" | awk 'NF { count += 1 } END { print count + 0 }'
}

retry_delay() {
    retry_failures=$1
    retry_delay_value=$poll_seconds
    retry_step=1
    while [ "$retry_step" -lt "$retry_failures" ] && [ "$retry_delay_value" -lt 300 ]; do
        retry_delay_value=$((retry_delay_value * 2))
        if [ "$retry_delay_value" -gt 300 ]; then
            retry_delay_value=300
        fi
        retry_step=$((retry_step + 1))
    done
    printf '%s\n' "$retry_delay_value"
}

log_controller() {
    codex_log controller "$*" || true
}

stop_pid_safely() {
    stop_pid=$1
    stop_alias=$2
    if ! codex_pid_alive "$stop_pid"; then
        return 0
    fi
    if ! codex_pid_matches_tunnel "$stop_pid" "$stop_alias" "$runner_path"; then
        log_controller "拒绝终止 PID $stop_pid：可执行文件或 alias 不符合配置"
        return 1
    fi

    /bin/kill -TERM "$stop_pid" 2>/dev/null || true
    stop_wait=0
    while [ "$stop_wait" -lt 10 ]; do
        if ! codex_pid_alive "$stop_pid"; then
            return 0
        fi
        sleep 1
        stop_wait=$((stop_wait + 1))
    done

    if codex_pid_alive "$stop_pid" && codex_pid_matches_tunnel "$stop_pid" "$stop_alias" "$runner_path"; then
        /bin/kill -KILL "$stop_pid" 2>/dev/null || true
    fi
}

stop_tunnel() {
    stop_name=$1
    stop_alias=$2
    stop_label=$3
    stop_job_pid=$(codex_launchd_job_pid "$stop_label")
    stop_ssh_pids=$(codex_find_tunnel_pids "$stop_alias")
    stop_all_pids="$stop_job_pid $stop_ssh_pids"

    for stop_pid in $stop_all_pids; do
        [ -n "$stop_pid" ] || continue
        stop_pid_safely "$stop_pid" "$stop_alias" || true
    done
    log_controller "已请求停止隧道：$stop_name ($stop_alias)"
}

start_tunnel() {
    start_name=$1
    start_alias=$2
    start_label=$3
    start_now=$4
    state_read "$start_name"

    if [ "$start_now" -lt "$state_retry_at" ]; then
        return 0
    fi

    start_existing_pid=$(codex_find_tunnel_pid "$start_label" "$start_alias" "$runner_path")
    if [ -n "$start_existing_pid" ]; then
        state_write "$start_name" "$start_now" 0 0
        return 0
    fi

    if ! codex_tcp_ready "$local_proxy_host" "$local_proxy_port"; then
        start_failures=$((state_failures + 1))
        start_delay=$(retry_delay "$start_failures")
        start_retry_at=$((start_now + start_delay))
        state_write "$start_name" "$start_now" "$start_failures" "$start_retry_at"
        log_controller "Clash 不可用：$local_proxy_host:$local_proxy_port；$start_delay 秒后重试 $start_name"
        return 0
    fi

    if ! codex_launchd_kickstart "$start_label" >/dev/null 2>&1; then
        start_failures=$((state_failures + 1))
        start_delay=$(retry_delay "$start_failures")
        start_retry_at=$((start_now + start_delay))
        state_write "$start_name" "$start_now" "$start_failures" "$start_retry_at"
        log_controller "无法按需启动 launchd 隧道任务：$start_label；$start_delay 秒后重试"
        return 0
    fi

    state_write "$start_name" "$start_now" 0 "$((start_now + poll_seconds))"
    log_controller "检测到 Codex/Cursor 远程会话，已请求启动隧道：$start_name ($start_alias)"
}

run_cycle() {
    cycle_now=$(date +%s)
    for cycle_name in $(codex_config_tunnel_names "$config_path"); do
        cycle_dev_alias=$(codex_tunnel_config_get "$config_path" "$cycle_name" DEV_ALIAS)
        cycle_proxy_alias=$(codex_tunnel_config_get "$config_path" "$cycle_name" PROXY_ALIAS)
        cycle_label=$(codex_tunnel_label "$tunnel_label_prefix" "$cycle_name")
        cycle_session_pids=$(codex_find_session_pids "$cycle_dev_alias")
        cycle_tunnel_pid=$(codex_find_tunnel_pid "$cycle_label" "$cycle_proxy_alias" "$runner_path")
        state_read "$cycle_name"

        if [ -n "$cycle_session_pids" ]; then
            if [ -z "$cycle_tunnel_pid" ]; then
                state_write "$cycle_name" "$cycle_now" "$state_failures" "$state_retry_at"
                start_tunnel "$cycle_name" "$cycle_proxy_alias" "$cycle_label" "$cycle_now"
            else
                state_write "$cycle_name" "$cycle_now" 0 0
            fi
            continue
        fi

        if [ -n "$cycle_tunnel_pid" ]; then
            if [ "$state_last_seen" -eq 0 ]; then
                state_write "$cycle_name" "$cycle_now" 0 0
                log_controller "未检测到 $cycle_dev_alias 的 Codex/Cursor 会话，开始 ${stop_grace_minutes} 分钟停止宽限期"
            elif [ "$((cycle_now - state_last_seen))" -ge "$stop_grace_seconds" ]; then
                log_controller "$cycle_dev_alias 已连续 ${stop_grace_minutes} 分钟没有 Codex/Cursor 会话，停止隧道"
                stop_tunnel "$cycle_name" "$cycle_proxy_alias" "$cycle_label"
                state_reset "$cycle_name"
            fi
        else
            state_reset "$cycle_name"
        fi
    done
}

for initial_name in $(codex_config_tunnel_names "$config_path"); do
    state_reset "$initial_name"
done

log_controller "macOS 需求控制器启动：poll=${poll_seconds}s，stop-grace=${stop_grace_minutes}m"

while :; do
    run_cycle
    if [ "$run_once" -eq 1 ]; then
        exit 0
    fi
    sleep "$poll_seconds"
done
