#!/bin/sh

# Offline tests for the Linux multi-endpoint Codex proxy wrapper and installer.
#
# The tests run with a fake HOME, a fake $HOME/.local/bin/codex.direct and a
# PATH-injected fake curl, so they never touch the real user configuration,
# never write inside the repository and never use the network. Every file is
# created under a fresh system temporary directory removed by the trap.

set -u

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
wrapper_script="$repository_root/scripts/linux/codex-app-proxy-wrapper.sh"
installer_script="$repository_root/scripts/linux/install-codex-wrapper.sh"

failures=0
checks=0

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    failures=$((failures + 1))
}

assert_equals() {
    assertion_actual=$1
    assertion_expected=$2
    assertion_message=$3
    checks=$((checks + 1))
    if [ "$assertion_actual" != "$assertion_expected" ]; then
        fail "$assertion_message (expected [$assertion_expected], got [$assertion_actual])"
    fi
}

assert_file_contains() {
    assertion_file=$1
    assertion_needle=$2
    assertion_message=$3
    checks=$((checks + 1))
    if ! grep -F -e "$assertion_needle" "$assertion_file" >/dev/null 2>&1; then
        fail "$assertion_message (missing [$assertion_needle] in $assertion_file)"
    fi
}

assert_file_not_contains() {
    assertion_file=$1
    assertion_needle=$2
    assertion_message=$3
    checks=$((checks + 1))
    if grep -F -e "$assertion_needle" "$assertion_file" >/dev/null 2>&1; then
        fail "$assertion_message (unexpected [$assertion_needle] in $assertion_file)"
    fi
}

assert_file_not_exists() {
    assertion_path=$1
    assertion_message=$2
    checks=$((checks + 1))
    if [ -e "$assertion_path" ]; then
        fail "$assertion_message (unexpected path: $assertion_path)"
    fi
}

assert_file_exists() {
    assertion_path=$1
    assertion_message=$2
    checks=$((checks + 1))
    if [ ! -e "$assertion_path" ]; then
        fail "$assertion_message (missing path: $assertion_path)"
    fi
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

temp_base=${TMPDIR:-/tmp}
temp_root=$(mktemp -d "$temp_base/codex-linux-wrapper-test.XXXXXX") || {
    printf 'FAIL: cannot create temporary test directory\n' >&2
    exit 1
}
cleanup() {
    chmod -R u+rwX "$temp_root" 2>/dev/null || :
    rm -rf "$temp_root"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

unset CODEX_PROXY_URL CODEX_SSH_TUNNEL_ENDPOINTS_FILE CODEX_TUNNEL_DEBUG \
    CODEX_TUNNEL_PROBE_TARGET CODEX_TUNNEL_PROBE_TIMEOUT_SECONDS \
    XDG_STATE_HOME FAKE_CURL_HEALTHY FAKE_CURL_HEALTHY_CODE \
    FAKE_CURL_INVOCATIONS FAKE_CURL_TARGET_LOG FAKE_DIRECT_CAPTURE \
    FAKE_DIRECT_EXIT 2>/dev/null || :

fake_bin="$temp_root/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/curl" <<'FAKE_CURL'
#!/bin/sh
endpoint=''
target=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --proxy)
            shift
            endpoint=${1:-}
            ;;
        --connect-timeout|--max-time|-o|-w)
            shift
            ;;
        -s|--silent)
            ;;
        *)
            target=$1
            ;;
    esac
    shift
done
if [ -n "${FAKE_CURL_INVOCATIONS:-}" ]; then
    printf '%s\n' "$endpoint" >>"$FAKE_CURL_INVOCATIONS"
fi
if [ -n "${FAKE_CURL_TARGET_LOG:-}" ]; then
    printf '%s\n' "${target:-}" >>"$FAKE_CURL_TARGET_LOG"
fi
case ",${FAKE_CURL_HEALTHY:-}," in
    *",$endpoint,"*)
        printf '%s' "${FAKE_CURL_HEALTHY_CODE:-502}"
        exit 0
        ;;
esac
printf '000'
exit 7
FAKE_CURL
chmod 755 "$fake_bin/curl"

