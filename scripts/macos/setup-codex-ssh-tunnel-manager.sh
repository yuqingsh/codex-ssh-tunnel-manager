#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
# shellcheck source=scripts/macos/codex-ssh-tunnel-common.sh
. "$script_dir/codex-ssh-tunnel-common.sh"

usage() {
    printf '%s\n' \
        "用法：$0 [选项]" \
        '' \
        '交互式生成 macOS 本机配置，可选生成受本项目管理的 SSH alias，并安装 launchd 控制器。' \
        '' \
        '选项：' \
        '  --ssh-mode generate|existing 生成 SSH alias，或复用已有 alias（默认交互选择）' \
        '  --config-output 文件          保存本机配置的位置' \
        '  --no-install                  只生成并校验配置，不加载 launchd' \
        '  --skip-remote-check           不执行只读 SSH 登录和 Linux wrapper 检查' \
        '  -h, --help                    显示帮助'
}

prompt_default() {
    setup_prompt_text=$1
    setup_prompt_default=$2
    if [ -n "$setup_prompt_default" ]; then
        printf '%s [%s]: ' "$setup_prompt_text" "$setup_prompt_default" >&2
    else
        printf '%s: ' "$setup_prompt_text" >&2
    fi
    setup_prompt_value=
    IFS= read -r setup_prompt_value || true
    if [ -z "$setup_prompt_value" ]; then
        setup_prompt_value=$setup_prompt_default
    fi
    printf '%s\n' "$setup_prompt_value"
}

prompt_required() {
    setup_prompt_required_text=$1
    while :; do
        setup_prompt_required_value=$(prompt_default "$setup_prompt_required_text" '')
        if [ -n "$setup_prompt_required_value" ]; then
            printf '%s\n' "$setup_prompt_required_value"
            return 0
        fi
        printf '此项不能为空。\n' >&2
    done
}

prompt_yes_no() {
    setup_prompt_yes_no_text=$1
    setup_prompt_yes_no_default=$2
    while :; do
        case "$setup_prompt_yes_no_default" in
            y) setup_prompt_yes_no_hint='Y/n' ;;
            *) setup_prompt_yes_no_hint='y/N' ;;
        esac
        printf '%s [%s]: ' "$setup_prompt_yes_no_text" "$setup_prompt_yes_no_hint" >&2
        setup_prompt_yes_no_value=
        IFS= read -r setup_prompt_yes_no_value || true
        if [ -z "$setup_prompt_yes_no_value" ]; then
            setup_prompt_yes_no_value=$setup_prompt_yes_no_default
        fi
        case "$setup_prompt_yes_no_value" in
            y|Y|yes|YES|Yes)
                printf 'yes\n'
                return 0
                ;;
            n|N|no|NO|No)
                printf 'no\n'
                return 0
                ;;
            *)
                printf '请输入 y 或 n。\n' >&2
                ;;
        esac
    done
}

validate_tunnel_names() {
    setup_validate_names_value=$1
    (
        set -f
        IFS=,
        set -- $setup_validate_names_value
        [ "$#" -gt 0 ] || exit 1
        setup_validate_seen_names=,
        for setup_validate_name in "$@"; do
            case "$setup_validate_name" in
                ''|*[!A-Za-z0-9_]*)
                    exit 1
                    ;;
            esac
            case "$setup_validate_seen_names" in
                *",$setup_validate_name,"*)
                    exit 1
                    ;;
            esac
            setup_validate_seen_names=$setup_validate_seen_names$setup_validate_name,
        done
    )
}

