#!/usr/bin/env bash

set -u

proxy_url="${CODEX_PROXY_URL:-http://127.0.0.1:17897}"
proxy_host="127.0.0.1"
proxy_port="17897"

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