# make_home <case-name> creates a throw-away HOME with a fake codex.direct.
make_home() {
    case_home="$temp_root/home-$1"
    mkdir -p "$case_home/.local/bin" "$case_home/.config/codex-ssh-tunnel-manager"
    cat >"$case_home/.local/bin/codex.direct" <<'FAKE_DIRECT'
#!/bin/sh
if [ -n "${FAKE_DIRECT_CAPTURE:-}" ]; then
    {
        printf 'ARGC=%s\n' "$#"
        for argument in "$@"; do
            printf 'ARG=%s\n' "$argument"
        done
        printf 'HTTP_PROXY=%s\n' "${HTTP_PROXY:-}"
        printf 'HTTPS_PROXY=%s\n' "${HTTPS_PROXY:-}"
        printf 'ALL_PROXY=%s\n' "${ALL_PROXY:-}"
        printf 'http_proxy=%s\n' "${http_proxy:-}"
        printf 'https_proxy=%s\n' "${https_proxy:-}"
        printf 'all_proxy=%s\n' "${all_proxy:-}"
        printf 'NO_PROXY=%s\n' "${NO_PROXY:-}"
        printf 'no_proxy=%s\n' "${no_proxy:-}"
    } >"$FAKE_DIRECT_CAPTURE"
fi
exit "${FAKE_DIRECT_EXIT:-0}"
FAKE_DIRECT
    chmod 755 "$case_home/.local/bin/codex.direct"
}

write_endpoints() {
    endpoints_path=$1
    mkdir -p "$(dirname "$endpoints_path")"
    cat >"$endpoints_path"
}

reset_capture() {
    wrapper_stdout="$temp_root/wrapper.stdout"
    wrapper_stderr="$temp_root/wrapper.stderr"
    rm -f "$wrapper_stdout" "$wrapper_stderr"
}

# a) CODEX_PROXY_URL wins and curl must never run.
scenario_a_proxy_url_priority() {
    make_home a
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
http://127.0.0.1:17897
http://127.0.0.1:17898
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-a-direct.log"
    curl_invocations="$temp_root/case-a-curl.log"
    CODEX_PROXY_URL='http://127.0.0.1:19999' CODEX_TUNNEL_DEBUG=1 \
    FAKE_DIRECT_CAPTURE="$direct_capture" FAKE_CURL_INVOCATIONS="$curl_invocations" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" --version 'two words' \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case a: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:19999' 'case a: CODEX_PROXY_URL not exported as HTTP_PROXY'
    assert_file_contains "$direct_capture" 'ARG=--version' 'case a: first argument not passed through'
    assert_file_contains "$direct_capture" 'ARG=two words' 'case a: argument with space not passed through'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: selected=http://127.0.0.1:19999 reason=env' 'case a: missing debug selection line'
    assert_file_not_exists "$curl_invocations" 'case a: curl ran although CODEX_PROXY_URL was set'
}

# b) A single endpoint is used directly and never probed.
scenario_b_single_endpoint() {
    make_home b
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
# single endpoint
http://127.0.0.1:17898
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-b-direct.log"
    curl_invocations="$temp_root/case-b-curl.log"
    CODEX_TUNNEL_DEBUG=1 FAKE_DIRECT_CAPTURE="$direct_capture" \
    FAKE_CURL_INVOCATIONS="$curl_invocations" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case b: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17898' 'case b: single endpoint not selected'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: selected=http://127.0.0.1:17898 reason=single' 'case b: missing debug selection line'
    assert_file_not_exists "$curl_invocations" 'case b: curl ran for a single endpoint'
    assert_file_not_exists "$case_home/.local/state/codex/ssh-tunnel-manager" 'case b: normal path wrote a state log'
}

# c) Two endpoints, first unhealthy, second healthy: the second one wins.
scenario_c_probe_switch() {
    make_home c
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
http://127.0.0.1:17897
http://127.0.0.1:17898
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-c-direct.log"
    curl_invocations="$temp_root/case-c-curl.log"
    curl_targets="$temp_root/case-c-targets.log"
    CODEX_TUNNEL_DEBUG=1 FAKE_DIRECT_CAPTURE="$direct_capture" \
    FAKE_CURL_INVOCATIONS="$curl_invocations" FAKE_CURL_TARGET_LOG="$curl_targets" \
    FAKE_CURL_HEALTHY='http://127.0.0.1:17898' \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case c: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17898' 'case c: healthy second endpoint not selected'
    assert_equals "$(sed -n '1p' "$curl_invocations")" 'http://127.0.0.1:17897' 'case c: first probe endpoint'
    assert_equals "$(sed -n '2p' "$curl_invocations")" 'http://127.0.0.1:17898' 'case c: second probe endpoint'
    assert_equals "$(sed -n '1p' "$curl_targets")" 'http://codex-tunnel-probe.invalid/' 'case c: probe target'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: probe endpoint=http://127.0.0.1:17897 target=http://codex-tunnel-probe.invalid/ result=unhealthy' 'case c: first probe result'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: probe endpoint=http://127.0.0.1:17898 target=http://codex-tunnel-probe.invalid/ result=healthy http_code=502' 'case c: second probe result'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: selected=http://127.0.0.1:17898 reason=probe' 'case c: missing debug selection line'
    assert_file_not_exists "$case_home/.local/state/codex/ssh-tunnel-manager" 'case c: successful probe wrote a state log'
}