validate_simple_value() {
    case "$1" in
        ''|*[!A-Za-z0-9._:-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

validate_user_value() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

validate_identity_path() {
    case "$1" in
        ''|*[!A-Za-z0-9._/~:-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

detect_proxy_port() {
    setup_detected_proxy_ports=
    if [ -x /usr/bin/nc ]; then
        for setup_candidate_port in 7897 33331; do
            if /usr/bin/nc -z -w 1 127.0.0.1 "$setup_candidate_port" >/dev/null 2>&1; then
                setup_detected_proxy_ports=$setup_detected_proxy_ports$setup_candidate_port,
            fi
        done
    fi

    case "$setup_detected_proxy_ports" in
        7897,|33331,)
            printf '%s\n' "$setup_detected_proxy_ports" | sed 's/,$//'
            ;;
        7897,33331,|33331,7897,)
            printf '同时检测到 127.0.0.1:7897 和 127.0.0.1:33331。\n' >&2
            prompt_default '选择 Clash HTTP/mixed 端口' 7897
            ;;
        *)
            printf '未检测到默认 Clash 端口 7897/33331。控制器可以稍后重试，但现在需要指定端口。\n' >&2
            prompt_default 'Clash HTTP/mixed 端口' 7897
            ;;
    esac
}

validate_port_input() {
    codex_validate_integer "$1" 1 65535
}

setup_ssh() {
    if [ -f "$HOME/.ssh/config" ]; then
        /usr/bin/ssh -F "$HOME/.ssh/config" "$@"
    else
        /usr/bin/ssh "$@"
    fi
}

ssh_config_values() {
    setup_ssh_values_alias=$1
    setup_ssh_values_output=$2
    setup_ssh_values_expected_remote=$3
    setup_ssh_values_expected_local=$4

    if ! setup_ssh_values_dump=$(setup_ssh -G "$setup_ssh_values_alias" 2>/dev/null); then
        printf 'SSH alias 无法解析：%s\n' "$setup_ssh_values_alias" >&2
        return 1
    fi
    setup_ssh_values_hostname=$(printf '%s\n' "$setup_ssh_values_dump" | awk '$1 == "hostname" { print $2; exit }')
    if [ -z "$setup_ssh_values_hostname" ]; then
        printf 'SSH alias 没有解析出 hostname：%s\n' "$setup_ssh_values_alias" >&2
        return 1
    fi
    if [ -n "$setup_ssh_values_expected_remote" ]; then
        if ! printf '%s\n' "$setup_ssh_values_dump" | awk \
            -v expected_remote="$setup_ssh_values_expected_remote" \
            -v expected_local="$setup_ssh_values_expected_local" \
            '$1 == "remoteforward" {
                remote = $2
                local = $3
                gsub(/^\[/, "", remote)
                gsub(/^\[/, "", local)
                gsub(/\]:/, ":", remote)
                gsub(/\]:/, ":", local)
                if (remote == expected_remote && local == expected_local) { found = 1 }
            }
            END { exit !found }'; then
            printf 'SSH alias %s 没有精确的 RemoteForward：远端 %s，本机 %s。\n' \
                "$setup_ssh_values_alias" "$setup_ssh_values_expected_remote" "$setup_ssh_values_expected_local" >&2
            return 1
        fi
    fi
    printf '%s\n' "$setup_ssh_values_dump" > "$setup_ssh_values_output"
}

check_alias_pair() {
    setup_check_dev_alias=$1
    setup_check_proxy_alias=$2
    setup_check_remote_port=$3
    setup_check_local_port=$4
    setup_check_dump="$setup_tmp/$setup_check_dev_alias.ssh-g.txt"
    setup_check_proxy_dump="$setup_tmp/$setup_check_proxy_alias.ssh-g.txt"
    ssh_config_values "$setup_check_dev_alias" "$setup_check_dump" '' ''
    ssh_config_values "$setup_check_proxy_alias" "$setup_check_proxy_dump" \
        "127.0.0.1:$setup_check_remote_port" "127.0.0.1:$setup_check_local_port"
}

