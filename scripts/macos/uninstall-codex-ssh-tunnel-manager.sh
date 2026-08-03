#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s [--config 配置文件] [--install-root 目录] [--remove-installed-files]\n' "$0" >&2
}

install_root=$(codex_default_install_root)
config_path="$install_root/tunnels.macos.conf"
remove_installed_files=0
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
        --remove-installed-files)
            remove_installed_files=1
            shift
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
        printf '拒绝操作包含父目录跳转的安装路径：%s\n' "$install_root" >&2
        exit 65
        ;;
    "$HOME/Library/Application Support/Codex"/*)
        ;;
    *)
        printf '拒绝操作安装目录（必须位于用户的 Codex Application Support 目录）：%s\n' "$install_root" >&2
        exit 65
        ;;
esac

codex_config_validate "$config_path"

controller_label=$(codex_config_get "$config_path" CONTROLLER_LABEL)
tunnel_label_prefix=$(codex_config_get "$config_path" TUNNEL_LABEL_PREFIX)
launch_agents_root="$HOME/Library/LaunchAgents"
runner_path="$install_root/codex-ssh-tunnel-runner.sh"
controller_path="$install_root/codex-ssh-tunnel-controller.sh"
controller_marker_alias=
for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
    controller_marker_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" DEV_ALIAS)
    break
done

bootout_label() {
    bootout_label_value=$1
    /bin/launchctl bootout "$(codex_launchd_target "$bootout_label_value")" >/dev/null 2>&1 || true
}

stop_pid_safely() {
    stop_pid=$1
    stop_alias=$2
    if ! codex_pid_alive "$stop_pid"; then
        return 0
    fi
    if ! codex_stop_validated_pid "$stop_pid" "$stop_alias" tunnel "$runner_path"; then
        printf '跳过不符合配置的 PID：%s (%s)\n' "$stop_pid" "$stop_alias" >&2
        return 1
    fi
}

stop_controller_pid() {
    stop_controller_value=$1
    if ! codex_pid_alive "$stop_controller_value"; then
        return 0
    fi
    if ! codex_stop_validated_pid "$stop_controller_value" "$controller_marker_alias" controller "$controller_path"; then
        printf '拒绝终止不符合配置的 controller PID：%s\n' "$stop_controller_value" >&2
        return 1
    fi
}

printf '停止并卸载本项目的 launchd 任务……\n'
controller_pid=$(codex_launchd_job_pid "$controller_label")
if [ -n "$controller_pid" ]; then
    stop_controller_pid "$controller_pid"
    if codex_pid_alive "$controller_pid"; then
        printf 'controller PID 仍然存活，拒绝继续 bootout：%s\n' "$controller_pid" >&2
        exit 1
    fi
fi
bootout_label "$controller_label"
for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
    tunnel_proxy_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" PROXY_ALIAS)
    tunnel_label=$(codex_tunnel_label "$tunnel_label_prefix" "$tunnel_name")
    tunnel_job_pid=$(codex_launchd_job_pid "$tunnel_label")
    if [ -n "$tunnel_job_pid" ]; then
        stop_pid_safely "$tunnel_job_pid" "$tunnel_proxy_alias"
    fi
    for tunnel_pid in $(codex_find_tunnel_pids "$tunnel_proxy_alias"); do
        stop_pid_safely "$tunnel_pid" "$tunnel_proxy_alias"
    done
    if [ -n "$tunnel_job_pid" ] && codex_pid_alive "$tunnel_job_pid"; then
        printf '隧道 PID 仍然存活，拒绝继续 bootout：%s\n' "$tunnel_job_pid" >&2
        exit 1
    fi
    bootout_label "$tunnel_label"
    rm -f "$launch_agents_root/$tunnel_label.plist"
done
rm -f "$launch_agents_root/$controller_label.plist"

if [ "$remove_installed_files" -eq 1 ]; then
    for installed_file in \
        codex-ssh-tunnel-common.sh \
        codex-ssh-tunnel-runner.sh \
        codex-ssh-tunnel-controller.sh \
        get-codex-ssh-tunnel-status.sh \
        uninstall-codex-ssh-tunnel-manager.sh \
        inspect-codex-ssh-sessions.sh \
        tunnels.macos.conf; do
        rm -f "$install_root/$installed_file"
    done
    rmdir "$install_root" 2>/dev/null || true
fi

printf 'macOS launchd 任务已停止并卸载。运行日志和状态文件未删除。\n'
