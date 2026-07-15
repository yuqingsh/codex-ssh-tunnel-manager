#!/bin/sh

# CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1
# Ensure Codex processes started by a non-interactive SSH session use the
# reverse tunnel to the Windows proxy.

set -eu

proxy_url="${CODEX_PROXY_URL:-http://127.0.0.1:17897}"

HTTP_PROXY="$proxy_url"
HTTPS_PROXY="$proxy_url"
ALL_PROXY="$proxy_url"
http_proxy="$proxy_url"
https_proxy="$proxy_url"
all_proxy="$proxy_url"
NO_PROXY="127.0.0.1,localhost,::1"
no_proxy="$NO_PROXY"

export HTTP_PROXY HTTPS_PROXY ALL_PROXY
export http_proxy https_proxy all_proxy
export NO_PROXY no_proxy

exec "$HOME/.local/bin/codex.direct" "$@"