backup_path() {
    setup_backup_dir=$1
    setup_backup_prefix=$2
    mkdir -p "$setup_backup_dir"
    chmod 700 "$setup_backup_dir" 2>/dev/null || true
    setup_backup_stamp=$(date -u '+%Y%m%d-%H%M%SZ')
    setup_backup_candidate=$setup_backup_dir/$setup_backup_prefix-$setup_backup_stamp.bak
    setup_backup_index=1
    while [ -e "$setup_backup_candidate" ]; do
        setup_backup_candidate=$setup_backup_dir/$setup_backup_prefix-$setup_backup_stamp-$setup_backup_index.bak
        setup_backup_index=$((setup_backup_index + 1))
    done
    printf '%s\n' "$setup_backup_candidate"
}

write_managed_ssh_config() {
    setup_managed_ssh_dir=$HOME/.ssh
    setup_managed_ssh_file=$setup_managed_ssh_dir/codex-ssh-tunnel-manager.conf
    setup_main_ssh_file=$setup_managed_ssh_dir/config
    setup_include_line="Include $setup_managed_ssh_file"
    setup_ssh_staged_file="$setup_tmp/codex-ssh-tunnel-manager.ssh.conf"

    mkdir -p "$setup_managed_ssh_dir"
    chmod 700 "$setup_managed_ssh_dir" 2>/dev/null || true

    if [ -e "$setup_managed_ssh_file" ] && ! grep -F '# BEGIN CODEX SSH TUNNEL MANAGER' "$setup_managed_ssh_file" >/dev/null 2>&1; then
        printf '拒绝覆盖未由本项目管理的 SSH 文件：%s\n' "$setup_managed_ssh_file" >&2
        return 1
    fi

    : > "$setup_ssh_staged_file"
    chmod 600 "$setup_ssh_staged_file"
    printf '%s\n' \
        '# This file is managed by Codex SSH Tunnel Manager.' \
        '# BEGIN CODEX SSH TUNNEL MANAGER' >> "$setup_ssh_staged_file"

    while IFS='|' read -r setup_ssh_name setup_ssh_dev_alias setup_ssh_proxy_alias setup_ssh_host setup_ssh_user setup_ssh_port setup_ssh_identity; do
        printf '%s\n' \
            "Host $setup_ssh_dev_alias" \
            "    HostName $setup_ssh_host" \
            "    User $setup_ssh_user" \
            "    Port $setup_ssh_port" \
            "    IdentityFile $setup_ssh_identity" \
            '    IdentitiesOnly yes' \
            '    ServerAliveInterval 30' \
            '    ServerAliveCountMax 3' \
            '' \
            "Host $setup_ssh_proxy_alias" \
            "    HostName $setup_ssh_host" \
            "    User $setup_ssh_user" \
            "    Port $setup_ssh_port" \
            "    IdentityFile $setup_ssh_identity" \
            '    IdentitiesOnly yes' \
            "    RemoteForward 127.0.0.1:$setup_remote_proxy_port 127.0.0.1:$setup_local_proxy_port" \
            '    ExitOnForwardFailure yes' \
            '    ServerAliveInterval 30' \
            '    ServerAliveCountMax 3' \
            '' >> "$setup_ssh_staged_file"
    done < "$setup_answers_file"

    printf '%s\n' '# END CODEX SSH TUNNEL MANAGER' >> "$setup_ssh_staged_file"

    if [ -e "$setup_managed_ssh_file" ]; then
        setup_ssh_backup=$(backup_path "$setup_managed_ssh_dir/backups" codex-ssh-tunnel-manager)
        cp "$setup_managed_ssh_file" "$setup_ssh_backup"
        chmod 600 "$setup_ssh_backup"
    fi
    cp "$setup_ssh_staged_file" "$setup_managed_ssh_file"
    chmod 600 "$setup_managed_ssh_file"

    if [ ! -e "$setup_main_ssh_file" ]; then
        : > "$setup_main_ssh_file"
        chmod 600 "$setup_main_ssh_file"
    elif ! grep -Fqx "$setup_include_line" "$setup_main_ssh_file"; then
        setup_main_ssh_backup=$(backup_path "$setup_managed_ssh_dir/backups" ssh-config)
        cp "$setup_main_ssh_file" "$setup_main_ssh_backup"
        chmod 600 "$setup_main_ssh_backup"
        setup_main_ssh_staged="$setup_tmp/ssh-config.updated"
        {
            printf '%s\n\n' "$setup_include_line"
            cat "$setup_main_ssh_file"
        } > "$setup_main_ssh_staged"
        cp "$setup_main_ssh_staged" "$setup_main_ssh_file"
        chmod 600 "$setup_main_ssh_file"
    fi

    if ! grep -Fqx "$setup_include_line" "$setup_main_ssh_file"; then
        printf '\n# Codex SSH Tunnel Manager managed include.\n%s\n' "$setup_include_line" >> "$setup_main_ssh_file"
    fi
    chmod 600 "$setup_main_ssh_file"

    printf '已写入受本项目管理的 SSH 配置：%s\n' "$setup_managed_ssh_file"
    printf '已确保 ~/.ssh/config 包含该文件。\n'
}

