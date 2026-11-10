#!/bin/sh

# CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1
# Ensure Codex processes started by a non-interactive SSH session use a
# reverse-tunnel proxy endpoint bound to 127.0.0.1 on this Linux host.
#
# Several client machines can share the same Linux host and user, but each
# client must forward its own loopback port. The wrapper therefore reads an
# endpoint list and probes the entries so that a stale or missing tunnel on
# one client does not break Codex for the others:
#
#   1. CODEX_PROXY_URL, when non-empty, is used as-is (legacy behavior) and no
#      endpoint file is read and no probe is made;
#   2. otherwise endpoints are read from
#        ${CODEX_SSH_TUNNEL_ENDPOINTS_FILE:-$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf}
#      where only http://127.0.0.1:<1-65535> lines are accepted, blank lines
#      and lines starting with '#' are ignored; a missing file or a file with
#      no valid line falls back to http://127.0.0.1:17897;
#   3. a single endpoint is used directly, without probing;
#   4. multiple endpoints are probed in order through curl; the first healthy
#      endpoint (curl exit code 0 and HTTP status code >= 100) wins. When no
#      endpoint is healthy, the first endpoint is used and a status log line
#      is appended under
#      ${XDG_STATE_HOME:-$HOME/.local/state}/codex/ssh-tunnel-manager/.
#
# CODEX_TUNNEL_DEBUG=1 prints the selection reason and every probe result to
# stderr. CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS (integer 1-10, default 2) and
# CODEX_TUNNEL_PROBE_TARGET (default http://codex-tunnel-probe.invalid/) tune
# the probe request; a proxy answering 502 for the reserved .invalid name is
# healthy, because it proves the proxy endpoint carried the request.
#
# The selection reason reported in debug output is one of:
#   env      - CODEX_PROXY_URL was set
#   single   - a single endpoint was configured (no probe)
#   probe    - a probed endpoint was healthy
#   fallback - no probe was possible or no endpoint was healthy

set -eu

debug=${CODEX_TUNNEL_DEBUG:-}
probe_target=${CODEX_TUNNEL_PROBE_TARGET:-http://codex-tunnel-probe.invalid/}
endpoints_file=${CODEX_SSH_TUNNEL_ENDPOINTS_FILE:-"$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf"}
default_endpoint='http://127.0.0.1:17897'

debug_log() {
    if [ "$debug" = '1' ]; then
        printf 'codex-wrapper: %s\n' "$*" >&2
    fi
}

# Trim leading and trailing whitespace (including CR from CRLF files).
trim() {
    trimmed=$1
    trimmed=${trimmed#"${trimmed%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
}

# Validate an endpoint URL: exactly http://127.0.0.1:<port> with a decimal
# port in 1-65535 and no leading zero.
is_valid_endpoint() {
    candidate=$1
    case "$candidate" in
        http://127.0.0.1:*) endpoint_port=${candidate#http://127.0.0.1:} ;;
        *) return 1 ;;
    esac
    case "$endpoint_port" in
        ''|0*|*[!0-9]*|??????*) return 1 ;;
    esac
    [ "$endpoint_port" -ge 1 ] && [ "$endpoint_port" -le 65535 ]
}

# Append a status line without ever failing the wrapper: a read-only or full
# state directory must not prevent Codex from starting.
write_fallback_log() {
    fallback_detail=$1
    state_root=${XDG_STATE_HOME:-}
    if [ -z "$state_root" ]; then
        state_root=$HOME/.local/state
    fi
    log_dir=$state_root/codex/ssh-tunnel-manager
    if ! mkdir -p "$log_dir" 2>/dev/null; then
        debug_log "unable to create state log directory: $log_dir"
        return 0
    fi
    log_file=$log_dir/wrapper-$(date -u '+%Y%m%d').log
    log_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    if {
        printf '%s codex-wrapper fallback selected=%s endpoints=%s %s\n' \
            "$log_timestamp" "$selected" "$endpoint_count" "$fallback_detail"
    } >>"$log_file" 2>/dev/null; then
        debug_log "fallback logged to $log_file"
    else
        debug_log "unable to write state log: $log_file"
    fi
    return 0
}

