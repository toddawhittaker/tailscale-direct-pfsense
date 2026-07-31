#!/bin/sh
#
# Runtime state path handling.
#
# STATE_DIR and NEXT_RESTART_FILE used to sit in the config-defaults block with
# NEXT_RESTART_FILE expanded once from STATE_DIR.  The live config is sourced
# into that same namespace, so a config assigning only STATE_DIR moved the
# directory and not the file: mark_restart_attempt then created and mktemp'd
# under the new directory and mv'd into the old one, which had never been
# created.  The write failed, restart_tailscale_services returned before
# touching any service, and the watchdog silently stopped restarting anything
# for the life of the install.
#
# These tests cover the two halves of the fix -- the pair is re-derived
# together in reset_runtime_state, and a config that assigned either one is
# told the value was ignored -- plus the failure the split itself produced.

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

# Records only the message, not the `-t TAG` prefix, so the warning tests can
# assert exact log lines rather than substrings that prose could satisfy.
# An invocation in any other shape is recorded and fails rather than being
# quietly discarded.
cat > "${fakebin}/logger" <<'EOF'
#!/bin/sh
if [ "$#" -lt 3 ] || [ "$1" != "-t" ]; then
  printf 'unexpected logger invocation: %s\n' "$*" >> "$LOGGER_LOG"
  exit 1
fi
shift 2
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

# Pins the random cooldown to a value the MIN fallback would not produce, so a
# broken or unused stub shows up as a wrong stored epoch instead of passing.
cat > "${fakebin}/jot" <<'EOF'
#!/bin/sh
printf '%s\n' 1234
EOF

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
exit 0
EOF

# Nothing in these paths should sleep; record it rather than stall the suite.
cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf 'unexpected sleep %s\n' "$1" >> "$SERVICE_LOG"
exit 0
EOF

# Neither path should reach the network or the local Tailscale daemon.  Both
# fail loudly so an accidental call cannot be mistaken for a clean run.
cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
printf 'unexpected curl invocation\n' >> "$LOGGER_LOG"
exit 1
EOF

cat > "${fakebin}/tailscale" <<'EOF'
#!/bin/sh
printf 'unexpected tailscale invocation: %s\n' "$*" >> "$LOGGER_LOG"
exit 1
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/date" "${fakebin}/jot" \
  "${fakebin}/service" "${fakebin}/sleep" "${fakebin}/curl" \
  "${fakebin}/tailscale"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

LOGGER_LOG="${tmpdir}/logger.log"
SERVICE_LOG="${tmpdir}/service.log"
export LOGGER_LOG SERVICE_LOG

fixed_state_dir="/var/run/tailscale_watchdog"
fixed_next_restart_file="/var/run/tailscale_watchdog/next_restart_allowed"
docs_url="https://github.com/toddawhittaker/tailscale-direct-pfsense"

# ---- reset_runtime_state re-derives the pair --------------------------------
#
# Stands in for a live config that assigned both, and for one that assigned
# only STATE_DIR: either way both globals must come back fixed and consistent.

STATE_DIR="${tmpdir}/config-chosen-state"
NEXT_RESTART_FILE="${tmpdir}/config-chosen-elsewhere/next_restart_allowed"
reset_runtime_state

assert_eq "reset_runtime_state discards a config STATE_DIR" \
  "$fixed_state_dir" "$STATE_DIR"
assert_eq "reset_runtime_state discards a config NEXT_RESTART_FILE" \
  "$fixed_next_restart_file" "$NEXT_RESTART_FILE"

STATE_DIR="${tmpdir}/config-chosen-state"
reset_runtime_state

assert_eq "a config assigning only STATE_DIR leaves the fixed state directory" \
  "$fixed_state_dir" "$STATE_DIR"
assert_eq "the cooldown state file stays inside the state directory" \
  "${STATE_DIR}/next_restart_allowed" "$NEXT_RESTART_FILE"