check_remote_wrapper() {
    setup_wrapper_alias=$1
    if setup_ssh -o BatchMode=yes -o ConnectTimeout=8 "$setup_wrapper_alias" \
        'test -x "$HOME/.local/bin/codex" && test -e "$HOME/.local/bin/codex.direct" && grep -q CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1 "$HOME/.local/bin/codex"' \
        >/dev/null 2>&1; then
        printf 'Linux wrapper 检查通过：%s\n' "$setup_wrapper_alias"
        return 0
    fi
    printf 'Linux wrapper 检查未通过：%s（脚本不会自动修改远端）\n' "$setup_wrapper_alias" >&2
    return 1
}

setup_ssh_mode=
config_output="$repository_root/config/tunnels.macos.conf"
skip_remote_check=0
no_install=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --ssh-mode)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            case "$2" in
                generate|existing) setup_ssh_mode=$2 ;;
                *) usage >&2; exit 64 ;;
            esac
            shift 2
            ;;
        --config-output)
            [ "$#" -ge 2 ] || { usage >&2; exit 64; }
            config_output=$2
            shift 2
            ;;
        --no-install)
            no_install=1
            shift
            ;;
        --skip-remote-check)
            skip_remote_check=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 64
            ;;
    esac
done

setup_tmp_parent=$(printenv TMPDIR 2>/dev/null || true)
if [ -z "$setup_tmp_parent" ]; then
    setup_tmp_parent=/tmp
fi
setup_tmp=$(mktemp -d "$setup_tmp_parent/codex-ssh-tunnel-setup.XXXXXX")
trap 'rm -rf "$setup_tmp"' EXIT HUP INT TERM
setup_answers_file="$setup_tmp/answers.txt"
: > "$setup_answers_file"
chmod 600 "$setup_answers_file"

if [ -z "$setup_ssh_mode" ]; then
    setup_ssh_mode_choice=$(prompt_default 'SSH 配置方式（generate=生成独立 alias，existing=复用已有 alias）' generate)
    case "$setup_ssh_mode_choice" in
        generate|existing) setup_ssh_mode=$setup_ssh_mode_choice ;;
        *)
            printf 'SSH 配置方式必须是 generate 或 existing。\n' >&2
            exit 64
            ;;
    esac
fi

setup_tunnel_names=$(prompt_default '需要配置的隧道名称（多个名称用逗号分隔）' primary)
if ! validate_tunnel_names "$setup_tunnel_names"; then
    printf '隧道名称无效，只允许字母、数字和下划线，且不能重复：%s\n' "$setup_tunnel_names" >&2
    exit 65
fi

setup_local_proxy_port=$(detect_proxy_port)
if ! validate_port_input "$setup_local_proxy_port"; then
    printf 'Clash 端口无效：%s\n' "$setup_local_proxy_port" >&2
    exit 65
fi
setup_remote_proxy_port=$(prompt_default 'Linux 端反向代理端口' 17897)
if ! validate_port_input "$setup_remote_proxy_port"; then
    printf 'Linux 反向代理端口无效：%s\n' "$setup_remote_proxy_port" >&2
    exit 65
