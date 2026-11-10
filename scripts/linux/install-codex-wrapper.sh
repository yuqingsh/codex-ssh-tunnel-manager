#!/bin/sh

# Install the Codex proxy wrapper for the current Linux user and maintain the
# list of loopback tunnel endpoints the wrapper probes.
#
# Backward compatible: the first non-option argument is still treated as the
# wrapper source file (default: codex-app-proxy-wrapper.sh next to this
# script).
#
# Endpoint file: $HOME/.config/codex-ssh-tunnel-manager/endpoints.conf
#   - without --endpoint, an existing file is kept untouched and a missing
#     file is created with the default http://127.0.0.1:17897 endpoint;
#   - with one or more --endpoint URL options, the file is rewritten
#     atomically (temporary file + rename) with the validated, de-duplicated
#     endpoints and mode 600, after backing up the previous file as
#     endpoints.conf.bak-<UTC timestamp>.
#
# Every client that connects to the same Linux host and user needs a distinct
# remote loopback port, otherwise the second tunnel cannot bind. Use for
# example Windows 17897, macOS 17898 and further clients 17899+.

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
bin_dir="$HOME/.local/bin"
codex_path="$bin_dir/codex"
direct_path="$bin_dir/codex.direct"
config_dir="$HOME/.config/codex-ssh-tunnel-manager"
endpoints_file="$config_dir/endpoints.conf"

usage() {
    cat <<'USAGE'
Usage: install-codex-wrapper.sh [--endpoint URL]... [wrapper_source]

Install the Codex proxy wrapper for the current Linux user.

Options:
  --endpoint URL   Add a loopback tunnel endpoint (http://127.0.0.1:<port>).
                   Repeatable; entries are validated, de-duplicated and
                   stored in $HOME/.config/codex-ssh-tunnel-manager/endpoints.conf.
  --help           Show this help and exit.

The first non-option argument is still accepted as the wrapper source file
(default: codex-app-proxy-wrapper.sh next to this script).

Every client connecting to the same Linux host and user needs its own remote
loopback port: for example Windows 17897, macOS 17898, further clients 17899+.
USAGE
}

trim() {
    trimmed=$1
    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
}

# Validate an endpoint URL: exactly http://127.0.0.1:<port> with a decimal
# port in 1-65535 and no leading zero.
is_valid_endpoint() {
    endpoint_candidate=$1
    case "$endpoint_candidate" in
        http://127.0.0.1:*) endpoint_port=${endpoint_candidate#http://127.0.0.1:} ;;
        *) return 1 ;;
    esac
    case "$endpoint_port" in
        ''|0*|*[!0-9]*|??????*) return 1 ;;
    esac
    [ "$endpoint_port" -ge 1 ] && [ "$endpoint_port" -le 65535 ]
}

tmp_file=''
cleanup() {
    if [ -n "$tmp_file" ] && [ -e "$tmp_file" ]; then
        rm -f "$tmp_file"
    fi
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

wrapper_source=''
endpoint_args=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --endpoint)
            if [ "$#" -lt 2 ]; then
                printf 'install-codex-wrapper: --endpoint requires a URL\n' >&2
                exit 2
            fi
            endpoint_args="${endpoint_args}${2}
"
            shift 2
            ;;
        --endpoint=*)
            endpoint_args="${endpoint_args}${1#--endpoint=}
"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --)
            shift
            while [ "$#" -gt 0 ]; do
                if [ -n "$wrapper_source" ]; then
                    printf 'install-codex-wrapper: unexpected extra argument: %s\n' "$1" >&2
                    exit 2
                fi
                wrapper_source=$1
                shift
            done
            ;;
        -*)
            printf 'install-codex-wrapper: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$wrapper_source" ]; then
                printf 'install-codex-wrapper: unexpected extra argument: %s\n' "$1" >&2
                exit 2
            fi
            wrapper_source=$1
            shift
            ;;
    esac
done

if [ -z "$wrapper_source" ]; then
    wrapper_source="$script_dir/codex-app-proxy-wrapper.sh"
fi
if [ ! -f "$wrapper_source" ]; then
    printf 'Wrapper source not found: %s\n' "$wrapper_source" >&2
    exit 1
fi

