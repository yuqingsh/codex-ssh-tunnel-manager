#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '用法：%s --config 配置文件 [--install-root 目录] [--render-only 临时目录]\n' "$0" >&2
}

config_path=
install_root=$(codex_default_install_root)
render_root=
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
        --render-only)
            [ "$#" -ge 2 ] || { usage; exit 64; }
            render_root=$2
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
    config_path="$script_dir/../../config/tunnels.macos.conf"
fi

if [ -n "$render_root" ]; then
    install_root="$render_root/install"
else
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
fi

codex_config_validate "$config_path"

for required_executable in /bin/launchctl /usr/bin/plutil /usr/bin/ssh; do
    if [ ! -x "$required_executable" ]; then
        printf 'macOS 系统工具不存在：%s\n' "$required_executable" >&2
        exit 1
    fi
done

controller_label=$(codex_config_get "$config_path" CONTROLLER_LABEL)
tunnel_label_prefix=$(codex_config_get "$config_path" TUNNEL_LABEL_PREFIX)
controller_marker_alias=
for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
    controller_marker_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" DEV_ALIAS)
    break
done
if [ -n "$render_root" ]; then
    launch_agents_root="$render_root/LaunchAgents"
    log_root="$render_root/Logs"
    state_root="$render_root/State"
else
    launch_agents_root="$HOME/Library/LaunchAgents"
    log_root=$(codex_default_log_root)
    state_root=$(codex_default_state_root)
fi
domain=$(codex_launchd_domain)

mkdir -p "$install_root" "$launch_agents_root" "$log_root" "$state_root"
chmod 700 "$install_root" "$log_root" "$state_root" 2>/dev/null || true

runner_path="$install_root/codex-ssh-tunnel-runner.sh"
controller_path="$install_root/codex-ssh-tunnel-controller.sh"
installed_config_path="$install_root/tunnels.macos.conf"

write_controller_plist() {
    plist_path=$1
    plist_label=$(codex_xml_escape "$controller_label")
    plist_controller=$(codex_xml_escape "$controller_path")
    plist_config=$(codex_xml_escape "$installed_config_path")
    plist_marker_alias=$(codex_xml_escape "$controller_marker_alias")
    plist_install_root=$(codex_xml_escape "$install_root")
    plist_stdout=$(codex_xml_escape "$log_root/controller.stdout.log")
    plist_stderr=$(codex_xml_escape "$log_root/controller.stderr.log")

    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0">' \
        '<dict>' \
        '<key>Label</key>' "<string>$plist_label</string>" \
        '<key>ProgramArguments</key>' \
        '<array>' \
        '<string>/bin/sh</string>' \
        "<string>$plist_controller</string>" \
        '<string>--config</string>' \
        "<string>$plist_config</string>" \
        '<string>--controller-marker-alias</string>' \
        "<string>$plist_marker_alias</string>" \
        '</array>' \
        '<key>RunAtLoad</key>' \
        '<true/>' \
        '<key>KeepAlive</key>' \
        '<true/>' \
        '<key>ThrottleInterval</key>' \
        '<integer>5</integer>' \
        '<key>ProcessType</key>' \
        '<string>Background</string>' \
        '<key>StandardOutPath</key>' \
        "<string>$plist_stdout</string>" \
        '<key>StandardErrorPath</key>' \
        "<string>$plist_stderr</string>" \
        '<key>EnvironmentVariables</key>' \
        '<dict>' \
        '<key>PATH</key>' \
        '<string>/usr/bin:/bin:/usr/sbin:/sbin</string>' \
        '<key>CODEX_SSH_TUNNEL_INSTALL_ROOT</key>' \
        "<string>$plist_install_root</string>" \
        '</dict>' \
        '</dict>' \
        '</plist>' > "$plist_path"
}

write_tunnel_plist() {
    plist_name=$1
    plist_proxy_alias=$2
    plist_path=$3
    plist_label=$(codex_xml_escape "$(codex_tunnel_label "$tunnel_label_prefix" "$plist_name")")
    plist_runner=$(codex_xml_escape "$runner_path")
    plist_config=$(codex_xml_escape "$installed_config_path")
    plist_proxy=$(codex_xml_escape "$plist_proxy_alias")
    plist_install_root=$(codex_xml_escape "$install_root")
    plist_stdout=$(codex_xml_escape "$log_root/$plist_name-tunnel.stdout.log")
    plist_stderr=$(codex_xml_escape "$log_root/$plist_name-tunnel.stderr.log")

    printf '%s\n' \
        '<?xml version="1.0" encoding="UTF-8"?>' \
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
        '<plist version="1.0">' \
        '<dict>' \
        '<key>Label</key>' "<string>$plist_label</string>" \
        '<key>ProgramArguments</key>' \
        '<array>' \
        '<string>/bin/sh</string>' \
        "<string>$plist_runner</string>" \
        '<string>--config</string>' \
        "<string>$plist_config</string>" \
        '<string>--proxy-alias</string>' \
        "<string>$plist_proxy</string>" \
        '</array>' \
        '<key>RunAtLoad</key>' \
        '<false/>' \
        '<key>KeepAlive</key>' \
        '<false/>' \
        '<key>ThrottleInterval</key>' \
        '<integer>5</integer>' \
        '<key>ProcessType</key>' \
        '<string>Background</string>' \
        '<key>StandardOutPath</key>' \
        "<string>$plist_stdout</string>" \
        '<key>StandardErrorPath</key>' \
        "<string>$plist_stderr</string>" \
        '<key>EnvironmentVariables</key>' \
        '<dict>' \
        '<key>PATH</key>' \
        '<string>/usr/bin:/bin:/usr/sbin:/sbin</string>' \
        '<key>CODEX_SSH_TUNNEL_INSTALL_ROOT</key>' \
        "<string>$plist_install_root</string>" \
        '</dict>' \
        '</dict>' \
        '</plist>' > "$plist_path"
}

