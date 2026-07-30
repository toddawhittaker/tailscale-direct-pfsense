#!/bin/sh

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

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
exit 0
EOF

cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
printf 'curl called\n' >> "$CURL_LOG"
exit 0
EOF

cat > "${fakebin}/tailscale" <<'EOF'
#!/bin/sh
cat "$FAKE_TAILSCALE_OUTPUT"
exit "${FAKE_TAILSCALE_RC:-0}"
EOF

# Guards, not behavior.  Restart deferral is disabled below, so neither of
# these should ever run; they exist so that a regression which re-enables
# deferral is caught by an assertion instead of silently reaching the host's
# real interface counters and sleeping for 30 seconds at a time.
cat > "${fakebin}/netstat" <<'EOF'
#!/bin/sh
printf 'netstat %s\n' "$*" >> "$HOST_TOOL_LOG"
exit 1
EOF

cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$*" >> "$HOST_TOOL_LOG"
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/date" "${fakebin}/service" \
  "${fakebin}/curl" "${fakebin}/tailscale" "${fakebin}/netstat" \
  "${fakebin}/sleep"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

PEERS="router1 router2"
FAIL_THRESHOLD=2
PING_COUNT=5
RESTART_SERVICES="tailscaled pfsense_tailscaled"
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service.log"
CURL_LOG="${tmpdir}/curl.log"
LOGGER_LOG="${tmpdir}/logger.log"
HOST_TOOL_LOG="${tmpdir}/host-tools.log"
export SERVICE_LOG CURL_LOG LOGGER_LOG HOST_TOOL_LOG

# This file covers peer state transitions and global cooldown, not restart
# deferral; test_restart_deferral.sh owns that.  At the daemon default of 1,
# crossing the threshold below would send should_defer_restart to
# get_interface_bytes -> netstat -ibn -I tailscale0 and then sleep for
# RESTART_DEFERRAL_CHECK_SECONDS, making this file's result depend on the
# host's live interface counters.  On a machine where tailscale0 carries
# traffic the restart assertions would flip.
RESTART_DEFERRAL_ENABLED=0
TEST=1
DEBUG=0
PUSHOVER_TOKEN=""
PUSHOVER_USER=""

set_peer_attr count router1 0
set_peer_attr state router1 unknown
set_peer_attr threshold_seen router1 none
handle_relayed router1
assert_eq "relayed increments counter" "1" "$(get_peer_attr count router1 unset)"
assert_eq "relayed marks state" "relayed" "$(get_peer_attr state router1 unset)"

handle_relayed router1
assert_eq "test mode threshold keeps counter" "2" "$(get_peer_attr count router1 unset)"
assert_eq "test mode records threshold seen" "test" "$(get_peer_attr threshold_seen router1 unset)"
assert_eq "test mode does not call service" "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_contains "test mode logs restart decision summary" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart decision: peer=router1 count=2/2 cooldown=not_checked deferral=not_checked action=test"

handle_direct router1
assert_eq "direct resets relay counter" "0" "$(get_peer_attr count router1 unset)"
assert_eq "direct marks state" "direct" "$(get_peer_attr state router1 unset)"
assert_eq "direct clears threshold marker" "none" "$(get_peer_attr threshold_seen router1 unset)"

set_peer_attr count router1 3
set_peer_attr state router1 relayed
set_peer_attr threshold_seen router1 test
handle_unknown router1
assert_eq "unknown breaks relay sequence" "0" "$(get_peer_attr count router1 unset)"
assert_eq "unknown marks state" "unknown" "$(get_peer_attr state router1 unset)"
assert_eq "unknown clears threshold marker" "none" "$(get_peer_attr threshold_seen router1 unset)"

TEST=0
LOGGER_LOG="${tmpdir}/logger-cooldown.log"
export LOGGER_LOG
mkdir -p "$STATE_DIR" || exit 1
printf '%s\n' 100500 > "$NEXT_RESTART_FILE"
PUSHOVER_TOKEN="test-token"
PUSHOVER_USER="test-user"
set_peer_attr count router2 1
set_peer_attr state router2 relayed
set_peer_attr threshold_seen router2 none
handle_relayed router2
assert_eq "cooldown threshold keeps counter" "2" "$(get_peer_attr count router2 unset)"
assert_eq "cooldown threshold marker is recorded" "cooldown" "$(get_peer_attr threshold_seen router2 unset)"
assert_eq "cooldown suppresses service call" "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_eq "cooldown suppresses Pushover notification" \
  "missing" "$([ -f "$CURL_LOG" ] && cat "$CURL_LOG" || printf 'missing')"
assert_contains "cooldown logs restart decision summary" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart decision: peer=router2 count=2/2 cooldown=blocked remaining=500s deferral=not_checked action=suppress"

PUSHOVER_TOKEN=""
PUSHOVER_USER=""
rm -rf "$STATE_DIR"
SERVICE_LOG="${tmpdir}/service-global-first.log"
export SERVICE_LOG
set_peer_attr count router1 1
set_peer_attr state router1 relayed
set_peer_attr threshold_seen router1 none
handle_relayed router1
service_log="$(cat "$SERVICE_LOG" 2>/dev/null)"
assert_contains "first peer threshold restarts service" \
  "$service_log" "tailscaled restart"
assert_file_exists "first peer restart writes global cooldown" "$NEXT_RESTART_FILE"

SERVICE_LOG="${tmpdir}/service-global-second.log"
export SERVICE_LOG
set_peer_attr count router2 1
set_peer_attr state router2 relayed
set_peer_attr threshold_seen router2 none
handle_relayed router2
assert_eq "global cooldown suppresses second peer back-to-back restart" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_eq "second peer records cooldown suppression" \
  "cooldown" "$(get_peer_attr threshold_seen router2 unset)"

FAKE_TAILSCALE_OUTPUT="${SCRIPT_DIR}/fixtures/ping_mixed_direct.txt"
FAKE_TAILSCALE_RC=1
export FAKE_TAILSCALE_OUTPUT FAKE_TAILSCALE_RC
assert_eq "check_peer_path classifies output even when tailscale exits nonzero" \
  "direct" "$(check_peer_path router1)"

FAKE_TAILSCALE_OUTPUT="${SCRIPT_DIR}/fixtures/ping_unknown.txt"
FAKE_TAILSCALE_RC=1
export FAKE_TAILSCALE_OUTPUT FAKE_TAILSCALE_RC
assert_eq "check_peer_path returns unknown for unparseable output" \
  "unknown" "$(check_peer_path router1)"

# Proves the guarantee rather than assuming it: nothing in this file reached
# the host's interface counters or slept.
assert_eq "no netstat or sleep was invoked" \
  "missing" "$([ -f "$HOST_TOOL_LOG" ] && cat "$HOST_TOOL_LOG" || printf 'missing')"
