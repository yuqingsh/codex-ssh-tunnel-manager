#!/bin/sh

set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
wrapper_source="${1:-$script_dir/codex-app-proxy-wrapper.sh}"
bin_dir="$HOME/.local/bin"
codex_path="$bin_dir/codex"
direct_path="$bin_dir/codex.direct"

if [ ! -f "$wrapper_source" ]; then
    echo "Wrapper source not found: $wrapper_source" >&2
    exit 1
fi

mkdir -p "$bin_dir"

if [ -L "$codex_path" ] && [ ! -e "$direct_path" ]; then
    mv "$codex_path" "$direct_path"
elif [ -e "$codex_path" ] && ! grep -q 'CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1' "$codex_path" 2>/dev/null; then
    if [ -e "$direct_path" ]; then
        echo "Refusing to overwrite both $codex_path and $direct_path." >&2
        exit 1
    fi
    mv "$codex_path" "$direct_path"
fi

if [ ! -e "$direct_path" ]; then
    package_binary="$HOME/.codex/packages/standalone/current/bin/codex"
    if [ ! -x "$package_binary" ]; then
        echo "Official Codex binary not found at $package_binary." >&2
        exit 1
    fi
    ln -s "$package_binary" "$direct_path"
fi

install -m 755 "$wrapper_source" "$codex_path"
"$codex_path" --version

echo "Installed Codex proxy wrapper at $codex_path"