endpoint_list=''
if [ -r "$endpoints_file" ]; then
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        trim "$raw_line"
        candidate=$trimmed
        case "$candidate" in
            ''|\#*) continue ;;
        esac
        if is_valid_endpoint "$candidate"; then
            endpoint_list="${endpoint_list}${candidate}
"
        else
            debug_log "ignoring invalid endpoint line in $endpoints_file: $candidate"
        fi
    done <"$endpoints_file"
    debug_log "endpoint file: $endpoints_file"
else
    debug_log "endpoint file not readable, using default: $endpoints_file"
fi

endpoint_count=0
for endpoint in $endpoint_list; do
    endpoint_count=$((endpoint_count + 1))
done
if [ "$endpoint_count" -eq 0 ]; then
    endpoint_list="${default_endpoint}
"
    endpoint_count=1
    debug_log "no valid endpoint configured, using default: $default_endpoint"
fi

selected=''
selection_reason=''
if [ -n "${CODEX_PROXY_URL:-}" ]; then
    selected=$CODEX_PROXY_URL
    selection_reason=env
elif [ "$endpoint_count" -eq 1 ]; then
    for endpoint in $endpoint_list; do
        selected=$endpoint
    done
    selection_reason=single
elif ! command -v curl >/dev/null 2>&1; then
    for endpoint in $endpoint_list; do
        selected=$endpoint
        break
    done
    selection_reason=fallback
    debug_log "curl not available, using first endpoint without probing"
    write_fallback_log 'detail=curl-unavailable'
else
    probe_timeout=2
    probe_timeout_raw=${CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS:-}
    if [ -n "$probe_timeout_raw" ]; then
        case "$probe_timeout_raw" in
            ''|0*|*[!0-9]*|??????*)
                debug_log "ignoring invalid CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS: $probe_timeout_raw"
                ;;
            *)
                if [ "$probe_timeout_raw" -ge 1 ] && [ "$probe_timeout_raw" -le 10 ]; then
                    probe_timeout=$probe_timeout_raw
                else
                    debug_log "ignoring out-of-range CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS: $probe_timeout_raw"
                fi
                ;;
        esac
    fi
    first_endpoint=''
    for endpoint in $endpoint_list; do
        if [ -z "$first_endpoint" ]; then
            first_endpoint=$endpoint
        fi
        probe_code=''
        if probe_code=$(curl --proxy "$endpoint" --connect-timeout 1 \
            --max-time "$probe_timeout" -s -o /dev/null -w '%{http_code}' \
            "$probe_target" 2>/dev/null); then
            probe_exit=0
        else
            probe_exit=$?
        fi
        probe_healthy=0
        if [ "$probe_exit" -eq 0 ]; then
            case "$probe_code" in
                [1-9][0-9][0-9]) probe_healthy=1 ;;
            esac
        fi
        if [ "$probe_healthy" -eq 1 ]; then
            debug_log "probe endpoint=$endpoint target=$probe_target result=healthy http_code=$probe_code"
            selected=$endpoint
            selection_reason=probe
            break
        fi
        debug_log "probe endpoint=$endpoint target=$probe_target result=unhealthy http_code=${probe_code:-none} curl_exit=$probe_exit"
    done
    if [ -z "$selected" ]; then
        selected=$first_endpoint
        selection_reason=fallback
        debug_log "no endpoint is healthy, using first endpoint: $selected"
        write_fallback_log 'detail=all-probes-unhealthy'
    fi
fi

debug_log "selected=$selected reason=$selection_reason"

HTTP_PROXY=$selected
HTTPS_PROXY=$selected
ALL_PROXY=$selected
http_proxy=$selected
https_proxy=$selected
all_proxy=$selected
NO_PROXY='127.0.0.1,localhost,::1'
no_proxy=$NO_PROXY

export HTTP_PROXY HTTPS_PROXY ALL_PROXY
export http_proxy https_proxy all_proxy
export NO_PROXY no_proxy

exec "$HOME/.local/bin/codex.direct" "$@"
