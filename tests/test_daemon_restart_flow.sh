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

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
if [ "${REQUIRE_COOLDOWN_BEFORE_SERVICE:-0}" -eq 1 ] && [ ! -f "$NEXT_RESTART_FILE" ]; then
  printf 'missing cooldown before service\n' >> "$SERVICE_LOG"
  exit 2
fi
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
case "$SERVICE_FAIL" in
  1)
    exit 1
    ;;
esac
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/curl" "${fakebin}/date" \
  "${fakebin}/jot" "${fakebin}/service"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

SERVICE_LOG="${tmpdir}/service.log"
SERVICE_FAIL=0
REQUIRE_COOLDOWN_BEFORE_SERVICE=1
export SERVICE_LOG SERVICE_FAIL REQUIRE_COOLDOWN_BEFORE_SERVICE

STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
export NEXT_RESTART_FILE
PEERS="router1 router2"
RESTART_SERVICES="tailscaled pfsense_tailscaled"
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
assert_contains "restart flow restarts tailscaled" "$service_log" "tailscaled restart"
assert_contains "restart flow restarts pfsense_tailscaled" "$service_log" "pfsense_tailscaled restart"
assert_not_contains "service was not called before cooldown write" \
  "$service_log" "missing cooldown before service"

SERVICE_FAIL=1
export SERVICE_FAIL
SERVICE_LOG="${tmpdir}/service-fail.log"
export SERVICE_LOG

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

SERVICE_FAIL=0
export SERVICE_FAIL
SERVICE_LOG="${tmpdir}/cooldown-write-fail.log"
export SERVICE_LOG
rm -rf "$STATE_DIR"
ln -s "${tmpdir}/elsewhere" "$STATE_DIR"

restart_tailscale_services router1 5 >/dev/null 2>&1
rc=$?
assert_eq "cooldown write failure blocks restart flow" "1" "$rc"
assert_eq "cooldown write failure does not call service" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