# d) HTTP status below 100 is not healthy. Both endpoints then fall back to the
#    first one and append one status log line.
scenario_d_low_http_code_fallback() {
    make_home d
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
http://127.0.0.1:17897
http://127.0.0.1:17898
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-d-direct.log"
    curl_invocations="$temp_root/case-d-curl.log"
    CODEX_TUNNEL_DEBUG=1 FAKE_DIRECT_CAPTURE="$direct_capture" \
    FAKE_CURL_INVOCATIONS="$curl_invocations" \
    FAKE_CURL_HEALTHY='http://127.0.0.1:17897,http://127.0.0.1:17898' \
    FAKE_CURL_HEALTHY_CODE='099' \
    XDG_STATE_HOME="$case_home/state" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case d: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17897' 'case d: fallback did not use the first endpoint'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: selected=http://127.0.0.1:17897 reason=fallback' 'case d: missing debug selection line'
    assert_file_contains "$wrapper_stderr" 'result=unhealthy http_code=099' 'case d: HTTP status 099 treated as other than unhealthy'
    log_count=0
    log_file=''
    for log_candidate in "$case_home/state/codex/ssh-tunnel-manager"/wrapper-*.log; do
        [ -f "$log_candidate" ] || continue
        log_count=$((log_count + 1))
        log_file=$log_candidate
    done
    assert_equals "$log_count" '1' 'case d: expected exactly one state log file'
    if [ "$log_count" -eq 1 ]; then
        assert_file_contains "$log_file" 'selected=http://127.0.0.1:17897' 'case d: state log does not name the fallback endpoint'
        assert_file_contains "$log_file" 'detail=all-probes-unhealthy' 'case d: state log does not explain the fallback'
    fi
    assert_equals "$(grep -c '^http' "$curl_invocations")" '2' 'case d: expected two probe attempts'
}

# e) Comments, blank lines and invalid endpoint lines are ignored; a file with
#    no valid line falls back to the default loopback endpoint.
scenario_e_invalid_lines() {
    make_home e
    explicit_endpoints="$temp_root/case-e-endpoints.conf"
    write_endpoints "$explicit_endpoints" <<'ENDPOINTS'
# comment line

   # indented comment
http://127.0.0.1:0
http://127.0.0.1:65536
https://127.0.0.1:17897
http://127.0.0.1:17897/extra
http://localhost:17897
http://0.0.0.0:17897
http://127.0.0.1:17897
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-e-direct.log"
    curl_invocations="$temp_root/case-e-curl.log"
    CODEX_SSH_TUNNEL_ENDPOINTS_FILE="$explicit_endpoints" CODEX_TUNNEL_DEBUG=1 \
    FAKE_DIRECT_CAPTURE="$direct_capture" FAKE_CURL_INVOCATIONS="$curl_invocations" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case e: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17897' 'case e: valid endpoint not selected'
    assert_file_contains "$wrapper_stderr" 'codex-wrapper: selected=http://127.0.0.1:17897 reason=single' 'case e: missing debug selection line'
    assert_file_contains "$wrapper_stderr" 'ignoring invalid endpoint line' 'case e: invalid lines were not reported in debug mode'
    assert_file_contains "$wrapper_stderr" 'http://localhost:17897' 'case e: invalid hostname line was not reported'
    assert_file_not_exists "$curl_invocations" 'case e: curl ran for a single valid endpoint'

    # No valid line at all: the default endpoint is used without probing.
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
# only comments and blank lines

ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-e-default-direct.log"
    CODEX_TUNNEL_DEBUG=1 FAKE_DIRECT_CAPTURE="$direct_capture" \
    FAKE_CURL_INVOCATIONS="$temp_root/case-e-default-curl.log" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case e default: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17897' 'case e default: default endpoint not selected'
    assert_file_contains "$wrapper_stderr" 'no valid endpoint configured, using default: http://127.0.0.1:17897' 'case e default: missing debug note'
    assert_file_not_exists "$temp_root/case-e-default-curl.log" 'case e default: curl ran for the default endpoint'
}

