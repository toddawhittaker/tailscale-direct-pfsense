#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

# The daemon file under test.  Overridable so a mutated copy can be checked.
DAEMON_FILE="${DAEMON_FILE:-${REPO_ROOT}/tailscale_watchdogd}"

. "${SCRIPT_DIR}/lib/testlib.sh"

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "$DAEMON_FILE"

tmpdir="$(make_temp_dir)"
fakebin="${tmpdir}/bin"
mkdir -p "$fakebin" || exit 1

STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"

IFC_FIXTURE="${tmpdir}/ifconfig_output"
IFC_CALLS="${tmpdir}/ifconfig_calls"
IFC_ADD_FAIL="${tmpdir}/ifconfig_add_fail"
RELOAD_CALLS="${tmpdir}/reload_calls"
RELOAD_FAIL="${tmpdir}/reload_fail"
RELOAD_KILL="${tmpdir}/reload_kill"
LOGGER_LOG="${tmpdir}/logger_log"
CURL_CALLS="${tmpdir}/curl_calls"
CURL_STDIN="${tmpdir}/curl_stdin"
CURL_ARGS="${tmpdir}/curl_args"
IFC_AFTER_ADD="${tmpdir}/ifconfig_after_add"
DATE_EPOCH_FILE="${tmpdir}/date_epoch"
export IFC_FIXTURE IFC_CALLS IFC_ADD_FAIL RELOAD_CALLS RELOAD_FAIL RELOAD_KILL
export LOGGER_LOG CURL_CALLS CURL_STDIN CURL_ARGS IFC_AFTER_ADD DATE_EPOCH_FILE

# Fake ifconfig.  Only the two invocations the daemon makes are accepted; any
# other argument list fails loudly so a changed command line cannot pass.
cat > "${fakebin}/ifconfig" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "tailscale0" ]; then
  printf 'show %s\n' "$*" >> "$IFC_CALLS"
  if [ "$(cat "$IFC_FIXTURE")" = "ABSENT" ]; then
    echo "ifconfig: interface tailscale0 does not exist" >&2
    exit 1
  fi
  cat "$IFC_FIXTURE"
  exit 0
fi
if [ "$#" -eq 3 ] && [ "$1" = "tailscale0" ] && [ "$2" = "group" ] && [ "$3" = "Tailscale" ]; then
  printf 'add %s\n' "$*" >> "$IFC_CALLS"
  # IFC_AFTER_ADD, when present, replaces the fixture: stands in for the
  # package hook adding the group first.
  [ -e "$IFC_AFTER_ADD" ] && cp "$IFC_AFTER_ADD" "$IFC_FIXTURE"
  [ -e "$IFC_ADD_FAIL" ] && exit 1
  exit 0
fi
echo "fake ifconfig: unexpected arguments: $*" >&2
printf 'UNEXPECTED %s\n' "$*" >> "$IFC_CALLS"
exit 99
EOF

cat > "${fakebin}/reload" <<'EOF'
#!/bin/sh
printf 'reload %s\n' "$*" >> "$RELOAD_CALLS"
[ -e "$RELOAD_FAIL" ] && exit 1
# Kills the daemon's repair subshell, which is this script's parent.
[ -e "$RELOAD_KILL" ] && kill -KILL "$PPID"
exit 0
EOF

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

# Fake date with a file-driven epoch so the repair holdoff is deterministic.
cat > "${fakebin}/date" <<'EOF'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  cat "$DATE_EPOCH_FILE"
else
  /bin/date "$@"
fi
EOF

# Fake curl.  Records one line per call and keeps whatever was sent on stdin
# (the daemon passes the request, secrets included, as a config stream).
cat > "${fakebin}/curl" <<'EOF'
#!/bin/sh
printf 'curl\n' >> "$CURL_CALLS"
printf '%s\n' "$@" >> "$CURL_ARGS"
cat >> "$CURL_STDIN"
exit 0
EOF

chmod 755 "${fakebin}/ifconfig" "${fakebin}/reload" "${fakebin}/logger" "${fakebin}/curl" "${fakebin}/date"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