fi

for setup_tunnel_name in $(printf '%s\n' "$setup_tunnel_names" | tr ',' ' '); do
    setup_default_dev_alias=$(printf '%s-dev' "$setup_tunnel_name")
    setup_default_proxy_alias=$(printf '%s-proxy' "$setup_tunnel_name")
    setup_dev_alias=$(prompt_default "$setup_tunnel_name 的 Codex 开发 SSH alias" "$setup_default_dev_alias")
    setup_proxy_alias=$(prompt_default "$setup_tunnel_name 的反向隧道 SSH alias" "$setup_default_proxy_alias")
    if ! codex_validate_alias "$setup_dev_alias" || ! codex_validate_alias "$setup_proxy_alias"; then
        printf 'SSH alias 无效：%s / %s\n' "$setup_dev_alias" "$setup_proxy_alias" >&2
        exit 65
    fi
    if [ "$setup_dev_alias" = "$setup_proxy_alias" ]; then
        printf '开发 alias 和代理 alias 不能相同：%s\n' "$setup_dev_alias" >&2
        exit 65
    fi

    case "$setup_ssh_mode" in
        generate)
            setup_host=$(prompt_required "$setup_tunnel_name 的 Linux 主机名或地址")
            setup_user=$(prompt_required "$setup_tunnel_name 的 Linux 用户名")
            setup_ssh_port=$(prompt_default "$setup_tunnel_name 的 SSH 端口" 22)
            setup_identity=$(prompt_default "$setup_tunnel_name 的 IdentityFile" '~/.ssh/id_ed25519')
            if ! validate_simple_value "$setup_host" || ! validate_user_value "$setup_user" || \
                ! validate_port_input "$setup_ssh_port" || ! validate_identity_path "$setup_identity"; then
                printf 'SSH 主机、用户名、端口或 IdentityFile 含有不支持的字符。\n' >&2
                exit 65
            fi
            printf '%s|%s|%s|%s|%s|%s|%s\n' \
                "$setup_tunnel_name" "$setup_dev_alias" "$setup_proxy_alias" "$setup_host" \
                "$setup_user" "$setup_ssh_port" "$setup_identity" >> "$setup_answers_file"
            ;;
        existing)
            printf '%s|%s|%s||||\n' "$setup_tunnel_name" "$setup_dev_alias" "$setup_proxy_alias" >> "$setup_answers_file"
            ;;
    esac
done

if [ "$setup_ssh_mode" = generate ]; then
    setup_write_ssh_answer=$(prompt_yes_no '是否写入受本项目管理的 ~/.ssh SSH alias 配置？' y)
    if [ "$setup_write_ssh_answer" != yes ]; then
        printf '未写入 SSH 配置。请改用 --ssh-mode existing 并手动准备 alias，或重新运行向导。\n' >&2
        exit 1
    fi
fi

if [ -e "$config_output" ]; then
    setup_overwrite_answer=$(prompt_yes_no "配置已存在，是否覆盖 $config_output？" n)
    if [ "$setup_overwrite_answer" != yes ]; then
        printf '已取消，未覆盖现有配置。\n' >&2
        exit 1
    fi
fi