# f) Proxy variables in both cases, NO_PROXY and argument passthrough.
scenario_f_proxy_environment() {
    make_home f
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
http://127.0.0.1:17898
ENDPOINTS
    reset_capture
    direct_capture="$temp_root/case-f-direct.log"
    FAKE_DIRECT_CAPTURE="$direct_capture" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" app-server proxy --flag 'two words' \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    assert_equals "$wrapper_status" '0' 'case f: wrapper exit code'
    assert_file_contains "$direct_capture" 'ARGC=4' 'case f: argument count not passed through'
    assert_file_contains "$direct_capture" 'ARG=app-server' 'case f: first argument not passed through'
    assert_file_contains "$direct_capture" 'ARG=proxy' 'case f: second argument not passed through'
    assert_file_contains "$direct_capture" 'ARG=--flag' 'case f: option argument not passed through'
    assert_file_contains "$direct_capture" 'ARG=two words' 'case f: quoted argument not passed through'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17898' 'case f: HTTP_PROXY'
    assert_file_contains "$direct_capture" 'HTTPS_PROXY=http://127.0.0.1:17898' 'case f: HTTPS_PROXY'
    assert_file_contains "$direct_capture" 'ALL_PROXY=http://127.0.0.1:17898' 'case f: ALL_PROXY'
    assert_file_contains "$direct_capture" 'http_proxy=http://127.0.0.1:17898' 'case f: http_proxy'
    assert_file_contains "$direct_capture" 'https_proxy=http://127.0.0.1:17898' 'case f: https_proxy'
    assert_file_contains "$direct_capture" 'all_proxy=http://127.0.0.1:17898' 'case f: all_proxy'
    assert_file_contains "$direct_capture" 'NO_PROXY=127.0.0.1,localhost,::1' 'case f: NO_PROXY'
    assert_file_contains "$direct_capture" 'no_proxy=127.0.0.1,localhost,::1' 'case f: no_proxy'
}

# g) An unwritable state directory must not prevent the wrapper from starting.
scenario_g_unwritable_log() {
    make_home g
    write_endpoints "$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf" <<'ENDPOINTS'
http://127.0.0.1:17897
http://127.0.0.1:17898
ENDPOINTS
    readonly_state="$case_home/state-readonly"
    mkdir -p "$readonly_state"
    chmod 500 "$readonly_state"
    reset_capture
    direct_capture="$temp_root/case-g-direct.log"
    CODEX_TUNNEL_DEBUG=1 FAKE_DIRECT_CAPTURE="$direct_capture" \
    XDG_STATE_HOME="$readonly_state" \
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$wrapper_script" \
        >"$wrapper_stdout" 2>"$wrapper_stderr"
    wrapper_status=$?
    chmod 700 "$readonly_state" 2>/dev/null || :
    assert_equals "$wrapper_status" '0' 'case g: wrapper exit code'
    assert_file_contains "$direct_capture" 'HTTP_PROXY=http://127.0.0.1:17897' 'case g: fallback endpoint not selected'
    assert_file_contains "$wrapper_stderr" 'unable to create state log directory' 'case g: unwritable log directory was not reported in debug mode'
    assert_file_not_exists "$readonly_state/codex/ssh-tunnel-manager" 'case g: log directory unexpectedly created'
}

run_installer() {
    HOME="$case_home" PATH="$fake_bin:$PATH" \
        /bin/sh "$installer_script" "$@" >"$installer_stdout" 2>"$installer_stderr"
    installer_status=$?
    return "$installer_status"
}

