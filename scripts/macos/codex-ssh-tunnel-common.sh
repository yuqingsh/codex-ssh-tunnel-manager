#!/bin/sh

# Shared POSIX helpers for the macOS Codex SSH tunnel manager.
# This file is sourced by the other macOS scripts and must not be executed
# directly.

codex_config_get() {
    codex_config_get_path=$1
    codex_config_get_key=$2

    awk -v wanted="$codex_config_get_key" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            key = $0
            sub(/=.*/, "", key)
            if (key == wanted) {
                value = $0
                sub(/^[^=]*=/, "", value)
                print value
                found = 1
                exit
            }
        }
        END {
            if (!found) {
                exit 1
            }
        }
    ' "$codex_config_get_path"
}

codex_validate_integer() {
    codex_validate_integer_value=$1
    codex_validate_integer_min=$2
    codex_validate_integer_max=$3

    case "$codex_validate_integer_value" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac

    if [ "$codex_validate_integer_value" -lt "$codex_validate_integer_min" ] 2>/dev/null; then
        return 1
    fi
    if [ "$codex_validate_integer_value" -gt "$codex_validate_integer_max" ] 2>/dev/null; then
        return 1
    fi
    return 0
}

codex_validate_alias() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

codex_validate_label() {
    case "$1" in
        ''|*[!A-Za-z0-9._-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

codex_tunnel_config_get() {
    codex_tunnel_config_path=$1
    codex_tunnel_config_name=$2
    codex_tunnel_config_field=$3
    codex_tunnel_config_upper_name=$(printf '%s' "$codex_tunnel_config_name" | tr '[:lower:]' '[:upper:]')
    codex_tunnel_config_key="TUNNEL_${codex_tunnel_config_upper_name}_${codex_tunnel_config_field}"
    codex_config_get "$codex_tunnel_config_path" "$codex_tunnel_config_key"
}

codex_config_validate() {
    codex_config_validate_path=$1

    if [ ! -f "$codex_config_validate_path" ]; then
        printf '配置文件不存在：%s\n' "$codex_config_validate_path" >&2
        return 1
    fi
    if [ ! -r "$codex_config_validate_path" ]; then
        printf '配置文件不可读：%s\n' "$codex_config_validate_path" >&2
        return 1
    fi

    if ! awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        {
            if ($0 !~ /^[A-Z][A-Z0-9_]*=[^[:space:]]+$/) {
                printf "配置行格式无效：%s\n", $0 > "/dev/stderr"
                invalid = 1
                next
            }
            key = $0
            sub(/=.*/, "", key)
            if (seen[key]++) {
                printf "配置键重复：%s\n", key > "/dev/stderr"
                invalid = 1
            }
        }
        END { exit invalid }
    ' "$codex_config_validate_path"; then
        return 1
    fi

    for codex_required_key in \
        SCHEMA_VERSION \
        POLL_SECONDS \
        STOP_GRACE_MINUTES \
        PROXY_WAIT_SECONDS \
        LOCAL_PROXY_HOST \
        LOCAL_PROXY_PORT \
        REMOTE_PROXY_HOST \
        REMOTE_PROXY_PORT \
        CONTROLLER_LABEL \
        TUNNEL_LABEL_PREFIX \
        TUNNEL_NAMES; do
        codex_required_value=$(codex_config_get "$codex_config_validate_path" "$codex_required_key" 2>/dev/null) || {
            printf '缺少配置键：%s\n' "$codex_required_key" >&2
            return 1
        }
        if [ -z "$codex_required_value" ]; then
            printf '配置键不能为空：%s\n' "$codex_required_key" >&2
            return 1
        fi
    done

    codex_schema_version=$(codex_config_get "$codex_config_validate_path" SCHEMA_VERSION)
    if [ "$codex_schema_version" != '1' ]; then
        printf '不支持的配置版本：%s\n' "$codex_schema_version" >&2
        return 1
    fi

    for codex_integer_key in \
        POLL_SECONDS \
        STOP_GRACE_MINUTES \
        PROXY_WAIT_SECONDS \
        LOCAL_PROXY_PORT \
        REMOTE_PROXY_PORT; do
        case "$codex_integer_key" in
            POLL_SECONDS)
                codex_integer_min=2
                codex_integer_max=300
                ;;
            STOP_GRACE_MINUTES)
                codex_integer_min=1
                codex_integer_max=1440
                ;;
            PROXY_WAIT_SECONDS)
                codex_integer_min=1
                codex_integer_max=3600
                ;;
            LOCAL_PROXY_PORT|REMOTE_PROXY_PORT)
                codex_integer_min=1
                codex_integer_max=65535
                ;;
        esac
        codex_integer_value=$(codex_config_get "$codex_config_validate_path" "$codex_integer_key")
        if ! codex_validate_integer "$codex_integer_value" "$codex_integer_min" "$codex_integer_max"; then
            printf '配置键 %s 的取值无效：%s\n' "$codex_integer_key" "$codex_integer_value" >&2
            return 1
        fi
    done

    for codex_loopback_key in LOCAL_PROXY_HOST REMOTE_PROXY_HOST; do
        codex_loopback_value=$(codex_config_get "$codex_config_validate_path" "$codex_loopback_key")
        if [ "$codex_loopback_value" != '127.0.0.1' ]; then
            printf '%s 必须保持为 127.0.0.1：%s\n' "$codex_loopback_key" "$codex_loopback_value" >&2
            return 1
        fi
    done

    for codex_label_key in CONTROLLER_LABEL TUNNEL_LABEL_PREFIX; do
        codex_label_value=$(codex_config_get "$codex_config_validate_path" "$codex_label_key")
        if ! codex_validate_label "$codex_label_value"; then
            printf '%s 含有不支持的字符：%s\n' "$codex_label_key" "$codex_label_value" >&2
            return 1
        fi
    done

    codex_tunnel_names=$(codex_config_get "$codex_config_validate_path" TUNNEL_NAMES)
    case "$codex_tunnel_names" in
        ''|,*|*,|*,,*|*[!A-Za-z0-9_,-]*)
            printf 'TUNNEL_NAMES 格式无效：%s\n' "$codex_tunnel_names" >&2
            return 1
            ;;
    esac

    if ! (
        codex_seen_names=,
        codex_seen_aliases=,
        IFS=,
        set -- $codex_tunnel_names
        for codex_tunnel_name in "$@"; do
            case ",$codex_seen_names," in
                *",$codex_tunnel_name,"*)
                    printf '隧道名称重复：%s\n' "$codex_tunnel_name" >&2
                    exit 1
                    ;;
            esac
            codex_seen_names=$codex_seen_names$codex_tunnel_name,

            codex_dev_alias=$(codex_tunnel_config_get "$codex_config_validate_path" "$codex_tunnel_name" DEV_ALIAS 2>/dev/null) || {
                printf '缺少隧道配置：%s DEV_ALIAS\n' "$codex_tunnel_name" >&2
                exit 1
            }
            codex_proxy_alias=$(codex_tunnel_config_get "$codex_config_validate_path" "$codex_tunnel_name" PROXY_ALIAS 2>/dev/null) || {
                printf '缺少隧道配置：%s PROXY_ALIAS\n' "$codex_tunnel_name" >&2
                exit 1
            }

            if ! codex_validate_alias "$codex_dev_alias"; then
                printf '开发 alias 无效：%s\n' "$codex_dev_alias" >&2
                exit 1
            fi
            if ! codex_validate_alias "$codex_proxy_alias"; then
                printf '代理 alias 无效：%s\n' "$codex_proxy_alias" >&2
                exit 1
            fi

            for codex_alias in "$codex_dev_alias" "$codex_proxy_alias"; do
                case ",$codex_seen_aliases," in
                    *",$codex_alias,"*)
                        printf 'SSH alias 重复：%s\n' "$codex_alias" >&2
                        exit 1
                        ;;
                esac
                codex_seen_aliases=$codex_seen_aliases$codex_alias,
            done
        done
    ); then
        return 1
    fi

    return 0
}

