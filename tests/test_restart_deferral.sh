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

cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf '%s\n' "$1" >> "$SLEEP_LOG"
exit 0
EOF

cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
exit 0
EOF

cat > "${fakebin}/netstat" <<'EOF'
#!/bin/sh
count=0
if [ -f "$NETSTAT_COUNT_FILE" ]; then
  count="$(cat "$NETSTAT_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$NETSTAT_COUNT_FILE"
printf '%s %s\n' "$NETSTAT_MODE" "$*" >> "$NETSTAT_LOG"

case "$NETSTAT_MODE" in
  quiet)
    if [ "$count" -eq 1 ]; then
      ibytes=1000
      obytes=1000
    else
      ibytes=1010
      obytes=1010
    fi
    ;;
  active)
    if [ "$count" -eq 1 ]; then
      ibytes=1000
      obytes=1000
    else
      ibytes=50000
      obytes=50000
    fi
    ;;
  backward)
    if [ "$count" -eq 1 ]; then
      ibytes=2000
      obytes=2000
    else
      ibytes=1000
      obytes=1000
    fi
    ;;
  malformed)
    printf 'Name Mtu Network Address Ipkts\n'
    printf 'tailscale0 1280 link address 1\n'
    exit 0
    ;;
  missing)
    printf 'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll\n'
    printf 'lo0 16384 link address 1 0 0 1000 1 0 1000 0\n'
    exit 0
    ;;
  second_fails)
    # The first sample succeeds and only the second one fails.  The malformed
    # and missing modes above fail on every call, so should_defer_restart
    # always returns at the first sample and the second sample's failure
    # branch is never reached.  This mode is the only way to exercise it.
    if [ "$count" -ge 2 ]; then
      printf 'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll\n'
      printf 'lo0 16384 link address 1 0 0 1000 1 0 1000 0\n'
      exit 0
    fi
    ibytes=1000
    obytes=1000
    ;;
esac

printf 'Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll\n'
printf 'tailscale0 1280 link address 1 0 0 %s 1 0 %s 0\n' "$ibytes" "$obytes"
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/curl" "${fakebin}/date" \
  "${fakebin}/jot" "${fakebin}/sleep" "${fakebin}/service" \
  "${fakebin}/netstat"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

PEERS="router1 router2"
FAIL_THRESHOLD=2
PING_COUNT=5
RESTART_SERVICES="tailscaled pfsense_tailscaled"
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
RESTART_DEFERRAL_ENABLED=1
RESTART_DEFERRAL_INTERFACE="tailscale0"
RESTART_DEFERRAL_CHECK_SECONDS=30
RESTART_DEFERRAL_MAX_BYTES=65536
RESTART_DEFERRAL_MAX_ATTEMPTS=2
RESTART_DEFERRAL_ATTEMPTS=0
STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service.log"
LOGGER_LOG="${tmpdir}/logger.log"
SLEEP_LOG="${tmpdir}/sleep.log"
NETSTAT_LOG="${tmpdir}/netstat.log"
NETSTAT_COUNT_FILE="${tmpdir}/netstat-count"
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
TEST=0
DEBUG=0
export SERVICE_LOG LOGGER_LOG SLEEP_LOG NETSTAT_LOG NETSTAT_COUNT_FILE NETSTAT_MODE

reset_fake_netstat() {
  NETSTAT_MODE="$1"
  export NETSTAT_MODE
  rm -f "$NETSTAT_COUNT_FILE" "$NETSTAT_LOG" "$SLEEP_LOG"
}

reset_restart_state() {
  rm -rf "$STATE_DIR"
  rm -f "$SERVICE_LOG" "$LOGGER_LOG"
  RESTART_DEFERRAL_ATTEMPTS=0
  set_peer_attr count router1 1
  set_peer_attr state router1 relayed
  set_peer_attr threshold_seen router1 none
}

parse_sample='Name Mtu Network Address Ipkts Ierrs Idrop Ibytes Opkts Oerrs Obytes Coll
tailscale0 1280 link address 1 0 0 100 1 0 200 0'
assert_eq "interface byte parser reads received and sent bytes" \
  "300" "$(printf '%s\n' "$parse_sample" | parse_interface_bytes tailscale0)"

reset_restart_state
reset_fake_netstat active
handle_relayed router1
assert_eq "active traffic defers restart" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_eq "active traffic does not write cooldown state" \
  "missing" "$([ -f "$NEXT_RESTART_FILE" ] && cat "$NEXT_RESTART_FILE" || printf 'missing')"
assert_eq "active traffic increments global deferral attempts" \
  "1" "$RESTART_DEFERRAL_ATTEMPTS"