PRESENT_FIXTURE='tailscale0: flags=1008051<UP,POINTOPOINT,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 1280
	options=80000<LINKSTATE>
	inet 100.64.0.1 --> 100.64.0.1 netmask 0xffffffff
	groups: tun Tailscale
	nd6 options=101<PERFORMNUD,NO_DAD>
	Opened by PID 1234'

MISSING_FIXTURE='tailscale0: flags=1008051<UP,POINTOPOINT,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 1280
	options=80000<LINKSTATE>
	inet 100.64.0.1 --> 100.64.0.1 netmask 0xffffffff
	groups: tun
	nd6 options=101<PERFORMNUD,NO_DAD>
	Opened by PID 1234'

NOGROUPS_FIXTURE='tailscale0: flags=1008051<UP,POINTOPOINT,RUNNING,MULTICAST,LOWER_UP> metric 0 mtu 1280
	options=80000<LINKSTATE>
	inet 100.64.0.1 --> 100.64.0.1 netmask 0xffffffff
	nd6 options=101<PERFORMNUD,NO_DAD>
	Opened by PID 1234'

# set_ifc present|missing|nogroups|absent
set_ifc() {
  case "$1" in
    present) printf '%s\n' "$PRESENT_FIXTURE" > "$IFC_FIXTURE" ;;
    missing) printf '%s\n' "$MISSING_FIXTURE" > "$IFC_FIXTURE" ;;
    nogroups) printf '%s\n' "$NOGROUPS_FIXTURE" > "$IFC_FIXTURE" ;;
    absent) printf 'ABSENT\n' > "$IFC_FIXTURE" ;;
    *) echo "set_ifc: bad state $1" >&2; exit 1 ;;
  esac
}

# new_scenario: clean logs, clean state, repair enabled, notifications wired
# to the fake curl.
new_scenario() {
  : > "$IFC_CALLS"
  : > "$RELOAD_CALLS"
  : > "$LOGGER_LOG"
  : > "$CURL_CALLS"
  : > "$CURL_STDIN"
  : > "$CURL_ARGS"
  rm -f "$IFC_ADD_FAIL" "$RELOAD_FAIL" "$RELOAD_KILL" "$IFC_AFTER_ADD"
  printf "100000\n" > "$DATE_EPOCH_FILE"
  IFGROUP_NEXT_REPAIR_ALLOWED=0
  IFGROUP_REPAIR_MIN_SECONDS=900
  ONE_SHOT=0
  rm -rf "$STATE_DIR"
  IFGROUP_MISSING_CHECKS=0
  IFGROUP_STATUS=""
  INTERFACE_GROUP_REPAIR_ENABLED=1
  TEST=0
  DEBUG=0
  FILTER_RELOAD_COMMAND="${fakebin}/reload"
  NOTIFY_PROVIDER="pushover"
  PUSHOVER_TOKEN="faketoken"
  PUSHOVER_USER="fakeuser"
  LOCAL_TAILSCALE_NAME="router0"
  set_ifc present
}

# file_lines FILE: number of lines in FILE.
file_lines() {
  wc -l < "$1" | tr -d ' '
}

SHOW="show tailscale0"
ADD="add tailscale0 group Tailscale"
NL='
'

# ---- 1. interface_output_has_group ---------------------------------------

printf '%s\n' "$PRESENT_FIXTURE" | interface_output_has_group Tailscale
assert_eq "group listed on the groups line returns 0" "0" "$?"
printf '%s\n' "$MISSING_FIXTURE" | interface_output_has_group Tailscale
assert_eq "group absent from the groups line returns 1" "1" "$?"
printf '%s\n' "$NOGROUPS_FIXTURE" | interface_output_has_group Tailscale
assert_eq "output with no groups line returns 2" "2" "$?"
printf '\tgroups: tun TailscaleX\n' | interface_output_has_group Tailscale
assert_eq "group that is a prefix of another word does not match" "1" "$?"
printf '\tgroups: tun XTailscale\n' | interface_output_has_group Tailscale
assert_eq "group that is a suffix of another word does not match" "1" "$?"
printf '\tgroups: Tailscale tun\n' | interface_output_has_group Tailscale
assert_eq "group listed first on the groups line matches" "0" "$?"

# ---- 2. disabled by default ----------------------------------------------