bootout_label() {
    bootout_label_value=$1
    /bin/launchctl bootout "$(codex_launchd_target "$bootout_label_value")" >/dev/null 2>&1 || true
}

stop_existing_pid() {
    existing_pid=$1
    existing_alias=$2
    if ! codex_pid_alive "$existing_pid"; then
        return 0
    fi
    if ! codex_stop_validated_pid "$existing_pid" "$existing_alias" tunnel "$runner_path"; then
        printf '跳过不符合配置的 PID：%s (%s)\n' "$existing_pid" "$existing_alias" >&2
        return 1
    fi
}

stop_controller_pid() {
    existing_controller_pid=$1
    if ! codex_pid_alive "$existing_controller_pid"; then
        return 0
    fi
    if ! codex_stop_validated_pid "$existing_controller_pid" "$controller_marker_alias" controller "$controller_path"; then
        printf '拒绝终止不符合配置的 controller PID：%s\n' "$existing_controller_pid" >&2
        return 1
    fi
}

if [ -z "$render_root" ]; then
    printf '停止已加载的本项目 launchd 任务……\n'

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
            stop_existing_pid "$tunnel_job_pid" "$tunnel_proxy_alias"
        fi
        for existing_pid in $(codex_find_tunnel_pids "$tunnel_proxy_alias"); do
            stop_existing_pid "$existing_pid" "$tunnel_proxy_alias"
        done
        if [ -n "$tunnel_job_pid" ] && codex_pid_alive "$tunnel_job_pid"; then
            printf '隧道 PID 仍然存活，拒绝继续 bootout：%s\n' "$tunnel_job_pid" >&2
            exit 1
        fi
        bootout_label "$tunnel_label"
    done
fi

for file_name in \
    codex-ssh-tunnel-common.sh \
    codex-ssh-tunnel-runner.sh \
    codex-ssh-tunnel-controller.sh \
    get-codex-ssh-tunnel-status.sh \
    uninstall-codex-ssh-tunnel-manager.sh \
    inspect-codex-ssh-sessions.sh; do
    cp "$script_dir/$file_name" "$install_root/$file_name"
    chmod 755 "$install_root/$file_name"
done
cp "$config_path" "$installed_config_path"
chmod 600 "$installed_config_path"

controller_plist="$launch_agents_root/$controller_label.plist"
write_controller_plist "$controller_plist"
/usr/bin/plutil -lint "$controller_plist" >/dev/null

for tunnel_name in $(codex_config_tunnel_names "$config_path"); do
    tunnel_proxy_alias=$(codex_tunnel_config_get "$config_path" "$tunnel_name" PROXY_ALIAS)
    tunnel_label=$(codex_tunnel_label "$tunnel_label_prefix" "$tunnel_name")
    tunnel_plist="$launch_agents_root/$tunnel_label.plist"
    write_tunnel_plist "$tunnel_name" "$tunnel_proxy_alias" "$tunnel_plist"
    /usr/bin/plutil -lint "$tunnel_plist" >/dev/null
    if [ -z "$render_root" ]; then
        /bin/launchctl bootstrap "$domain" "$tunnel_plist"
    fi
done

if [ -z "$render_root" ]; then
    /bin/launchctl bootstrap "$domain" "$controller_plist"
    /bin/launchctl kickstart "$domain/$controller_label"
fi

printf 'macOS Codex SSH 隧道管理器安装完成。\n'
printf '控制器 label：%s\n' "$controller_label"
printf '安装目录：%s\n' "$install_root"
printf '日志目录：%s\n' "$log_root"
printf '隧道任务没有自动启动触发器，只由控制器按需 kickstart。\n'
if [ -n "$render_root" ]; then
    printf '仅渲染模式：未加载 launchd，也未修改进程或系统状态。\n'
fi
