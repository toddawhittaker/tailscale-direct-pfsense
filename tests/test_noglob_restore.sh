#!/bin/sh

# Regression test: check_all_peers must restore the caller's noglob setting.
# Functions called inside its loop once shared one global flag with it and
# unset it, so its own "[ $flag -eq 0 ]" saw an empty value, printed an error,
# and never ran "set +f".

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"

tmpdir="$(make_temp_dir)"
fakebin="${tmpdir}/bin"
mkdir -p "$fakebin" || exit 1

cat > "${fakebin}/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$LOGGER_LOG"
exit 0
EOF

cat > "${fakebin}/date" <<'EOF'
#!/bin/sh
if [ "$1" = "+%s" ]; then
  printf '%s\n' 100000
else
  /bin/date "$@"
fi
EOF

cat > "${fakebin}/jot" <<'EOF'
#!/bin/sh
printf '%s\n' 900
EOF

cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >> "$SERVICE_LOG"
exit 0
EOF

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
exit 0
EOF

# Any unexpected real tool use fails loudly instead of touching the host.
for tool in tailscale curl netstat; do
  cat > "${fakebin}/${tool}" <<'EOF'
#!/bin/sh
printf 'unexpected call: %s\n' "$0" >> "$UNEXPECTED_LOG"
exit 1
EOF
done

chmod 755 "${fakebin}"/*

PATH="${fakebin}:/usr/bin:/bin"
export PATH

LOGGER_LOG="${tmpdir}/logger.log"
SERVICE_LOG="${tmpdir}/service.log"
UNEXPECTED_LOG="${tmpdir}/unexpected.log"
export LOGGER_LOG SERVICE_LOG UNEXPECTED_LOG

STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
PEERS="router1"
FAIL_THRESHOLD=1
RESTART_SERVICES="pfsense_tailscaled"
RESTART_SETTLE_SECONDS=1
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
RESTART_DEFERRAL_ENABLED=0
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
TEST=0
DEBUG=0

# Classification is injected so no tailscale command is needed.
check_peer_path() {
  printf '%s\n' "$FAKE_CLASS"
}

reset_case() {
  rm -rf "$STATE_DIR"
  : > "$SERVICE_LOG"
  : > "$LOGGER_LOG"
  set_peer_attr count router1 0
  set_peer_attr state router1 unknown
  set_peer_attr threshold_seen router1 none
}

has_f() {
  case $- in
    *f*) printf 'set\n' ;;
    *) printf 'unset\n' ;;
  esac
}

run_case() {
  FAKE_CLASS="$1"
  reset_case
  set +f
  errfile="${tmpdir}/stderr.$1"
  # The daemon runs without set -u.  Under it, the old shared-flag bug aborted
  # this file on the unset flag instead of reaching the assertions below.
  set +u
  check_all_peers 2> "$errfile"
  set -u
  after="$(has_f)"
  err_text="$(cat "$errfile")"
}

run_case direct
assert_eq "direct peer: noglob is off after check_all_peers" "unset" "$after"
assert_eq "direct peer: nothing written to stderr" "" "$err_text"
assert_eq "direct peer: state was recorded" "direct" \
  "$(get_peer_attr state router1 unset)"

run_case unknown
assert_eq "unknown peer: noglob is off after check_all_peers" "unset" "$after"
assert_eq "unknown peer: nothing written to stderr" "" "$err_text"
assert_eq "unknown peer: state was recorded" "unknown" \
  "$(get_peer_attr state router1 unset)"

run_case relayed
assert_eq "restarting peer: noglob is off after check_all_peers" "unset" "$after"
assert_eq "restarting peer: nothing written to stderr" "" "$err_text"
assert_eq "restarting peer: services were stopped, settled, and started" \
  "$(printf 'pfsense_tailscaled stop\nsleep 1\npfsense_tailscaled start')" \
  "$(cat "$SERVICE_LOG")"
assert_eq "restarting peer: successful restart marked the peer post_restart" \
  "post_restart" "$(get_peer_attr state router1 unset)"
assert_file_exists "restarting peer: restart wrote cooldown state" \
  "$NEXT_RESTART_FILE"

# A caller that already had noglob on must keep it.
FAKE_CLASS=direct
reset_case
set -f
set +u
check_all_peers 2> "${tmpdir}/stderr.caller"
set -u
after="$(has_f)"
set +f
assert_eq "caller noglob stays on after check_all_peers" "set" "$after"
assert_eq "caller noglob: nothing written to stderr" "" \
  "$(cat "${tmpdir}/stderr.caller")"

FAKE_CLASS=relayed
reset_case
set -f
set +u
check_all_peers 2> "${tmpdir}/stderr.caller_relayed"
set -u
after="$(has_f)"
set +f
assert_eq "caller noglob stays on across a restart" "set" "$after"
assert_eq "caller noglob across a restart: nothing written to stderr" "" \
  "$(cat "${tmpdir}/stderr.caller_relayed")"

assert_eq "no unexpected tailscale, curl, or netstat call" \
  "missing" "$([ -f "$UNEXPECTED_LOG" ] && cat "$UNEXPECTED_LOG" || printf 'missing')"