new_scenario
assert_eq "repair is off in the daemon defaults" "0" "$(sh -c 'TAILSCALE_WATCHDOG_TESTING=1; export TAILSCALE_WATCHDOG_TESTING; . "$1"; printf %s "$INTERFACE_GROUP_REPAIR_ENABLED"' sh "$DAEMON_FILE")"
INTERFACE_GROUP_REPAIR_ENABLED=0
set_ifc missing
check_interface_group
check_interface_group
check_interface_group
assert_eq "disabled: ifconfig is never called" "" "$(cat "$IFC_CALLS")"
assert_eq "disabled: reload is never called" "" "$(cat "$RELOAD_CALLS")"
assert_eq "disabled: nothing is logged" "" "$(cat "$LOGGER_LOG")"

# ---- 3. healthy -----------------------------------------------------------

new_scenario
check_interface_group
check_interface_group
check_interface_group
assert_eq "healthy: only read-only ifconfig calls are made" "${SHOW}${NL}${SHOW}${NL}${SHOW}" "$(cat "$IFC_CALLS")"
assert_eq "healthy: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "healthy: nothing logged" "" "$(cat "$LOGGER_LOG")"
assert_eq "healthy: no notification" "" "$(cat "$CURL_CALLS")"
assert_eq "healthy: no state directory created" "no" "$([ -e "$STATE_DIR" ] && echo yes || echo no)"

# ---- 4. missing once, twice, then healthy --------------------------------

new_scenario
set_ifc missing
check_interface_group
assert_eq "missing once: one log line" "1" "$(file_lines "$LOGGER_LOG")"
assert_contains "missing once: log says it will repair at the next check" "$(cat "$LOGGER_LOG")" "is not in interface group Tailscale; repairing if it is still missing at the next check"
assert_eq "missing once: no add" "$SHOW" "$(cat "$IFC_CALLS")"
assert_eq "missing once: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "missing once: no notification" "" "$(cat "$CURL_CALLS")"

check_interface_group
assert_eq "missing twice: add runs with exactly tailscale0 group Tailscale" "${SHOW}${NL}${SHOW}${NL}${ADD}" "$(cat "$IFC_CALLS")"
assert_eq "missing twice: reload runs once, without arguments" "reload " "$(cat "$RELOAD_CALLS")"
assert_contains "missing twice: success logged" "$(cat "$LOGGER_LOG")" "Interface group repaired: tailscale0 was missing from interface group Tailscale; re-added it and reloaded the filter"
assert_eq "missing twice: one notification" "curl" "$(cat "$CURL_CALLS")"
assert_contains "missing twice: notification reports the re-add" "$(cat "$CURL_ARGS")" "re-added it and reloaded the filter"

set_ifc present
: > "$LOGGER_LOG"
check_interface_group
assert_eq "after repair, a present group causes no further add" "1" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "after repair, reload is not repeated" "1" "$(file_lines "$RELOAD_CALLS")"
assert_eq "after repair, nothing more is logged" "" "$(cat "$LOGGER_LOG")"
assert_eq "after repair, no second notification" "1" "$(file_lines "$CURL_CALLS")"

# ---- 5. missing, present, missing ----------------------------------------

new_scenario
set_ifc missing
check_interface_group
set_ifc present
check_interface_group
set_ifc missing
check_interface_group
assert_eq "missing/present/missing: counter resets, no add" "0" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "missing/present/missing: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "missing/present/missing: counter is back at 1" "1" "$IFGROUP_MISSING_CHECKS"
assert_contains "missing then present logs that the group is back" "$(cat "$LOGGER_LOG")" "is in interface group Tailscale again"

# ---- 6. interface absent between two missing checks ----------------------

new_scenario
set_ifc missing
check_interface_group
set_ifc absent
check_interface_group
set_ifc missing
check_interface_group
assert_eq "absent interface between misses: counter resets, no add" "0" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "absent interface between misses: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "absent interface between misses: counter is 1" "1" "$IFGROUP_MISSING_CHECKS"
new_scenario
set_ifc absent
check_interface_group
check_interface_group
check_interface_group
assert_eq "absent interface alone: only shows, no add" "${SHOW}${NL}${SHOW}${NL}${SHOW}" "$(cat "$IFC_CALLS")"
assert_eq "absent interface alone: nothing logged" "" "$(cat "$LOGGER_LOG")"

