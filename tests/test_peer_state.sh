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

cat > "${fakebin}/tailscale" <<'EOF'
#!/bin/sh
cat "$FAKE_TAILSCALE_OUTPUT"
exit "${FAKE_TAILSCALE_RC:-0}"
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/date" "${fakebin}/service" "${fakebin}/tailscale"

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
export SERVICE_LOG
TEST=1
DEBUG=0

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
mkdir -p "$STATE_DIR" || exit 1
printf '%s\n' 100500 > "$NEXT_RESTART_FILE"
set_peer_attr count router2 1
set_peer_attr state router2 relayed
set_peer_attr threshold_seen router2 none
handle_relayed router2
assert_eq "cooldown threshold keeps counter" "2" "$(get_peer_attr count router2 unset)"
assert_eq "cooldown threshold marker is recorded" "cooldown" "$(get_peer_attr threshold_seen router2 unset)"
assert_eq "cooldown suppresses service call" "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"

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