# ---- consistent state paths write cooldown and restart ----------------------

RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
PEERS="router1 router2"
RESTART_SERVICES="pfsense_tailscaled"
RESTART_SETTLE_SECONDS=0
NOTIFY_PROVIDER="pushover"
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
SERVICE_OUTPUT_TEMPLATE="${tmpdir}/service-output.XXXXXX"

STATE_DIR="${tmpdir}/consistent"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"

assert_success "mark_restart_attempt succeeds when the state paths agree" \
  mark_restart_attempt
assert_eq "consistent state paths store the next allowed epoch" \
  "101234" "$(cat "$NEXT_RESTART_FILE" 2>/dev/null)"

set_peer_attr count router1 5
set_peer_attr state router1 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "consistent state paths let the restart flow succeed" "0" "$rc"
# The control for the split-path assertion below: it proves the fake service is
# on PATH and does log, so an empty log there means the daemon never called it.
assert_eq "consistent state paths stop and start the configured service" \
  "$(printf 'pfsense_tailscaled stop\npfsense_tailscaled start')" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)"

# ---- split state paths reproduce the regression -----------------------------
#
# STATE_DIR is created and written under, NEXT_RESTART_FILE is somewhere that
# does not exist -- exactly the shape a config assigning only STATE_DIR used to
# produce.  The cooldown write fails and the restart is abandoned before any
# service command runs.

LOGGER_LOG="${tmpdir}/logger-split.log"
SERVICE_LOG="${tmpdir}/service-split.log"
export LOGGER_LOG SERVICE_LOG

STATE_DIR="${tmpdir}/split-state"
NEXT_RESTART_FILE="${tmpdir}/split-never-created/next_restart_allowed"

assert_eq "mark_restart_attempt fails when the cooldown file is outside the state directory" \
  "1" "$(mark_restart_attempt >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "a failed cooldown write leaves no cooldown state behind" \
  "missing" "$([ -f "$NEXT_RESTART_FILE" ] && printf 'present' || printf 'missing')"
assert_eq "a failed cooldown write leaves no temp file in the state directory" \
  "0" "$(find "$STATE_DIR" -name '.next_restart_allowed.*' | wc -l | tr -d ' ')"

set_peer_attr count router1 5
set_peer_attr state router1 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "split state paths make the restart flow fail" "1" "$rc"
assert_eq "split state paths suppress the restart before any service command" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_eq "split state paths preserve the peer counter for a later retry" \
  "5" "$(get_peer_attr count router1 unset)"
assert_contains "split state paths log why the restart was suppressed" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" \
  "Restart suppressed: could not write restart cooldown state"

# ---- ignored config state paths are reported --------------------------------
#
# Same order main uses: reset, then report what the reset discarded.  The whole
# log is compared, so a warning that fires for the wrong argument or fires
# twice fails as loudly as one that never fires.

reset_runtime_state

LOGGER_LOG="${tmpdir}/logger-warn-state-dir.log"
export LOGGER_LOG
warn_ignored_state_paths "/var/db/tailscale_watchdog" "$fixed_next_restart_file"
assert_eq "a config STATE_DIR is reported as ignored" \
  "Ignoring STATE_DIR from the config (/var/db/tailscale_watchdog). The runtime state directory is fixed at ${fixed_state_dir}; the uninstaller removes only that path. See ${docs_url}" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)"

LOGGER_LOG="${tmpdir}/logger-warn-next-file.log"
export LOGGER_LOG
warn_ignored_state_paths "$fixed_state_dir" "/var/db/next_restart_allowed"
assert_eq "a config NEXT_RESTART_FILE is reported as ignored" \
  "Ignoring NEXT_RESTART_FILE from the config (/var/db/next_restart_allowed). The cooldown state file is fixed at ${fixed_next_restart_file}. See ${docs_url}" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)"