# ---- 7. unrecognised output ----------------------------------------------

new_scenario
set_ifc nogroups
check_interface_group
check_interface_group
check_interface_group
assert_eq "unrecognised output: no add" "0" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "unrecognised output: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "unrecognised output: logged exactly once" "1" "$(file_lines "$LOGGER_LOG")"
assert_contains "unrecognised output: log says not repairing" "$(cat "$LOGGER_LOG")" "no groups line in 'ifconfig tailscale0' output; not repairing"
assert_eq "unrecognised output: no notification" "" "$(cat "$CURL_CALLS")"

# ---- 8. test mode ---------------------------------------------------------

new_scenario
TEST=1
set_ifc missing
check_interface_group
check_interface_group
assert_eq "test mode: no add" "0" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "test mode: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "test mode: TEST MODE line logged once" "1" "$(grep -c 'TEST MODE: tailscale0 is still not in interface group Tailscale; would re-add it and run ' "$LOGGER_LOG")"
assert_eq "test mode: no notification" "" "$(cat "$CURL_CALLS")"
before="$(file_lines "$LOGGER_LOG")"
check_interface_group
assert_eq "test mode: third check does not log again" "$before" "$(file_lines "$LOGGER_LOG")"

# ---- 9. add fails ---------------------------------------------------------

new_scenario
: > "$IFC_ADD_FAIL"
set_ifc missing
check_interface_group
check_interface_group
assert_eq "add fails: add was attempted" "1" "$(grep -c "^${ADD}\$" "$IFC_CALLS")"
assert_eq "add fails: reload is not called" "" "$(cat "$RELOAD_CALLS")"
assert_eq "add fails: failure logged once" "1" "$(grep -c 'Interface group repair FAILED: could not add tailscale0 to interface group Tailscale' "$LOGGER_LOG")"
assert_eq "add fails: one notification" "1" "$(file_lines "$CURL_CALLS")"
assert_contains "add fails: notification says it could not be re-added" "$(cat "$CURL_ARGS")" "could not be re-added"
check_interface_group
check_interface_group
assert_eq "add fails: add is retried on each later check" "3" "$(grep -c "^${ADD}\$" "$IFC_CALLS")"
assert_eq "add fails: failure is not logged again" "1" "$(grep -c 'Interface group repair FAILED' "$LOGGER_LOG")"
assert_eq "add fails: no repeat notification" "1" "$(file_lines "$CURL_CALLS")"
assert_eq "add fails: reload still never called" "" "$(cat "$RELOAD_CALLS")"

# ---- 10. reload fails -----------------------------------------------------

new_scenario
: > "$RELOAD_FAIL"
set_ifc missing
check_interface_group
check_interface_group
assert_eq "reload fails: add was done once" "1" "$(grep -c "^${ADD}\$" "$IFC_CALLS")"
assert_eq "reload fails: reload was called once" "reload " "$(cat "$RELOAD_CALLS")"
assert_contains "reload fails: logged with the reload command" "$(cat "$LOGGER_LOG")" "re-added tailscale0 to interface group Tailscale, but ${fakebin}/reload failed; run it by hand"
assert_not_contains "reload fails: no success line" "$(cat "$LOGGER_LOG")" "Interface group repaired:"
assert_eq "reload fails: one notification" "1" "$(file_lines "$CURL_CALLS")"
assert_contains "reload fails: notification says the reload failed" "$(cat "$CURL_ARGS")" "the filter reload failed"

# ---- 11. no state files from healthy checks ------------------------------

new_scenario
mkdir -p "$STATE_DIR" || exit 1
check_interface_group
check_interface_group
assert_eq "healthy checks leave STATE_DIR empty" "" "$(ls -A "$STATE_DIR")"

# ---- 12. config validation ------------------------------------------------