codex_config_tunnel_names() {
    codex_config_tunnel_names_path=$1
    codex_config_get "$codex_config_tunnel_names_path" TUNNEL_NAMES | tr ',' '\n'
}

codex_default_install_root() {
    printf '%s\n' "${CODEX_SSH_TUNNEL_INSTALL_ROOT:-$HOME/Library/Application Support/Codex/ssh-tunnel-manager}"
}

codex_default_log_root() {
    printf '%s\n' "${CODEX_SSH_TUNNEL_LOG_ROOT:-$HOME/Library/Logs/Codex/ssh-tunnels}"
}

codex_default_state_root() {
    printf '%s\n' "${CODEX_SSH_TUNNEL_STATE_ROOT:-$HOME/Library/Application Support/Codex/ssh-tunnels}"
}

codex_launchd_domain() {
    printf 'gui/%s\n' "$(id -u)"
}

codex_launchd_target() {
    printf '%s/%s\n' "$(codex_launchd_domain)" "$1"
}

codex_tunnel_label() {
    codex_tunnel_label_prefix=$1
    codex_tunnel_label_name=$2
    printf '%s.%s\n' "$codex_tunnel_label_prefix" "$codex_tunnel_label_name"
}

codex_utc_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

codex_utc_date() {
    date -u '+%Y%m%d'
}