# Installer: legacy positional wrapper source, --endpoint validation/dedup/
# atomic rewrite/backup/mode, --help, and the default endpoint file.
scenario_installer() {
    if ! command -v install >/dev/null 2>&1; then
        printf 'SKIP: installer tests (install command unavailable)\n'
        return 0
    fi
    make_home installer
    installer_stdout="$temp_root/installer.stdout"
    installer_stderr="$temp_root/installer.stderr"
    endpoints_file="$case_home/.config/codex-ssh-tunnel-manager/endpoints.conf"

    # Fresh install without --endpoint creates the default endpoint file.
    run_installer
    assert_equals "$installer_status" '0' 'installer: fresh install exit code'
    assert_file_exists "$endpoints_file" 'installer: default endpoint file not created'
    assert_file_contains "$endpoints_file" 'http://127.0.0.1:17897' 'installer: default endpoint missing'
    assert_equals "$(file_mode "$endpoints_file")" '600' 'installer: default endpoint file mode'
    assert_file_contains "$installer_stdout" "Endpoint file: $endpoints_file" 'installer: endpoint file path not printed'
    assert_file_contains "$installer_stdout" 'Only one endpoint is configured' 'installer: single endpoint hint missing'
    assert_file_contains "$installer_stdout" '17898' 'installer: multi-client hint does not mention 17898'
    assert_file_contains "$case_home/.local/bin/codex" 'CODEX_SSH_TUNNEL_MANAGER_WRAPPER=1' 'installer: wrapper marker not installed'
    assert_file_exists "$case_home/.local/bin/codex.direct" 'installer: codex.direct not preserved'

    # Rewriting with --endpoint de-duplicates, backs up the old file and keeps
    # mode 600; the --endpoint=URL form is accepted as well.
    cp "$endpoints_file" "$temp_root/installer-old-endpoints.conf"
    run_installer --endpoint 'http://127.0.0.1:17898' \
        --endpoint 'http://127.0.0.1:17898' \
        --endpoint='http://127.0.0.1:17899'
    assert_equals "$installer_status" '0' 'installer: --endpoint install exit code'
    assert_equals "$(grep -c '^http://127\.0\.0\.1:' "$endpoints_file")" '2' 'installer: endpoints not de-duplicated'
    assert_file_contains "$endpoints_file" 'http://127.0.0.1:17898' 'installer: first explicit endpoint missing'
    assert_file_contains "$endpoints_file" 'http://127.0.0.1:17899' 'installer: second explicit endpoint missing'
    assert_file_not_contains "$endpoints_file" 'http://127.0.0.1:17897' 'installer: replaced endpoint still present'
    assert_equals "$(file_mode "$endpoints_file")" '600' 'installer: rewritten endpoint file mode'
    backup_count=0
    backup_file=''
    for backup_candidate in "$endpoints_file".bak-*; do
        [ -f "$backup_candidate" ] || continue
        backup_count=$((backup_count + 1))
        backup_file=$backup_candidate
    done
    assert_equals "$backup_count" '1' 'installer: expected one endpoint file backup'
    if [ "$backup_count" -eq 1 ]; then
        checks=$((checks + 1))
        if ! cmp -s "$backup_file" "$temp_root/installer-old-endpoints.conf"; then
            fail 'installer: backup does not match the previous endpoint file'
        fi
    fi

    # Invalid endpoints are rejected and leave the file untouched.
    cp "$endpoints_file" "$temp_root/installer-before-invalid.conf"
    for bad_endpoint in 'http://0.0.0.0:17897' 'http://127.0.0.1:0' \
        'http://127.0.0.1:65536' 'http://127.0.0.1:017897' \
        'https://127.0.0.1:17897' 'http://localhost:17897'; do
        if run_installer --endpoint "$bad_endpoint"; then
            fail "installer: invalid endpoint accepted: $bad_endpoint"
        fi
    done
    checks=$((checks + 1))
    if ! cmp -s "$endpoints_file" "$temp_root/installer-before-invalid.conf"; then
        fail 'installer: endpoint file changed after rejected endpoints'
    fi

    # --help works and documents --endpoint.
    run_installer --help
    assert_equals "$installer_status" '0' 'installer: --help exit code'
    assert_file_contains "$installer_stdout" '--endpoint' 'installer: --help does not document --endpoint'

    # Legacy positional wrapper source still works.
    custom_wrapper="$temp_root/custom-wrapper.sh"
    cp "$wrapper_script" "$custom_wrapper"
    printf '\n# legacy positional wrapper source test\n' >>"$custom_wrapper"
    run_installer "$custom_wrapper"
    assert_equals "$installer_status" '0' 'installer: legacy positional source exit code'
    checks=$((checks + 1))
    if ! cmp -s "$case_home/.local/bin/codex" "$custom_wrapper"; then
        fail 'installer: legacy positional wrapper source not installed'
    fi
}

scenario_a_proxy_url_priority
scenario_b_single_endpoint
scenario_c_probe_switch
scenario_d_low_http_code_fallback
scenario_e_invalid_lines
scenario_f_proxy_environment
scenario_g_unwritable_log
scenario_installer

if [ "$failures" -gt 0 ]; then
    printf 'Linux wrapper tests failed: %s failure(s).\n' "$failures" >&2
    exit 1
fi
printf 'Linux wrapper tests passed (%s checks).\n' "$checks"
