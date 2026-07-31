#!/bin/sh

# A TERM arriving between a service stop and the matching start must not exit
# the daemon.  Doing so would leave Tailscale stopped on the router, and a
# watchdog started against a dead Tailscale classifies every peer as unknown,
# which breaks the relayed sequence -- so it would never restart the service on
# its own.
#
# POSIX defers a trapped signal until the running foreground command completes
# and then runs the trap, so this is not a narrow race: any TERM delivered from
# the first stop onwards lands in the window.  The fake service below sends the
# signal itself, which makes the timing exact rather than probabilistic.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

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

cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
exit 0
EOF

# Delivers TERM to the daemon process at the exact moment the service has been
# stopped and not yet started.  SIGNAL_TARGET_PID is set only for the run that
# exercises the signal path.
cat > "${fakebin}/service" <<'EOF'
#!/bin/sh
printf '%s %s\n' "$1" "$2" >> "$SERVICE_LOG"
# SIGNAL_ON_SLEEP moves the signal to the settle instead, so the two cases do
# not both fire.
if [ "$2" = "stop" ] && [ -n "${SIGNAL_TARGET_PID:-}" ] && [ -z "${SIGNAL_ON_SLEEP:-}" ]; then
  kill -TERM "$SIGNAL_TARGET_PID"
fi
exit 0
EOF

# SIGNAL_ON_SLEEP delivers the TERM during the settle instead of during the
# stop, which is the case where a settle is already sleeping and must run to
# completion rather than being skipped.
#
# This fake really does sleep, and brackets the pause with begin/end markers.
# An earlier version logged one line and returned immediately, which made the
# assertion for that case unfalsifiable: the marker appeared whether the pause
# completed or was abandoned.  The real pause plus the end marker is what makes
# "a settle already sleeping runs to completion" a testable claim -- and that
# claim is what the cap in validate_config is sized against.
cat > "${fakebin}/sleep" <<'EOF'
#!/bin/sh
printf 'sleep-begin %s\n' "$1" >> "$SERVICE_LOG"
if [ -n "${SIGNAL_ON_SLEEP:-}" ] && [ -n "${SIGNAL_TARGET_PID:-}" ]; then
  kill -TERM "$SIGNAL_TARGET_PID"
fi
/bin/sleep "$1"
printf 'sleep-end %s\n' "$1" >> "$SERVICE_LOG"
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/date" "${fakebin}/jot" \
  "${fakebin}/curl" "${fakebin}/service" "${fakebin}/sleep"

PATH="${fakebin}:/usr/bin:/bin"
export PATH
TEST_PATH="$PATH"
export TEST_PATH

# Runs one restart in a child shell with the real signal handler installed.
# Sourcing the daemon in-process would not do: the trap has to fire in a shell
# that can actually exit, which is the behavior under test.
cat > "${tmpdir}/run_restart.sh" <<'EOF'
#!/bin/sh
set -u
TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"

# Sourcing resets these to the real runtime paths, so override afterwards.
# PATH matters most: the daemon hardens it at the top of the file, which would
# put the real logger and service ahead of the fakes.  The other test files get
# this for free by sourcing before they set PATH; this one sources in a child.
PATH="$TEST_PATH"
export PATH
STATE_DIR="$TEST_STATE_DIR"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"

PEERS="router1"
RESTART_SERVICES="${TEST_RESTART_SERVICES:-pfsense_tailscaled}"
RESTART_SETTLE_SECONDS=1
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
TEST=0
DEBUG=0

if [ -n "${SIGNAL_SELF:-}" ]; then
  SIGNAL_TARGET_PID=$$
  export SIGNAL_TARGET_PID
fi

trap handle_shutdown INT TERM

set_peer_attr count router1 5
set_peer_attr state router1 relayed

restart_tailscale_services router1 5 >/dev/null 2>&1
printf 'returned normally\n' >> "$SERVICE_LOG"
EOF
chmod 755 "${tmpdir}/run_restart.sh"