validate_with() {
  (
    PEERS="router1 router2"
    CHECK_INTERVAL=60
    FAIL_THRESHOLD=5
    PING_COUNT=5
    INTERFACE_GROUP_REPAIR_ENABLED="$1"
    validate_config
  ) >/dev/null 2>&1
  echo $?
}
new_scenario
assert_eq "validate_config accepts INTERFACE_GROUP_REPAIR_ENABLED=0" "0" "$(validate_with 0)"
assert_eq "validate_config accepts INTERFACE_GROUP_REPAIR_ENABLED=1" "0" "$(validate_with 1)"
assert_eq "validate_config rejects INTERFACE_GROUP_REPAIR_ENABLED=2" "2" "$(validate_with 2)"
assert_eq "validate_config rejects a non-numeric INTERFACE_GROUP_REPAIR_ENABLED" "2" "$(validate_with yes)"

# ---- 13. exact log lines for a repair ------------------------------------

new_scenario
set_ifc missing
check_interface_group
check_interface_group
assert_eq "repair logs the first miss, the intent, then the result, in order" \
"Interface group check: tailscale0 is not in interface group Tailscale; repairing if it is still missing at the next check${NL}Interface group repair: re-adding tailscale0 to interface group Tailscale and running ${fakebin}/reload${NL}Interface group repaired: tailscale0 was missing from interface group Tailscale; re-added it and reloaded the filter" \
"$(cat "$LOGGER_LOG")"

new_scenario
ONE_SHOT=1
set_ifc missing
check_interface_group
assert_eq "one-shot first miss says the running daemon repairs it" \
"Interface group check: tailscale0 is not in interface group Tailscale; the running daemon repairs this if it is still missing at its next check" \
"$(cat "$LOGGER_LOG")"

# ---- 14. holdoff ----------------------------------------------------------

new_scenario
set_ifc missing
check_interface_group
check_interface_group
assert_eq "holdoff: first repair sets the next allowed epoch 900s ahead" "100900" "$IFGROUP_NEXT_REPAIR_ALLOWED"
: > "$LOGGER_LOG"
set_ifc present
check_interface_group
set_ifc missing
printf '100100\n' > "$DATE_EPOCH_FILE"
check_interface_group
check_interface_group
check_interface_group
assert_eq "holdoff: no second add within 900s" "1" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "holdoff: no second reload within 900s" "1" "$(file_lines "$RELOAD_CALLS")"
assert_eq "holdoff: no second notification" "1" "$(file_lines "$CURL_CALLS")"
assert_eq "holdoff: one waiting line, logged once while it persists" \
"Interface group check: tailscale0 is missing from interface group Tailscale again within 900s of the last repair; waiting 800s before repairing again" \
"$(grep 'waiting' "$LOGGER_LOG")"
assert_eq "holdoff: status is holdoff" "holdoff" "$IFGROUP_STATUS"
printf '100900\n' > "$DATE_EPOCH_FILE"
check_interface_group
assert_eq "holdoff: repairs again once the gap has passed" "2" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "holdoff: second reload ran" "2" "$(file_lines "$RELOAD_CALLS")"
assert_eq "holdoff: second notification sent" "2" "$(file_lines "$CURL_CALLS")"

# Recovery from a holdoff is logged.
new_scenario
IFGROUP_NEXT_REPAIR_ALLOWED=100500
set_ifc missing
check_interface_group
check_interface_group
set_ifc present
: > "$LOGGER_LOG"
check_interface_group
assert_eq "recovery from holdoff is logged" "Interface group check: tailscale0 is in interface group Tailscale again" "$(cat "$LOGGER_LOG")"

# A reload failure also starts the holdoff.
new_scenario
: > "$RELOAD_FAIL"
set_ifc missing
check_interface_group
check_interface_group
assert_eq "reload failure still starts the holdoff" "100900" "$IFGROUP_NEXT_REPAIR_ALLOWED"

# ---- 15. counter resets after a successful repair ------------------------

new_scenario
set_ifc missing
check_interface_group
check_interface_group
assert_eq "after a repair the missing counter is zero" "0" "$IFGROUP_MISSING_CHECKS"
printf '101000\n' > "$DATE_EPOCH_FILE"
check_interface_group
assert_eq "after holdoff expires, one miss does not repair immediately" "1" "$(grep -c '^add ' "$IFC_CALLS")"
assert_eq "after holdoff expires, one miss does not reload" "1" "$(file_lines "$RELOAD_CALLS")"

# ---- 16. recovery after a failed add -------------------------------------