assert_contains "active traffic logs defer decision summary" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart decision: peer=router1 count=2/2 cooldown=allowed deferral=busy attempts=1/2"
assert_eq "deferral samples over configured interval" \
  "30" "$(cat "$SLEEP_LOG")"
assert_contains "deferral samples configured interface" \
  "$(cat "$NETSTAT_LOG")" "active -ibn -I tailscale0"

reset_fake_netstat quiet
SERVICE_LOG="${tmpdir}/service-quiet.log"
LOGGER_LOG="${tmpdir}/logger-quiet.log"
export SERVICE_LOG
export LOGGER_LOG
handle_relayed router1
assert_contains "quiet traffic allows restart" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "tailscaled restart"
assert_file_exists "quiet traffic writes cooldown state" "$NEXT_RESTART_FILE"
assert_eq "quiet traffic resets deferral attempts" \
  "0" "$RESTART_DEFERRAL_ATTEMPTS"
logger_log="$(cat "$LOGGER_LOG" 2>/dev/null)"
assert_contains "quiet traffic logs selected cooldown" \
  "$logger_log" "Restart cooldown selected: cooldown=900s next_allowed_epoch=100900 range=(min=900s,max=900s)"
assert_contains "quiet traffic logs restart decision summary" \
  "$logger_log" "Restart decision: peer=router1 count=3/2 cooldown=selected selected=900s next_allowed_epoch=100900 deferral=quiet action=restart"

reset_restart_state
mkdir -p "$STATE_DIR" || exit 1
printf '%s\n' 100500 > "$NEXT_RESTART_FILE"
reset_fake_netstat active
SERVICE_LOG="${tmpdir}/service-cooldown.log"
LOGGER_LOG="${tmpdir}/logger-cooldown.log"
export SERVICE_LOG
export LOGGER_LOG
handle_relayed router1
assert_eq "cooldown suppresses restart before deferral" \
  "missing" "$([ -f "$SERVICE_LOG" ] && cat "$SERVICE_LOG" || printf 'missing')"
assert_eq "cooldown suppresses activity sampling" \
  "missing" "$([ -f "$NETSTAT_LOG" ] && cat "$NETSTAT_LOG" || printf 'missing')"
assert_contains "cooldown logs suppress decision summary" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart decision: peer=router1 count=2/2 cooldown=blocked remaining=500s deferral=not_checked action=suppress"

reset_restart_state
reset_fake_netstat malformed
SERVICE_LOG="${tmpdir}/service-malformed.log"
LOGGER_LOG="${tmpdir}/logger-malformed.log"
export SERVICE_LOG
export LOGGER_LOG
handle_relayed router1
assert_contains "malformed activity output proceeds with restart" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "tailscaled restart"
assert_file_exists "malformed activity output writes cooldown state" "$NEXT_RESTART_FILE"

reset_restart_state
reset_fake_netstat missing
SERVICE_LOG="${tmpdir}/service-missing.log"
LOGGER_LOG="${tmpdir}/logger-missing.log"
export SERVICE_LOG
export LOGGER_LOG
handle_relayed router1
assert_contains "missing interface proceeds with restart" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "tailscaled restart"

reset_restart_state
reset_fake_netstat second_fails
SERVICE_LOG="${tmpdir}/service-second-fails.log"
LOGGER_LOG="${tmpdir}/logger-second-fails.log"
export SERVICE_LOG
export LOGGER_LOG
handle_relayed router1
assert_contains "failure on the second activity sample proceeds with restart" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "tailscaled restart"
assert_file_exists "failure on the second activity sample writes cooldown state" \
  "$NEXT_RESTART_FILE"
assert_contains "failure on the second activity sample logs the check failure" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Restart deferral activity check failed for interface tailscale0"
# Proves the first sample really did succeed, so this exercised the second
# sample's failure branch rather than repeating the first sample's.
assert_eq "second sample failure sampled the interface twice" \
  "2" "$(cat "$NETSTAT_COUNT_FILE" 2>/dev/null)"

reset_restart_state
reset_fake_netstat active
SERVICE_LOG="${tmpdir}/service-limit.log"
LOGGER_LOG="${tmpdir}/logger-limit.log"
export SERVICE_LOG
export LOGGER_LOG
RESTART_DEFERRAL_ATTEMPTS=2
handle_relayed router1
assert_contains "max deferrals proceeds with restart" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)" "tailscaled restart"
assert_eq "max deferrals skips activity sampling" \
  "missing" "$([ -f "$NETSTAT_LOG" ] && cat "$NETSTAT_LOG" || printf 'missing')"

reset_restart_state
reset_fake_netstat active
RESTART_DEFERRAL_ATTEMPTS=1
handle_direct router1
assert_eq "direct path clears global deferral state" \
  "0" "$RESTART_DEFERRAL_ATTEMPTS"
