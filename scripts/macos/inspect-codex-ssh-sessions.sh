#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s [--config 配置文件]\n' "$0" >&2
}

config_path=$(codex_default_install_root)/tunnels.macos.conf
while [ "$#" -gt 0 ]; do
    case "$1" in
        --config)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            config_path=$2
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

codex_config_validate "$config_path"

printf '以下命令行来自当前用户可见的 ssh 进程；不要把未脱敏输出提交到仓库。\n'
found=0
for pid in $(codex_ssh_pids); do
    found=1
    executable=$(codex_pid_executable "$pid")
    command_line=$(codex_pid_command "$pid")
    matches=
    for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
        dev_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" DEV_ALIAS)
        client=
        if codex_pid_matches_session "$pid" "$dev_alias"; then
            client=codex
        elif codex_pid_matches_cursor_session "$pid" "$dev_alias"; then
            client=cursor
        fi
        if [ -n "$client" ]; then
            if [ -n "$matches" ]; then
                matches="$matches,$tunnel_name:$client"
            else
                matches="$tunnel_name:$client"
            fi
        fi
    done
    if [ -z "$matches" ]; then
        matches=-
    fi
    printf 'PID=%s EXEC=%s MATCHES=%s COMMAND=%s\n' "$pid" "$executable" "$matches" "$command_line"
done

if [ "$found" -eq 0 ]; then
    printf '当前没有名称为 ssh 的进程。\n'
fi