LOGGER_LOG="${tmpdir}/logger-warn-matching.log"
export LOGGER_LOG
warn_ignored_state_paths "$fixed_state_dir" "$fixed_next_restart_file"
assert_eq "state paths matching the fixed values are not reported" \
  "" "$(cat "$LOGGER_LOG" 2>/dev/null)"

LOGGER_LOG="${tmpdir}/logger-warn-empty.log"
export LOGGER_LOG
warn_ignored_state_paths "" ""
assert_eq "unset state paths are not reported" \
  "" "$(cat "$LOGGER_LOG" 2>/dev/null)"

# ---- end to end through main ------------------------------------------------
#
# Everything above calls functions directly, which leaves main's own wiring --
# capture the config values, reset, then report -- unprotected.  Two changes to
# main keep every assertion above green: deleting the warn_ignored_state_paths
# call, and moving it ahead of reset_runtime_state.  The second is the
# dangerous one.  Called before the reset, the function compares the config's
# STATE_DIR against a global that still holds the config's STATE_DIR, so the
# warning is unreachable and the silent ignore this whole change exists to
# remove is back, in code that still reads as though it warns.
#
# Fakes here are shell functions, not files on a temporary PATH, which is a
# departure from the rest of the suite and is forced by the daemon: it hardens
# PATH at the top of the file and load_config_file hardens it again after
# sourcing the config, so a temporary PATH is gone before main runs a single
# command.  Functions are found ahead of any PATH lookup and survive both.
# Nothing is written to a real system path -- mkdir and service are refused
# outright, so a gate that stops working fails an assertion instead.

e2e_dir="${tmpdir}/e2e"
e2e_cfg_state_dir="${e2e_dir}/config-state"

# Recorded as a failure rather than a bare `exit 1`.  finish_tests runs on EXIT
# and sets the status itself, so an exit here with assertions already passed and
# none failed would still report success -- the same shape of silent pass that
# the zero-assertion guard in testlib.sh exists to close.
mkdir -p "$e2e_cfg_state_dir" || {
  test_not_ok "end-to-end setup: could not create ${e2e_cfg_state_dir}"
  exit 1
}

# An active cooldown, planted where a config-honoured STATE_DIR would find it.
# Reading it is the visible symptom of the config value surviving the reset:
# the run below is arranged to reach the cooldown check, and must not see this.
printf '%s\n' 100500 > "${e2e_cfg_state_dir}/next_restart_allowed"

# One relayed peer, threshold 1, busy interface: the run reaches the cooldown
# check and then stops at the deferral gate, without restarting anything or
# writing state anywhere.
cat > "${e2e_dir}/watchdog.conf" <<EOF
PEERS="router1"
CHECK_INTERVAL=60
FAIL_THRESHOLD=1
PING_COUNT=1
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
RESTART_SERVICES="pfsense_tailscaled"
RESTART_SETTLE_SECONDS=0
RESTART_DEFERRAL_ENABLED=1
RESTART_DEFERRAL_INTERFACE="tailscale0"
RESTART_DEFERRAL_CHECK_SECONDS=1
RESTART_DEFERRAL_MAX_BYTES=1
RESTART_DEFERRAL_MAX_ATTEMPTS=10
NOTIFY_PROVIDER="none"
NOTIFY_ON_STARTUP=0
STATE_DIR="${e2e_cfg_state_dir}"
EOF

cat > "${e2e_dir}/run.sh" <<'EOF'
#!/bin/sh
#
# Runs the daemon's real entrypoint sequence in a child process.  The guard at
# the bottom of the daemon skips the main call; everything else, including the
# top-level reset_runtime_state, runs exactly as it does in production.

set -u

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "$DAEMON"

logger() {
  if [ "$#" -lt 3 ] || [ "$1" != "-t" ]; then
    printf 'unexpected logger invocation: %s\n' "$*" >> "$GUARD_LOG"
    return 1
  fi
  shift 2
  printf '%s\n' "$*" >> "$LOGGER_LOG"
}

