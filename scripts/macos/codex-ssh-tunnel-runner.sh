#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s --config 配置文件 --proxy-alias SSH代理alias\n' "$0" >&2
}

config_path=
proxy_alias=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            config_path=$2
            shift 2
            ;;
        --proxy-alias)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            proxy_alias=$2
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

if [ -z "$config_path" ] || [ -z "$proxy_alias" ]; then
    usage
    exit 64
fi

codex_config_validate "$config_path"

tunnel_name=
for candidate_name in $(codex_config_tunnel_names "$config_path"); do
    candidate_alias=$(codex_tunnel_config_get "$config_path" "$candidate_name" PROXY_ALIAS)
    if [ "$candidate_alias" = "$proxy_alias" ]; then
        tunnel_name=$candidate_name
        break
    fi
done

if [ -z "$tunnel_name" ]; then
    printf '未找到与代理 alias 对应的隧道：%s\n' "$proxy_alias" >&2
    exit 65
fi

local_proxy_host=$(codex_config_get "$config_path" LOCAL_PROXY_HOST)
local_proxy_port=$(codex_config_get "$config_path" LOCAL_PROXY_PORT)
proxy_wait_seconds=$(codex_config_get "$config_path" PROXY_WAIT_SECONDS)
log_component="${tunnel_name}-tunnel"

if [ ! -x /usr/bin/ssh ]; then
    codex_log "$log_component" "未找到 /usr/bin/ssh，无法启动 $proxy_alias" || true
    exit 127
fi

codex_log "$log_component" "隧道 runner 启动：proxy-alias=$proxy_alias，local-proxy=$local_proxy_host:$local_proxy_port" || true

deadline=$(( $(date +%s) + proxy_wait_seconds ))
while :; do
    if codex_tcp_ready "$local_proxy_host" "$local_proxy_port"; then
        break
    fi

    now=$(date +%s)
    if [ "$now" -ge "$deadline" ]; then
        codex_log "$log_component" "Clash 未在 ${proxy_wait_seconds}s 内监听 $local_proxy_host:$local_proxy_port，稍后由控制器重试" || true
        exit 2
    fi
    sleep 2
done

codex_log "$log_component" "Clash 已就绪，启动 ssh -N -T $proxy_alias" || true

# RemoteForward 必须由用户 SSH 配置中的 proxy alias 提供；这里不把真实
# 主机、用户名或远端地址写入仓库，也不覆盖用户的 SSH 主机校验设置。
exec /usr/bin/ssh \
    -N \
    -T \
    -o BatchMode=yes \
    -o ConnectTimeout=15 \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    "$proxy_alias"