new_scenario
: > "$IFC_ADD_FAIL"
set_ifc missing
check_interface_group
check_interface_group
set_ifc present
: > "$LOGGER_LOG"
check_interface_group
assert_eq "recovery after a failed add is logged" "Interface group check: tailscale0 is in interface group Tailscale again" "$(cat "$LOGGER_LOG")"
assert_eq "a failed add does not start the holdoff" "0" "$IFGROUP_NEXT_REPAIR_ALLOWED"

# ---- 17. add fails because the package hook won the race -----------------

new_scenario
: > "$IFC_ADD_FAIL"
printf '%s\n' "$PRESENT_FIXTURE" > "$IFC_AFTER_ADD"
set_ifc missing
check_interface_group
: > "$LOGGER_LOG"
check_interface_group
assert_eq "race: log says the interface rejoined, nothing to do" \
"Interface group repair: re-adding tailscale0 to interface group Tailscale and running ${fakebin}/reload${NL}Interface group check: tailscale0 rejoined interface group Tailscale before the repair ran; nothing to do" \
"$(cat "$LOGGER_LOG")"
assert_eq "race: no reload" "" "$(cat "$RELOAD_CALLS")"
assert_eq "race: no notification" "" "$(cat "$CURL_CALLS")"
assert_eq "race: status ok" "ok" "$IFGROUP_STATUS"
assert_eq "race: counter reset" "0" "$IFGROUP_MISSING_CHECKS"
assert_eq "race: no holdoff left behind" "0" "$IFGROUP_NEXT_REPAIR_ALLOWED"

# ---- 18. internal state is discarded by reset_runtime_state ---------------

FILTER_RELOAD_COMMAND="/tmp/hostile_reload"
IFGROUP_INTERFACE="hostile0"
IFGROUP_NAME="Hostile"
IFGROUP_REPAIR_MIN_SECONDS=1
reset_runtime_state
assert_eq "reset_runtime_state discards a configured FILTER_RELOAD_COMMAND" "/etc/rc.filter_configure_sync" "$FILTER_RELOAD_COMMAND"
assert_eq "reset_runtime_state discards a configured IFGROUP_INTERFACE" "tailscale0" "$IFGROUP_INTERFACE"
assert_eq "reset_runtime_state discards a configured IFGROUP_NAME" "Tailscale" "$IFGROUP_NAME"
assert_eq "reset_runtime_state discards a configured IFGROUP_REPAIR_MIN_SECONDS" "900" "$IFGROUP_REPAIR_MIN_SECONDS"

# ---- 19. secrets stay out of argv -----------------------------------------

new_scenario
set_ifc missing
check_interface_group
check_interface_group
assert_contains "the token reaches curl on stdin" "$(cat "$CURL_STDIN")" "faketoken"
assert_not_contains "the token never appears in curl argv" "$(cat "$CURL_ARGS")" "faketoken"
assert_not_contains "the user key never appears in curl argv" "$(cat "$CURL_ARGS")" "fakeuser"
assert_not_contains "the token never appears in the log" "$(cat "$LOGGER_LOG")" "faketoken"

# A clock stepped backwards after a repair must not stretch the holdoff.
new_scenario
set_ifc missing
check_interface_group
check_interface_group
set_ifc present
check_interface_group
set_ifc missing
printf '99000\n' > "$DATE_EPOCH_FILE"
check_interface_group
check_interface_group
assert_eq "clock step back: holdoff longer than 900s is treated as over" "2" "$(grep -c '^add ' "$IFC_CALLS")"

# A repair subshell killed after the add must not be read as the hook having
# won the race, even though the group is now present.
new_scenario
: > "$RELOAD_KILL"
printf '%s\n' "$PRESENT_FIXTURE" > "$IFC_AFTER_ADD"
set_ifc missing
check_interface_group
check_interface_group
assert_not_contains "killed repair: not reported as rejoined" "$(cat "$LOGGER_LOG")" "rejoined"
assert_contains "killed repair: reported as failed" "$(cat "$LOGGER_LOG")" "Interface group repair FAILED"
assert_eq "killed repair: status is add_failed" "add_failed" "$IFGROUP_STATUS"
assert_eq "killed repair: holdoff not started" "0" "$IFGROUP_NEXT_REPAIR_ALLOWED"