export REPO_ROOT

# ---- TERM delivered between the stop and the start -------------------------

TEST_STATE_DIR="${tmpdir}/state-signal"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service-signal.log"
LOGGER_LOG="${tmpdir}/logger-signal.log"
SIGNAL_SELF=1
export TEST_STATE_DIR NEXT_RESTART_FILE SERVICE_LOG LOGGER_LOG SIGNAL_SELF

sh "${tmpdir}/run_restart.sh"
signal_rc=$?

service_log="$(cat "$SERVICE_LOG" 2>/dev/null)"

assert_contains "TERM between stop and start still runs the start" \
  "$service_log" "pfsense_tailscaled start"
# The trap runs as soon as the stop's command substitution returns, which is
# before the settle check, so this settle is dropped rather than taken.
assert_eq "TERM during the stop skips the settle and still starts" \
  "$(printf 'pfsense_tailscaled stop\npfsense_tailscaled start')" \
  "$service_log"
assert_eq "deferred shutdown exits zero" "0" "$signal_rc"
assert_not_contains "deferred shutdown exits rather than returning" \
  "$service_log" "returned normally"

logger_log="$(cat "$LOGGER_LOG" 2>/dev/null)"
assert_contains "deferred shutdown is logged" \
  "$logger_log" "Shutdown requested during a service restart; completing the restart first"
assert_contains "deferred shutdown still logs the stop" \
  "$logger_log" "Daemon stopping"

# ---- No signal: the restart returns normally -------------------------------

TEST_STATE_DIR="${tmpdir}/state-plain"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service-plain.log"
LOGGER_LOG="${tmpdir}/logger-plain.log"
SIGNAL_SELF=""
export TEST_STATE_DIR NEXT_RESTART_FILE SERVICE_LOG LOGGER_LOG SIGNAL_SELF

sh "${tmpdir}/run_restart.sh"
plain_rc=$?

assert_eq "restart without a signal returns normally" "0" "$plain_rc"
assert_eq "restart without a signal takes the full settle" \
  "$(printf 'pfsense_tailscaled stop\nsleep-begin 1\nsleep-end 1\npfsense_tailscaled start\nreturned normally')" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)"
assert_not_contains "restart without a signal logs no shutdown" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Daemon stopping"

# ---- Multi-service list: every stopped service still gets started -----------
#
# This is the shape a preserved live config has, and it is where the deadline
# actually bites: the critical section spans the whole list, but the rc
# wrapper's SIGKILL budget is a single window measured from the TERM.  Once a
# shutdown is pending the loop starts what it already stopped and then breaks,
# leaving untouched services running -- they are safe as they are, and stopping
# one would open a fresh window on a budget already partly spent.

TEST_STATE_DIR="${tmpdir}/state-multi"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service-multi.log"
LOGGER_LOG="${tmpdir}/logger-multi.log"
SIGNAL_SELF=1
TEST_RESTART_SERVICES="tailscaled pfsense_tailscaled"
export TEST_STATE_DIR NEXT_RESTART_FILE SERVICE_LOG LOGGER_LOG SIGNAL_SELF \
  TEST_RESTART_SERVICES

sh "${tmpdir}/run_restart.sh"
multi_rc=$?

multi_log="$(cat "$SERVICE_LOG" 2>/dev/null)"

# The trap runs as soon as the first stop's command substitution returns, which
# is before the settle check -- so that settle is dropped, not taken.  The
# service already stopped is started, and the loop then breaks rather than
# stopping a service that is still safely running.
assert_eq "multi-service shutdown starts what it stopped and stops no more" \
  "$(printf 'tailscaled stop\ntailscaled start')" \
  "$multi_log"
assert_not_contains "multi-service shutdown does not stop the untouched service" \
  "$multi_log" "pfsense_tailscaled stop"