codex_log() {
    codex_log_component=$1
    shift
    codex_log_root=${CODEX_SSH_TUNNEL_LOG_ROOT:-$HOME/Library/Logs/Codex/ssh-tunnels}
    mkdir -p "$codex_log_root" || return 1
    chmod 700 "$codex_log_root" 2>/dev/null || true
    codex_log_path="$codex_log_root/${codex_log_component}-$(codex_utc_date).log"
    printf '%s [%s] %s\n' "$(codex_utc_timestamp)" "$codex_log_component" "$*" >> "$codex_log_path"
}

codex_tcp_ready() {
    codex_tcp_host=$1
    codex_tcp_port=$2
    if [ "$codex_tcp_host" != '127.0.0.1' ]; then
        return 1
    fi
    if [ ! -x /usr/bin/nc ]; then
        return 1
    fi
    /usr/bin/nc -z -w 2 "$codex_tcp_host" "$codex_tcp_port" >/dev/null 2>&1
}

codex_ssh_pids() {
    /usr/bin/pgrep -x ssh 2>/dev/null || true
}

codex_pid_command() {
    /bin/ps -ww -p "$1" -o command= 2>/dev/null | sed 's/^[[:space:]]*//'
}

codex_pid_executable() {
    /bin/ps -p "$1" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//' | sed 's#.*/##'
}

codex_normalize_command() {
    printf '%s' "$1" | tr '\t' ' '
}

codex_command_has_token() {
    codex_command_value=$(codex_normalize_command "$1")
    codex_command_token=$2
    case " $codex_command_value " in
        *" $codex_command_token "*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

codex_command_has_session_signature() {
    codex_session_alias=$1
    codex_session_command=$(codex_normalize_command "$2")
    case " $codex_session_command " in
        *" $codex_session_alias "*'codex app-server proxy'*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

codex_command_has_tunnel_flags() {
    codex_tunnel_command=$1
    if ! codex_command_has_token "$codex_tunnel_command" '-N' && \
        ! codex_command_has_token "$codex_tunnel_command" '-NT'; then
        return 1
    fi
    if ! codex_command_has_token "$codex_tunnel_command" '-T' && \
        ! codex_command_has_token "$codex_tunnel_command" '-NT'; then
        return 1
    fi
    return 0
}

codex_pid_matches_session() {
    codex_session_pid=$1
    codex_session_alias=$2
    [ "$(codex_pid_executable "$codex_session_pid")" = 'ssh' ] || return 1
    codex_command_has_session_signature "$codex_session_alias" "$(codex_pid_command "$codex_session_pid")"
}

codex_pid_matches_tunnel() {
    codex_tunnel_pid_value=$1
    codex_tunnel_alias=$2
    codex_tunnel_runner_path=${3:-}
    codex_tunnel_executable=$(codex_pid_executable "$codex_tunnel_pid_value")
    codex_tunnel_command=$(codex_pid_command "$codex_tunnel_pid_value")

    case "$codex_tunnel_executable" in
        ssh)
            codex_command_has_token "$codex_tunnel_command" "$codex_tunnel_alias" || return 1
            codex_command_has_tunnel_flags "$codex_tunnel_command"
            ;;
        sh|bash)
            [ -n "$codex_tunnel_runner_path" ] || return 1
            case "$codex_tunnel_command" in
                *"$codex_tunnel_runner_path"*)
                    codex_command_has_token "$codex_tunnel_command" "$codex_tunnel_alias"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

