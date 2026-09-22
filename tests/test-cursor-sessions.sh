#!/bin/sh
set -eu
repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$repository_root/scripts/macos/codex-ssh-tunnel-common.sh"
check_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cursor-tunnel-tests-XXXXXX")
trap 'rm -rf "$check_tmp"' EXIT HUP INT TERM
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

for command in \
    'ssh -T -D 54321 primary-dev bash --login -c bash' \
    '/usr/bin/ssh -vT -D54321 -o ConnectTimeout=15 primary-dev bash --login -c bash' \
    'ssh -T -F "/tmp/config with spaces" -L /tmp/local:/tmp/remote primary-dev /bin/bash --login -c bash' \
    'ssh -T -D 54321 -- primary-dev bash --login -c bash'; do
    codex_command_has_cursor_signature primary-dev "$command" || fail "valid Cursor command: $command"
done
for command in \
    'ssh -T -D 54321 primary-dev-extra bash --login -c bash' \
    'ssh -T -D 54321 other-dev echo primary-dev bash --login -c bash' \
    'ssh -T -D 54321 -o primary-dev other-dev bash --login -c bash' \
    'ssh -T -D 54321 primary-dev hostname' \
    'ssh -T primary-dev bash --login -c bash' \
    'ssh -T -N -D 54321 primary-dev bash --login -c bash' \
    'ssh -T -D 54321 primary-proxy bash --login -c bash' \
    'ssh -T -D 54321 user@primary-dev bash --login -c bash' \
    'ssh -T -D 54321 primary-dev bash --login -c bash extra' \
    'sh -T -D 54321 primary-dev bash --login -c bash' \
    'ssh -T -D 54321 -F "unterminated primary-dev bash --login -c bash'; do
    if codex_command_has_cursor_signature primary-dev "$command"; then fail "false positive: $command"; fi
done

# Model the observed SSH -> shell -> Cursor Helper ancestry, plus unrelated
# terminals, exited parents and cycles. No real process is started or stopped.
codex_pid_executable() { printf 'ssh\n'; }
codex_pid_command() {
    case "$1" in
        101) printf 'ssh -T primary-dev codex app-server proxy\n' ;;
        *) printf 'ssh -T -D 54321 primary-dev bash --login -c bash\n' ;;
    esac
}
codex_pid_parent() {
    case "$1" in
        102) printf '202\n' ;; 202) printf '302\n' ;;
        103) printf '303\n' ;; 104) printf '304\n' ;;
        105) printf '305\n' ;; 305) printf '105\n' ;;
        *) printf '1\n' ;;
    esac
}
codex_pid_executable_path() {
    case "$1" in
        202) printf '/bin/sh\n' ;;
        302) printf '/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)\n' ;;
        303) printf '/Applications/Terminal.app/Contents/MacOS/Terminal\n' ;;
        304) printf '/tmp/Cursor.app-fake/Contents/MacOS/Cursor\n' ;;
        *) printf '/bin/sh\n' ;;
    esac
}
codex_ssh_pids() { printf '101\n102\n103\n104\n105\n106\n'; }
codex_pid_matches_cursor_session 102 primary-dev || fail 'Cursor ancestry not detected'
for pid in 103 104 105 106; do
    if codex_pid_matches_cursor_session "$pid" primary-dev; then fail "invalid ancestry: $pid"; fi
done
[ "$(codex_find_session_pids primary-dev codex)" = 101 ] || fail 'Codex regression'
[ "$(codex_find_session_pids primary-dev cursor)" = 102 ] || fail 'Cursor classification'
[ "$(codex_find_session_pids primary-dev | tr '\n' ' ')" = '101 102 ' ] || fail 'shared demand'

# Execute the actual controller cycle with mock launchd/tunnel operations.
# Only omit its infinite driver loop. State is isolated to this test directory.
sed 's/^TUNNEL_NAMES=.*/TUNNEL_NAMES=primary/' "$repository_root/config/tunnels.macos.example.conf" > "$check_tmp/config.conf"
cp "$repository_root/scripts/macos/codex-ssh-tunnel-common.sh" "$check_tmp/"
sed '/^for initial_name in /,$d' "$repository_root/scripts/macos/codex-ssh-tunnel-controller.sh" > "$check_tmp/controller-test.sh"
cat >> "$check_tmp/controller-test.sh" <<'TEST'
test_now=1000
test_demand=cursor
test_running=0
test_starts=0
test_stops=0
date() { printf '%s\n' "$test_now"; }
codex_log() { :; }
codex_find_session_pids() {
    [ "${2:-all}" = all ] || exit 91
    [ "$test_demand" = none ] || printf '102\n'
    return 0
}
codex_find_tunnel_pid() { [ "$test_running" = 0 ] || printf '900\n'; return 0; }
codex_tcp_ready() { return 0; }
codex_launchd_kickstart() { test_starts=$((test_starts + 1)); test_running=1; }
stop_tunnel() { test_stops=$((test_stops + 1)); test_running=0; }
run_cycle
[ "$test_starts" = 1 ] && [ "$test_running" = 1 ] || exit 92
# A Cursor-only session continues past the original Codex grace timeout.
test_now=2000
run_cycle
[ "$test_starts" = 1 ] && [ "$test_stops" = 0 ] || exit 93
# Disconnect, reconnect inside grace, then finally disconnect past grace.
test_demand=none
test_now=2500
run_cycle
[ "$test_stops" = 0 ]
test_demand=cursor
test_now=2550
run_cycle
test_demand=none
test_now=3100
run_cycle
[ "$test_stops" = 0 ]
test_now=3151
run_cycle
[ "$test_stops" = 1 ] && [ "$test_running" = 0 ] || exit 94
# No demand must not launch another tunnel.
test_now=4000
run_cycle
[ "$test_starts" = 1 ]
TEST
CODEX_SSH_TUNNEL_STATE_ROOT="$check_tmp/state" \
CODEX_SSH_TUNNEL_LOG_ROOT="$check_tmp/log" \
    sh "$check_tmp/controller-test.sh" --config "$check_tmp/config.conf" || fail 'controller lifecycle'
printf 'Cursor session and controller lifecycle tests passed.\n'