setup_config_staged="$setup_tmp/tunnels.macos.conf"
{
    printf '%s\n' \
        '# Generated by setup-codex-ssh-tunnel-manager.sh.' \
        '# This file contains machine-local SSH aliases and must not be committed.' \
        '' \
        'SCHEMA_VERSION=1' \
        'POLL_SECONDS=5' \
        'STOP_GRACE_MINUTES=10' \
        'PROXY_WAIT_SECONDS=120' \
        'LOCAL_PROXY_HOST=127.0.0.1' \
        "LOCAL_PROXY_PORT=$setup_local_proxy_port" \
        'REMOTE_PROXY_HOST=127.0.0.1' \
        "REMOTE_PROXY_PORT=$setup_remote_proxy_port" \
        'CONTROLLER_LABEL=com.codex.ssh-tunnel-manager.controller' \
        'TUNNEL_LABEL_PREFIX=com.codex.ssh-tunnel-manager.tunnel' \
        "TUNNEL_NAMES=$setup_tunnel_names" \
        ''
    while IFS='|' read -r setup_config_name setup_config_dev_alias setup_config_proxy_alias setup_config_host setup_config_user setup_config_port setup_config_identity; do
        setup_config_upper_name=$(printf '%s' "$setup_config_name" | tr '[:lower:]' '[:upper:]')
        printf '%s\n' \
            "TUNNEL_"$setup_config_upper_name"_DEV_ALIAS=$setup_config_dev_alias" \
            "TUNNEL_"$setup_config_upper_name"_PROXY_ALIAS=$setup_config_proxy_alias" \
            ''
    done < "$setup_answers_file"
} > "$setup_config_staged"

mkdir -p "$(dirname -- "$config_output")"
cp "$setup_config_staged" "$config_output"
chmod 600 "$config_output"
codex_config_validate "$config_output"

if [ "$setup_ssh_mode" = generate ]; then
    write_managed_ssh_config
fi

for setup_check_name in $(codex_config_tunnel_names "$config_output"); do
    setup_check_dev_alias=$(codex_tunnel_config_get "$config_output" "$setup_check_name" DEV_ALIAS)
    setup_check_proxy_alias=$(codex_tunnel_config_get "$config_output" "$setup_check_name" PROXY_ALIAS)
    if ! check_alias_pair "$setup_check_dev_alias" "$setup_check_proxy_alias" "$setup_remote_proxy_port" "$setup_local_proxy_port"; then
        printf 'SSH alias 校验失败，请修正 SSH 配置后重新运行。\n' >&2
        exit 1
    fi
done
printf 'SSH alias 和 RemoteForward 校验通过。\n'

if [ -x /usr/bin/nc ] && ! /usr/bin/nc -z -w 2 127.0.0.1 "$setup_local_proxy_port" >/dev/null 2>&1; then
    printf '警告：Clash 当前未监听 127.0.0.1:%s；控制器安装后会等待并重试。\n' "$setup_local_proxy_port" >&2
else
    printf 'Clash 本地端口可达：127.0.0.1:%s\n' "$setup_local_proxy_port"
fi

if [ "$skip_remote_check" -eq 0 ]; then
    setup_remote_failures=0
    for setup_remote_name in $(codex_config_tunnel_names "$config_output"); do
        setup_remote_dev_alias=$(codex_tunnel_config_get "$config_output" "$setup_remote_name" DEV_ALIAS)
        if ! setup_ssh -o BatchMode=yes -o ConnectTimeout=8 "$setup_remote_dev_alias" hostname >/dev/null 2>&1; then
            printf '只读 SSH 登录检查失败：%s\n' "$setup_remote_dev_alias" >&2
            setup_remote_failures=$((setup_remote_failures + 1))
        elif ! check_remote_wrapper "$setup_remote_dev_alias"; then
            setup_remote_failures=$((setup_remote_failures + 1))
        fi
    done
    if [ "$setup_remote_failures" -gt 0 ]; then
        printf '远端检查有失败项。脚本没有修改 Linux；控制器仍可安装，修复 SSH 或 wrapper 后会自动恢复。\n' >&2
    fi
else
    printf '已跳过只读 SSH 登录和 Linux wrapper 检查。\n'
fi

if [ "$no_install" -eq 1 ]; then
    printf '配置已生成：%s\n' "$config_output"
    printf '未安装 launchd；稍后可运行 install-codex-ssh-tunnel-manager.sh。\n'
    exit 0
fi

"$script_dir/install-codex-ssh-tunnel-manager.sh" --config "$config_output"
printf '一键初始化完成。打开 Codex App 的远程项目后，控制器会按需建立反向隧道。\n'
printf '配置文件：%s\n' "$config_output"