# config_is_safe_to_source requires a root-owned 0600 file, which a test cannot
# create.  Only the two queries it makes are answered; anything else is a
# change in how the config is vetted and must not pass silently.
stat() {
  case "${1:-} ${2:-}" in
    '-f %Su')
      printf 'root\n'
      ;;
    '-f %Lp')
      printf '600\n'
      ;;
    *)
      printf 'unexpected stat invocation: %s\n' "$*" >> "$GUARD_LOG"
      return 1
      ;;
  esac
}

date() {
  if [ "${1:-}" = '+%s' ]; then
    printf '100000\n'
    return 0
  fi
  printf 'unexpected date invocation: %s\n' "$*" >> "$GUARD_LOG"
  return 1
}

tailscale() {
  case "$*" in
    'ping -c 1 router1')
      printf 'pong from router1 (100.64.0.2) via DERP(nyc) in 31ms\n'
      ;;
    *)
      printf 'unexpected tailscale invocation: %s\n' "$*" >> "$GUARD_LOG"
      return 1
      ;;
  esac
}

# Two samples a long way apart, so the deferral gate sees a busy interface.
netstat() {
  _count=0
  if [ -f "$NETSTAT_COUNT" ]; then
    read -r _count < "$NETSTAT_COUNT"
  fi
  _count=$((_count + 1))
  printf '%s\n' "$_count" > "$NETSTAT_COUNT"
  printf 'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll\n'
  printf 'tailscale0 1280 link address 1 0 0 %s 1 0 %s 0\n' \
    "$((_count * 500000))" "$((_count * 500000))"
}

sleep() {
  :
}

# Nothing in this run may restart a service or create a state directory.  Both
# refuse and record rather than succeed, so this test cannot touch the live
# system even if a gate above it stops working.
service() {
  printf 'service %s\n' "$*" >> "$GUARD_LOG"
  return 1
}

mkdir() {
  printf 'mkdir %s\n' "$*" >> "$GUARD_LOG"
  return 1
}

main "$@"
EOF

DAEMON="${REPO_ROOT}/tailscale_watchdogd"
LOGGER_LOG="${e2e_dir}/logger.log"
GUARD_LOG="${e2e_dir}/guard.log"
NETSTAT_COUNT="${e2e_dir}/netstat-count"
export DAEMON LOGGER_LOG GUARD_LOG NETSTAT_COUNT

sh "${e2e_dir}/run.sh" -1 -f "${e2e_dir}/watchdog.conf" \
  > "${e2e_dir}/stdout" 2>&1
rc=$?

assert_eq "a one-shot run with a config that assigns STATE_DIR completes" \
  "0" "$rc"
assert_eq "a one-shot run reports the STATE_DIR its config assigned" \
  "Ignoring STATE_DIR from the config (${e2e_cfg_state_dir}). The runtime state directory is fixed at ${fixed_state_dir}; the uninstaller removes only that path. See ${docs_url}" \
  "$(grep '^Ignoring ' "$LOGGER_LOG" 2>/dev/null)"
# The whole restart decision, not a fragment: under the old behavior this line
# reads cooldown=blocked remaining=500s, because the cooldown planted in the
# config's directory was found.
assert_eq "a one-shot run does not read cooldown state from the config's directory" \
  "Restart decision: peer=router1 count=1/1 cooldown=allowed deferral=busy attempts=1/10 delta=1000000 action=defer" \
  "$(grep '^Restart decision: ' "$LOGGER_LOG" 2>/dev/null)"
assert_not_contains "the cooldown planted in the config's directory has no effect" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "restart is suppressed by cooldown"
assert_eq "a one-shot run creates no state directory and runs no service command" \
  "missing" "$([ -f "$GUARD_LOG" ] && cat "$GUARD_LOG" || printf 'missing')"
