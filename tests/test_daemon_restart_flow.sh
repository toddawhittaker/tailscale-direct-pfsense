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

cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
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

# Records the settle pause instead of actually sleeping, so the suite stays fast
# and can assert that the pause happened between the stop and the start.
cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf 'sleep %s\n' "$1" >> "$SERVICE_LOG"
exit 0
EOF

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
if [ "${REQUIRE_COOLDOWN_BEFORE_SERVICE:-0}" -eq 1 ] && [ ! -f "$NEXT_RESTART_FILE" ]; then
  printf 'missing cooldown before service\n' >> "$SERVICE_LOG"
  exit 2
fi
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
# SERVICE_STOP_FAIL exercises the pfSense case where the stop reports failure
# because the daemon is already down; only the start decides the outcome.
if [ "${SERVICE_STOP_FAIL:-0}" -eq 1 ] && [ "$2" = "stop" ]; then
  exit 1
fi
case "$SERVICE_FAIL" in
  1)
    exit 1
    ;;
esac
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/curl" "${fakebin}/date" \
  "${fakebin}/jot" "${fakebin}/service" "${fakebin}/sleep"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

SERVICE_LOG="${tmpdir}/service.log"
LOGGER_LOG="${tmpdir}/logger.log"
SERVICE_FAIL=0
SERVICE_STOP_FAIL=0
REQUIRE_COOLDOWN_BEFORE_SERVICE=1
export SERVICE_LOG LOGGER_LOG SERVICE_FAIL SERVICE_STOP_FAIL \
  REQUIRE_COOLDOWN_BEFORE_SERVICE

STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
export NEXT_RESTART_FILE
PEERS="router1 router2"
RESTART_SERVICES="pfsense_tailscaled"
RESTART_SETTLE_SECONDS=3
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
TEST=0
DEBUG=0

set_peer_attr count router1 5
set_peer_attr state router1 relayed
set_peer_attr count router2 3
set_peer_attr state router2 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "successful restart flow returns success" "0" "$rc"

assert_eq "successful restart resets router1 counter" \
  "0" "$(get_peer_attr count router1 unset)"
assert_eq "successful restart resets router2 counter" \
  "0" "$(get_peer_attr count router2 unset)"
assert_eq "successful restart marks router1 post_restart" \
  "post_restart" "$(get_peer_attr state router1 unset)"
assert_file_exists "restart writes cooldown state" "$NEXT_RESTART_FILE"

service_log="$(cat "$SERVICE_LOG" 2>/dev/null)"
# Stop, settle, start -- as separate invocations, matching the pfSense GUI's
# service control.  A plain "service ... restart" gives the rc.d post-start hook
# no time for tailscale0 to go away before it waits for it to return.
assert_eq "restart flow stops, settles, then starts" \
  "$(printf 'pfsense_tailscaled stop\nsleep 3\npfsense_tailscaled start')" \
  "$service_log"
assert_not_contains "restart flow does not use the restart verb" \
  "$service_log" "pfsense_tailscaled restart"
# No separate assertion that tailscaled is not bounced on its own: any needle
# built from "tailscaled ..." also matches inside "pfsense_tailscaled ...", so
# such a check would pass vacuously.  The exact-match assertion above already
# proves the log holds nothing but the three expected lines.
assert_not_contains "service was not called before cooldown write" \
  "$service_log" "missing cooldown before service"
logger_log="$(cat "$LOGGER_LOG" 2>/dev/null)"
assert_contains "restart flow logs selected cooldown" \
  "$logger_log" "Restart cooldown selected: cooldown=900s next_allowed_epoch=100900 range=(min=900s,max=900s)"

SERVICE_FAIL=1
export SERVICE_FAIL
SERVICE_LOG="${tmpdir}/service-fail.log"
LOGGER_LOG="${tmpdir}/logger-fail.log"
export SERVICE_LOG
export LOGGER_LOG

set_peer_attr count router1 5
set_peer_attr state router1 relayed
set_peer_attr count router2 3
set_peer_attr state router2 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "failed restart flow returns failure" "1" "$rc"
assert_eq "failed restart preserves router1 counter" \
  "5" "$(get_peer_attr count router1 unset)"
assert_eq "failed restart preserves router2 counter" \
  "3" "$(get_peer_attr count router2 unset)"
assert_contains "failed restart logs selected cooldown" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart cooldown selected: cooldown=900s"

# A failing stop must not fail the restart.  The pfSense GUI skips the stop
# entirely when the service is not running, and pfsense_tailscaled's stop
# returns non-zero when tailscaled is already down.  Only the start decides.
SERVICE_FAIL=0
SERVICE_STOP_FAIL=1
export SERVICE_FAIL SERVICE_STOP_FAIL
SERVICE_LOG="${tmpdir}/stop-fail.log"
LOGGER_LOG="${tmpdir}/logger-stop-fail.log"
export SERVICE_LOG LOGGER_LOG

set_peer_attr count router1 5
set_peer_attr state router1 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "failing stop does not fail the restart" "0" "$rc"
assert_eq "failing stop still resets counters" \
  "0" "$(get_peer_attr count router1 unset)"
assert_contains "failing stop still runs the start" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "pfsense_tailscaled start"

# A zero settle skips the pause entirely rather than calling sleep 0.
SERVICE_STOP_FAIL=0
export SERVICE_STOP_FAIL
RESTART_SETTLE_SECONDS=0
SERVICE_LOG="${tmpdir}/no-settle.log"
LOGGER_LOG="${tmpdir}/logger-no-settle.log"
export SERVICE_LOG LOGGER_LOG

set_peer_attr count router1 5
set_peer_attr state router1 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
assert_eq "zero settle stops and starts with no pause" \
  "$(printf 'pfsense_tailscaled stop\npfsense_tailscaled start')" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)"

RESTART_SETTLE_SECONDS=3
SERVICE_FAIL=0
export SERVICE_FAIL
SERVICE_LOG="${tmpdir}/cooldown-write-fail.log"
LOGGER_LOG="${tmpdir}/logger-cooldown-write-fail.log"
export SERVICE_LOG
export LOGGER_LOG
rm -rf "$STATE_DIR"
ln -s "${tmpdir}/elsewhere" "$STATE_DIR"

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "cooldown write failure blocks restart flow" "1" "$rc"
assert_eq "cooldown write failure does not call service" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