normalized_endpoints=''
if [ -n "$endpoint_args" ]; then
    for raw_endpoint in $endpoint_args; do
        if ! is_valid_endpoint "$raw_endpoint"; then
            printf 'install-codex-wrapper: invalid endpoint: %s (expected http://127.0.0.1:<1-65535>)\n' "$raw_endpoint" >&2
            exit 1
        fi
        duplicate=0
        for existing_endpoint in $normalized_endpoints; do
            if [ "$existing_endpoint" = "$raw_endpoint" ]; then
                duplicate=1
                break
            fi
        done
        if [ "$duplicate" -eq 0 ]; then
            normalized_endpoints="${normalized_endpoints}${raw_endpoint}
"
        fi
    done
fi

endpoint_header='# Codex SSH 隧道代理端点列表（Linux 端）。
#
# 每行一个端点，格式必须为 http://127.0.0.1:<1-65535>；空行和以 # 开头的行会被忽略。
# 同一台 Linux 开发机上，每台客户端必须使用不同的远端回环端口，否则后连接的隧道
# 会因端口已被占用而无法建立。约定 Windows 17897、macOS 17898，更多客户端 17899 及以后。
# Codex wrapper 会按顺序探测这些端点，并选择第一个可用的端点。
'
default_endpoint_content="${endpoint_header}http://127.0.0.1:17897
"

write_endpoints_file() {
    new_content=$1
    mkdir -p "$config_dir"
    if [ -e "$endpoints_file" ]; then
        backup_timestamp=$(date -u '+%Y%m%dT%H%M%SZ')
        backup_file="${endpoints_file}.bak-${backup_timestamp}"
        cp "$endpoints_file" "$backup_file"
        printf 'Backed up previous endpoint file to %s\n' "$backup_file"
    fi
    tmp_file="${endpoints_file}.tmp.$$"
    (umask 077; printf '%s' "$new_content" >"$tmp_file")
    chmod 600 "$tmp_file"
    mv "$tmp_file" "$endpoints_file"
    tmp_file=''
}

mkdir -p "$bin_dir"

if [ -L "$codex_path" ] && [ ! -e "$direct_path" ]; then
    mv "$codex_path" "$direct_path"
elif [ -e "$codex_path" ] && ! grep -q 'CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1' "$codex_path" 2>/dev/null; then
    if [ -e "$direct_path" ]; then
        printf 'Refusing to overwrite both %s and %s.\n' "$codex_path" "$direct_path" >&2
        exit 1
    fi
    mv "$codex_path" "$direct_path"
fi

if [ ! -e "$direct_path" ]; then
    package_binary="$HOME/.codex/packages/standalone/current/bin/codex"
    if [ ! -x "$package_binary" ]; then
        printf 'Official Codex binary not found at %s.\n' "$package_binary" >&2
        exit 1
    fi
    ln -s "$package_binary" "$direct_path"
fi

install -m 755 "$wrapper_source" "$codex_path"
printf 'Installed Codex proxy wrapper at %s\n' "$codex_path"

if [ -n "$normalized_endpoints" ]; then
    write_endpoints_file "${endpoint_header}${normalized_endpoints}"
elif [ -e "$endpoints_file" ]; then
    printf 'Keeping existing endpoint file: %s\n' "$endpoints_file"
else
    write_endpoints_file "$default_endpoint_content"
fi

# Validate that the installed wrapper can still start the official Codex
# binary, and keep its --version output visible.
"$codex_path" --version

configured_endpoints=''
if [ -r "$endpoints_file" ]; then
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        trim "$raw_line"
        candidate=$trimmed
        case "$candidate" in
            ''|\#*) continue ;;
        esac
        if is_valid_endpoint "$candidate"; then
            configured_endpoints="${configured_endpoints}${candidate}
"
        fi
    done <"$endpoints_file"
fi

configured_count=0
for endpoint in $configured_endpoints; do
    configured_count=$((configured_count + 1))
done

printf '\nEndpoint file: %s\n' "$endpoints_file"
printf 'Endpoints:\n'
if [ "$configured_count" -eq 0 ]; then
    printf '  (none)\n'
else
    for endpoint in $configured_endpoints; do
        printf '  %s\n' "$endpoint"
    done
fi

if [ "$configured_count" -eq 1 ]; then
    printf '\nOnly one endpoint is configured. Clients sharing the same Linux host and\n'
    printf 'user need distinct remote ports (Windows 17897, macOS 17898, further 17899+).\n'
    printf 'Add another endpoint, for example:\n'
    printf '  install-codex-wrapper.sh --endpoint http://127.0.0.1:17898\n'
fi
