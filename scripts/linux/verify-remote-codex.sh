#!/usr/bin/env bash

# Verify the Codex proxy wrapper environment on the Linux host.
#
# Endpoint resolution matches codex-app-proxy-wrapper.sh:
#   1. CODEX_PROXY_URL, when non-empty, is reported as-is and never probed;
#   2. otherwise endpoints come from
#      ${CODEX_SSH_TUNNEL_ENDPOINTS_FILE:-$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf}
#      (only http://127.0.0.1:<1-65535> lines are accepted);
#   3. a single endpoint is reported as skipped and used directly;
#   4. multiple endpoints are probed with curl; the first healthy one is used,
#      and when none is healthy the first endpoints is used as a fallback.
#
# Every candidate endpoint is reported as
#   ENDPOINT=<url> PROBE=healthy|unhealthy|skipped
# followed by ENDPOINT_SELECTED=<url>, and the selected endpoint is then used
# for the nc/curl/environment checks.

set -u

debug=${CODEX_TUNNEL_DEBUG:-}
probe_target=${CODEX_TUNNEL_PROBE_TARGET:-http://codex-tunnel-probe.invalid/}
endpoints_file=${CODEX_SSH_TUNNEL_ENDPOINTS_FILE:-$HOME/.config/codex-ssh-tunnel-manager/endpoints.conf}
default_endpoint='http://127.0.0.1:17897'
trimmed=''

debug_log() {
    if [ "$debug" = '1' ]; then
        printf 'verify-remote-codex: %s\n' "$*" >&2
    fi
}

trim() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    trimmed=$value
}

# Validate an endpoint URL: exactly http://127.0.0.1:<port> with a decimal
# port in 1-65535 and no leading zero.
is_valid_endpoint() {
    local candidate=$1
    local port
    case "$candidate" in
        http://127.0.0.1:*) port=${candidate#http://127.0.0.1:} ;;
        *) return 1 ;;
    esac
    case "$port" in
        ''|0*|*[!0-9]*|??????*) return 1 ;;
    esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ]
}

endpoints=()
if [ -n "${CODEX_PROXY_URL:-}" ]; then
    endpoints=("$CODEX_PROXY_URL")
    debug_log 'CODEX_PROXY_URL is set, endpoint list is not used'
elif [ -r "$endpoints_file" ]; then
    while IFS= read -r raw_line || [ -n "$raw_line" ]; do
        trim "$raw_line"
        endpoint_line=$trimmed
        case "$endpoint_line" in
            ''|\#*) continue ;;
        esac
        if is_valid_endpoint "$endpoint_line"; then
            endpoints+=("$endpoint_line")
        else
            debug_log "ignoring invalid endpoint line in $endpoints_file: $endpoint_line"
        fi
    done <"$endpoints_file"
    debug_log "endpoint file: $endpoints_file"
else
    debug_log "endpoint file not readable, using default: $endpoints_file"
fi
if [ "${#endpoints[@]}" -eq 0 ]; then
    endpoints=("$default_endpoint")
    debug_log "no valid endpoint configured, using default: $default_endpoint"
fi

selected=''
selection_reason=''
if [ -n "${CODEX_PROXY_URL:-}" ]; then
    selected=$CODEX_PROXY_URL
    selection_reason=env
    printf 'ENDPOINT=%s PROBE=skipped\n' "$selected"
elif [ "${#endpoints[@]}" -eq 1 ]; then
    selected=${endpoints[0]}
    selection_reason=single
    printf 'ENDPOINT=%s PROBE=skipped\n' "$selected"
elif ! command -v curl >/dev/null 2>&1; then
    selected=${endpoints[0]}
    selection_reason=fallback
    for endpoint_candidate in "${endpoints[@]}"; do
        printf 'ENDPOINT=%s PROBE=skipped\n' "$endpoint_candidate"
    done
    debug_log 'curl not available, cannot probe endpoints'
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
    first_endpoint=${endpoints[0]}
    for endpoint_candidate in "${endpoints[@]}"; do
        probe_code=''
        if probe_code=$(curl --proxy "$endpoint_candidate" --connect-timeout 1 \
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
            printf 'ENDPOINT=%s PROBE=healthy\n' "$endpoint_candidate"
            if [ -z "$selected" ]; then
                selected=$endpoint_candidate
                selection_reason=probe
            fi
        else
            printf 'ENDPOINT=%s PROBE=unhealthy\n' "$endpoint_candidate"
            debug_log "probe endpoint=$endpoint_candidate http_code=${probe_code:-none} curl_exit=$probe_exit"
        fi
    done
    if [ -z "$selected" ]; then
        selected=$first_endpoint
        selection_reason=fallback
        debug_log "no endpoint is healthy, using first endpoint: $selected"
    fi
fi
printf 'ENDPOINT_SELECTED=%s\n' "$selected"
debug_log "selected=$selected reason=$selection_reason"

proxy_url=$selected
proxy_host='127.0.0.1'
proxy_port='17897'
if [[ $proxy_url =~ ^http://([^/:]+)(:([0-9]+))? ]]; then
    proxy_host=${BASH_REMATCH[1]}
    if [ -n "${BASH_REMATCH[3]:-}" ]; then
        proxy_port=${BASH_REMATCH[3]}
    else
        proxy_port='80'
    fi
fi

echo "HOSTNAME=$(hostname)"
printf 'CODEX_VERSION='
"$HOME/.local/bin/codex" --version 2>&1 || true

if nc -z -w3 "$proxy_host" "$proxy_port" >/dev/null 2>&1; then
    echo 'TUNNEL=tunnel-ok'
else
    echo 'TUNNEL=tunnel-missing'
fi

http_code=$(curl -sS -o /dev/null --max-time 20 \
    --proxy "$proxy_url" \
    -w '%{http_code}' \
    https://api.openai.com/v1/models)
curl_exit=$?
echo "TRANSPORT_CURL_EXIT=$curl_exit"
echo "TRANSPORT_HTTP_CODE=$http_code"

proxy_count=0
for pid in $(pgrep -f '[c]odex.direct app-server proxy' 2>/dev/null); do
    proxy_count=$((proxy_count + 1))
    if tr '\0' '\n' < "/proc/$pid/environ" | grep -q "^HTTPS_PROXY=$proxy_url$"; then
        proxy_env='present'
    else
        proxy_env='missing'
    fi
    echo "APP_SERVER_PROXY_PID=$pid HTTPS_PROXY=$proxy_env"
done
echo "APP_SERVER_PROXY_COUNT=$proxy_count"

host_count=0
for pid in $(pgrep -f 'features[.]code_mode_host=true' 2>/dev/null); do
    host_count=$((host_count + 1))
    if tr '\0' '\n' < "/proc/$pid/environ" | grep -q "^HTTPS_PROXY=$proxy_url$"; then
        proxy_env='present'
    else
        proxy_env='missing'
    fi
    echo "CODE_MODE_HOST_PID=$pid HTTPS_PROXY=$proxy_env"
done
echo "CODE_MODE_HOST_COUNT=$host_count"

if [ "$curl_exit" -ne 0 ]; then
    exit "$curl_exit"
fi