assert_contains "leaving the untouched service alone is logged" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "leaving pfsense_tailscaled running"
assert_eq "multi-service deferred shutdown exits zero" "0" "$multi_rc"
assert_not_contains "multi-service shutdown does not return normally" \
  "$multi_log" "returned normally"

# Without a signal every service keeps its settle.
TEST_STATE_DIR="${tmpdir}/state-multi-plain"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service-multi-plain.log"
LOGGER_LOG="${tmpdir}/logger-multi-plain.log"
SIGNAL_SELF=""
export TEST_STATE_DIR NEXT_RESTART_FILE SERVICE_LOG LOGGER_LOG SIGNAL_SELF

sh "${tmpdir}/run_restart.sh"

assert_eq "multi-service without a signal restarts every service with its settle" \
  "$(printf 'tailscaled stop\nsleep-begin 1\nsleep-end 1\ntailscaled start\npfsense_tailscaled stop\nsleep-begin 1\nsleep-end 1\npfsense_tailscaled start\nreturned normally')" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)"

# TERM delivered during the settle itself: that sleep is already running, so it
# completes rather than being skipped, and only the later ones are dropped.
# This is the single full settle the cap in validate_config is sized against.
TEST_STATE_DIR="${tmpdir}/state-sleep-signal"
NEXT_RESTART_FILE="${TEST_STATE_DIR}/next_restart_allowed"
SERVICE_LOG="${tmpdir}/service-sleep-signal.log"
LOGGER_LOG="${tmpdir}/logger-sleep-signal.log"
SIGNAL_SELF=1
SIGNAL_ON_SLEEP=1
export TEST_STATE_DIR NEXT_RESTART_FILE SERVICE_LOG LOGGER_LOG SIGNAL_SELF \
  SIGNAL_ON_SLEEP

sh "${tmpdir}/run_restart.sh"
sleep_signal_rc=$?

# sleep-end is the point: the pause ran to completion despite the TERM landing
# in the middle of it.  Without that marker this assertion could not tell a
# completed pause from an abandoned one.
assert_eq "TERM during a settle completes that settle, then stops no more services" \
  "$(printf 'tailscaled stop\nsleep-begin 1\nsleep-end 1\ntailscaled start')" \
  "$(cat "$SERVICE_LOG" 2>/dev/null)"
assert_eq "TERM during a settle still exits zero" "0" "$sleep_signal_rc"

SIGNAL_ON_SLEEP=""
TEST_RESTART_SERVICES=""
export SIGNAL_ON_SLEEP TEST_RESTART_SERVICES

# ---- Outside a restart, shutdown is still immediate -------------------------

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"
# Same reason as in the child: sourcing restores the daemon's hardened PATH.
PATH="$TEST_PATH"
export PATH

LOGGER_LOG="${tmpdir}/logger-normal.log"
export LOGGER_LOG
RESTART_CRITICAL=0
SHUTDOWN_PENDING=0
SLEEP_PID=""

# `exit 9` is only reached if handle_shutdown returned instead of exiting, so
# this distinguishes the two.  A bare `( handle_shutdown )` would pass either way.
( handle_shutdown; exit 9 )
assert_eq "handle_shutdown outside a restart exits rather than returning" "0" "$?"
assert_contains "handle_shutdown outside a restart logs stopping" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Daemon stopping"
assert_not_contains "handle_shutdown outside a restart does not defer" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "completing the restart first"

# The handler must not exit while a restart is in flight; it records instead.
LOGGER_LOG="${tmpdir}/logger-critical.log"
export LOGGER_LOG
RESTART_CRITICAL=1
SHUTDOWN_PENDING=0
handle_shutdown
assert_eq "handle_shutdown during a restart returns instead of exiting" \
  "1" "$SHUTDOWN_PENDING"
assert_contains "handle_shutdown during a restart logs the deferral" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "completing the restart first"