codex_pid_matches_controller() {
    codex_controller_pid_value=$1
    codex_controller_alias=$2
    codex_controller_path=$3
    codex_controller_executable=$(codex_pid_executable "$codex_controller_pid_value")
    codex_controller_command=$(codex_pid_command "$codex_controller_pid_value")

    case "$codex_controller_executable" in
        sh|bash)
            case "$codex_controller_command" in
                *"$codex_controller_path"*)
                    codex_command_has_token "$codex_controller_command" "$codex_controller_alias"
                    ;;
                *)
                    return 1
                    ;;
            esac
            ;;
        *)
            return 1
            ;;
    esac
}

codex_find_session_pids() {
    codex_find_session_alias=$1
    for codex_find_session_pid in $(codex_ssh_pids); do
        if codex_pid_matches_session "$codex_find_session_pid" "$codex_find_session_alias"; then
            printf '%s\n' "$codex_find_session_pid"
        fi
    done
}

codex_find_tunnel_pids() {
    codex_find_tunnel_alias=$1
    for codex_find_tunnel_pid in $(codex_ssh_pids); do
        if codex_pid_matches_tunnel "$codex_find_tunnel_pid" "$codex_find_tunnel_alias"; then
            printf '%s\n' "$codex_find_tunnel_pid"
        fi
    done
}

codex_pid_alive() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
    esac
    [ "$1" -gt 0 ] 2>/dev/null || return 1
    /bin/kill -0 "$1" 2>/dev/null
}

codex_stop_validated_pid() {
    codex_stop_pid_value=$1
    codex_stop_alias=$2
    codex_stop_kind=$3
    codex_stop_path=$4

    if ! codex_pid_alive "$codex_stop_pid_value"; then
        return 0
    fi

    case "$codex_stop_kind" in
        controller)
            codex_pid_matches_controller "$codex_stop_pid_value" "$codex_stop_alias" "$codex_stop_path" || return 1
            ;;
        tunnel)
            codex_pid_matches_tunnel "$codex_stop_pid_value" "$codex_stop_alias" "$codex_stop_path" || return 1
            ;;
        *)
            return 1
            ;;
    esac

    /bin/kill -TERM "$codex_stop_pid_value" 2>/dev/null || true
    codex_stop_wait=0
    while [ "$codex_stop_wait" -lt 10 ]; do
        if ! codex_pid_alive "$codex_stop_pid_value"; then
            return 0
        fi
        sleep 1
        codex_stop_wait=$((codex_stop_wait + 1))
    done

    if [ "$codex_stop_kind" = controller ]; then
        codex_pid_matches_controller "$codex_stop_pid_value" "$codex_stop_alias" "$codex_stop_path" || return 1
    else
        codex_pid_matches_tunnel "$codex_stop_pid_value" "$codex_stop_alias" "$codex_stop_path" || return 1
    fi
    /bin/kill -KILL "$codex_stop_pid_value" 2>/dev/null || true
    codex_stop_wait=0
    while [ "$codex_stop_wait" -lt 3 ]; do
        if ! codex_pid_alive "$codex_stop_pid_value"; then
            return 0
        fi
        sleep 1
        codex_stop_wait=$((codex_stop_wait + 1))
    done
    return 1
}

codex_launchd_job_loaded() {
    /bin/launchctl print "$(codex_launchd_target "$1")" >/dev/null 2>&1
}

codex_launchd_job_pid() {
    codex_launchd_job_label=$1
    /bin/launchctl print "$(codex_launchd_target "$codex_launchd_job_label")" 2>/dev/null |
        sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' |
        /usr/bin/head -n 1
}

codex_find_tunnel_pid() {
    codex_find_tunnel_label=$1
    codex_find_tunnel_alias=$2
    codex_find_tunnel_runner=${3:-}
    codex_launchd_pid=$(codex_launchd_job_pid "$codex_find_tunnel_label")
    if codex_pid_alive "$codex_launchd_pid" && \
        codex_pid_matches_tunnel "$codex_launchd_pid" "$codex_find_tunnel_alias" "$codex_find_tunnel_runner"; then
        printf '%s\n' "$codex_launchd_pid"
        return 0
    fi

    codex_find_tunnel_pids "$codex_find_tunnel_alias" | /usr/bin/head -n 1
}

codex_xml_escape() {
    printf '%s' "$1" |
        sed \
            -e 's/&/\&amp;/g' \
            -e 's/</\&lt;/g' \
            -e 's/>/\&gt;/g' \
            -e 's/"/\&quot;/g' \
            -e "s/'/\&apos;/g"
}
