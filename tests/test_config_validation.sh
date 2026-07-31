#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

run_validate() {
  desc="$1"
  expected_rc="$2"
  setup="$3"
  expected_msg="$4"

  tmpdir="$(make_temp_dir)"
  script="${tmpdir}/validate.sh"
  output="${tmpdir}/output.txt"

  cat > "$script" <<EOF
#!/bin/sh
TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"
PEERS="router1 router2"
CHECK_INTERVAL=60
FAIL_THRESHOLD=5
PING_COUNT=5
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
RESTART_SERVICES="pfsense_tailscaled"
RESTART_SETTLE_SECONDS=3
RESTART_DEFERRAL_ENABLED=1
RESTART_DEFERRAL_INTERFACE="tailscale0"
RESTART_DEFERRAL_CHECK_SECONDS=30
RESTART_DEFERRAL_MAX_BYTES=65536
RESTART_DEFERRAL_MAX_ATTEMPTS=10
NOTIFY_PROVIDER="pushover"
NOTIFY_ON_STARTUP=1
LOCAL_TAILSCALE_NAME=""
CURL_TIMEOUT=10
${setup}
validate_config
EOF

  sh "$script" > "$output" 2>&1
  rc=$?
  assert_eq "$desc rc" "$expected_rc" "$rc"
  if [ -n "$expected_msg" ]; then
    assert_contains "$desc message" "$(cat "$output")" "$expected_msg"
  fi
}

expect_invalid_config() {
  desc="$1"
  setup="$2"
  expected_msg="$3"

  run_validate "$desc" 2 "$setup" "$expected_msg"
}

expect_invalid_peer() {
  desc="$1"
  setup="$2"

  expect_invalid_config "$desc" "$setup" "Invalid peer name"
}

expect_invalid_service() {
  desc="$1"
  setup="$2"

  expect_invalid_config "$desc" "$setup" "Invalid service name"
}

expect_invalid_positive_int() {
  var="$1"
  value="$2"

  expect_invalid_config \
    "${var} rejects ${value}" \
    "${var}=\"${value}\"" \
    "${var} must be a positive integer"
}

run_validate "valid config passes" 0 "" ""
run_validate "notification provider pushover passes" 0 'NOTIFY_PROVIDER="pushover"' ""
run_validate "notification provider none passes" 0 'NOTIFY_PROVIDER="none"' ""
run_validate "blank notification provider passes" 0 'NOTIFY_PROVIDER=""' ""
run_validate "startup notification enabled passes" 0 'NOTIFY_ON_STARTUP=1' ""
run_validate "startup notification disabled passes" 0 'NOTIFY_ON_STARTUP=0' ""
run_validate "local tailscale name blank passes" 0 'LOCAL_TAILSCALE_NAME=""' ""
run_validate "local tailscale name safe value passes" 0 'LOCAL_TAILSCALE_NAME="router-1"' ""
expect_invalid_config "empty peers fail" 'PEERS=""' "PEERS must not be empty"

expect_invalid_peer "peer semicolon fails" 'PEERS="router1 bad;peer"'
expect_invalid_peer "peer command-substitution-shaped value fails" "PEERS='router1 \$(id)'"
expect_invalid_peer "peer path traversal fails" 'PEERS="router1 ../router"'
expect_invalid_peer "peer leading hyphen fails" 'PEERS="router1 -badpeer"'
expect_invalid_peer "peer glob fails" 'PEERS="router1 *"'

expect_invalid_config "sanitized peer collision fails" \
  'PEERS="router-a router.a"' \
  "collides with another peer"

for _var in CHECK_INTERVAL FAIL_THRESHOLD PING_COUNT RESTART_COOLDOWN_MIN RESTART_COOLDOWN_MAX CURL_TIMEOUT RESTART_DEFERRAL_CHECK_SECONDS RESTART_DEFERRAL_MAX_BYTES RESTART_DEFERRAL_MAX_ATTEMPTS; do
  for _value in 0 -1 abc; do
    expect_invalid_positive_int "$_var" "$_value"
  done
done
unset _var _value

expect_invalid_config "restart deferral enabled rejects non-boolean" \
  'RESTART_DEFERRAL_ENABLED=abc' \
  "RESTART_DEFERRAL_ENABLED must be 0 or 1"

expect_invalid_config "notification provider semicolon fails" \
  'NOTIFY_PROVIDER="pushover;reboot"' \
  "Invalid notification provider"

expect_invalid_config "notification provider path traversal fails" \
  'NOTIFY_PROVIDER="../pushover"' \
  "Invalid notification provider"

expect_invalid_config "notification provider leading hyphen fails" \
  'NOTIFY_PROVIDER="-pushover"' \
  "Invalid notification provider"

expect_invalid_config "unsupported notification provider fails" \
  'NOTIFY_PROVIDER="telegram"' \
  "Unsupported notification provider"

expect_invalid_config "startup notification rejects abc" \
  'NOTIFY_ON_STARTUP=abc' \
  "NOTIFY_ON_STARTUP must be 0 or 1"

expect_invalid_config "startup notification rejects 2" \
  'NOTIFY_ON_STARTUP=2' \
  "NOTIFY_ON_STARTUP must be 0 or 1"

expect_invalid_config "local tailscale name semicolon fails" \
  'LOCAL_TAILSCALE_NAME="router1;reboot"' \
  "Invalid local Tailscale name"

expect_invalid_config "local tailscale name path traversal fails" \
  'LOCAL_TAILSCALE_NAME="../router1"' \
  "Invalid local Tailscale name"

expect_invalid_config "local tailscale name leading hyphen fails" \
  'LOCAL_TAILSCALE_NAME="-router1"' \
  "Invalid local Tailscale name"

expect_invalid_config "local tailscale name glob fails" \
  'LOCAL_TAILSCALE_NAME="*"' \
  "Invalid local Tailscale name"

expect_invalid_config "restart deferral interface empty fails" \
  'RESTART_DEFERRAL_INTERFACE=""' \
  "RESTART_DEFERRAL_INTERFACE must not be empty"

expect_invalid_config "restart deferral interface semicolon fails" \
  'RESTART_DEFERRAL_INTERFACE="tailscale0;reboot"' \
  "Invalid restart deferral interface"

expect_invalid_config "restart deferral interface path traversal fails" \
  'RESTART_DEFERRAL_INTERFACE="../tailscale0"' \
  "Invalid restart deferral interface"

expect_invalid_config "restart deferral interface leading hyphen fails" \
  'RESTART_DEFERRAL_INTERFACE="-tailscale0"' \
  "Invalid restart deferral interface"

expect_invalid_config "restart deferral interface glob fails" \
  'RESTART_DEFERRAL_INTERFACE="*"' \
  "Invalid restart deferral interface"

expect_invalid_config "cooldown maximum below minimum fails" \
  'RESTART_COOLDOWN_MIN=1800; RESTART_COOLDOWN_MAX=900' \
  "must be >= RESTART_COOLDOWN_MIN"

expect_invalid_config "empty restart services fails" \
  'RESTART_SERVICES=""' \
  "RESTART_SERVICES must not be empty"

# Zero is valid here, unlike the other interval settings: it means stop and
# start back to back, with no settle pause.
expect_invalid_config "negative restart settle seconds fails" \
  'RESTART_SETTLE_SECONDS=-1' \
  "RESTART_SETTLE_SECONDS must be a non-negative integer"

expect_invalid_config "non-numeric restart settle seconds fails" \
  'RESTART_SETTLE_SECONDS=abc' \
  "RESTART_SETTLE_SECONDS must be a non-negative integer"

# Capped because the rc wrapper escalates to SIGKILL 10s after TERM.  A settle
# longer than that window can be killed mid-pause, with the service stopped and
# never started -- exactly the state the stop/start split exists to avoid.
expect_invalid_config "restart settle seconds above the cap fails" \
  'RESTART_SETTLE_SECONDS=60' \
  "RESTART_SETTLE_SECONDS must be <= 4"

# RESTART_SETTLE_SECONDS_MAX, RESTART_CRITICAL, SHUTDOWN_PENDING, and
# SERVICE_OUTPUT_TEMPLATE are internal state rather than settings, but the live
# config is sourced into the same namespace, so main re-asserts them immediately
# after load_config_file.  Without that, a config could raise the cap, or -- by
# assigning a non-numeric value -- make the comparison error out and silently
# skip the check entirely.  RESTART_CRITICAL=1 from a config would be worse
# still: handle_shutdown would defer every signal for the life of the daemon.
#
# Asserted statically because run_validate calls validate_config directly and
# never goes through main, so it cannot exercise the re-assert itself.
#
# Matched with an anchored, whole-line grep rather than assert_contains.  An
# unanchored substring match is satisfied by any prose that happens to mention
# the name -- this file writes two spaces after a period, so a sentence such as
# "the cap.  RESTART_SETTLE_SECONDS_MAX=4 came from the wrapper" passed while
# the code itself was gone.  Requiring exactly one whole line makes replacement
# by a comment fail, not just deletion.
#
# The daemon does this with one reset_runtime_state covering the whole block
# rather than an enumerated list in main.  An earlier version enumerated four
# names and missed SLEEP_PID -- the one handle_shutdown passes to kill as root
# -- so these assertions check the mechanism, then check the function covers
# every internal, rather than trusting a list in two places.
reassert_block="$(sed -n '/^  load_config_file "\$CONFIG_FILE"$/,/^  # ---- Option parsing/p' \
  "${REPO_ROOT}/tailscale_watchdogd")"
assert_contains "the re-assert follows load_config_file" \
  "$reassert_block" 'load_config_file "$CONFIG_FILE"'
assert_eq "main discards config-assigned runtime state after loading" \
  "1" "$(printf '%s\n' "$reassert_block" | grep -c '^  reset_runtime_state$')"

# The reset only helps if nothing sources the config again afterwards.  A
# second source anywhere -- a drop-in directory, a per-instance override --
# silently undoes it while every assertion above still passes, so this counts
# sourcing operations in the whole daemon rather than looking for one shape.
# The single permitted one is load_config_file's own.
assert_eq "the daemon sources exactly one file" \
  "1" "$(grep -c '^[[:space:]]*\(\.\|source\)[[:space:]]' "${REPO_ROOT}/tailscale_watchdogd")"
assert_eq "and that source is load_config_file's" \
  "1" "$(grep -c '^  \. "\$file"$' "${REPO_ROOT}/tailscale_watchdogd")"
assert_eq "load_config_file is called exactly once" \
  "1" "$(grep -c '^  load_config_file "\$CONFIG_FILE"$' "${REPO_ROOT}/tailscale_watchdogd")"

# Every internal must be inside reset_runtime_state, not merely somewhere in
# the file.  SLEEP_PID is listed first because it is the one that reaches a
# kill; TEST and DEBUG because a config setting them silently stops the
# watchdog watching, or fills a RAM-backed /tmp through an unlinked descriptor.
reset_body="$(sed -n '/^reset_runtime_state() {$/,/^}$/p' "${REPO_ROOT}/tailscale_watchdogd")"
for internal in 'SLEEP_PID=""' TEST=0 ONE_SHOT=0 DEBUG=0 RESTART_DEFERRAL_ATTEMPTS=0 \
  RESTART_CRITICAL=0 SHUTDOWN_PENDING=0 RESTART_SETTLE_SECONDS_MAX=4 \
  'SERVICE_OUTPUT_TEMPLATE="/tmp/tailscale_watchdog.service.XXXXXX"'; do
  assert_eq "reset_runtime_state assigns ${internal}" \
    "1" "$(printf '%s\n' "$reset_body" | grep -c "^  ${internal}\$")"
done

# The temp-file capture in run_service_command is the whole reason that
# function exists: a command substitution puts the service child's stdout on a
# pipe the daemon owns, and a SIGKILL mid-start then kills the orphan with
# SIGPIPE before it finishes.  The output-marker assertions in
# test_daemon_restart_flow.sh prove output is captured, but a pipe captures it
# just as well -- so they stay green if the function reverts.  These do not.
# Comment lines are stripped first: the surrounding comments legitimately quote
# `service ... restart` in prose, and matching those would make the check fire
# on its own explanation.
daemon_code="$(grep -v '^[[:space:]]*#' "${REPO_ROOT}/tailscale_watchdogd")"
assert_not_contains "no service invocation inside a command substitution" \
  "$daemon_code" '$(service '
assert_not_contains "no service invocation inside backticks" \
  "$daemon_code" '`service '
assert_contains "run_service_command redirects service output to a file" \
  "$(sed -n '/^run_service_command() {$/,/^}$/p' "${REPO_ROOT}/tailscale_watchdogd")" \
  '>"$_rsc_log" 2>&1'

expect_invalid_service "restart service semicolon fails" 'RESTART_SERVICES="tailscaled bad;svc"'
expect_invalid_service "restart service command-substitution-shaped value fails" "RESTART_SERVICES='tailscaled \$(id)'"
expect_invalid_service "restart service path traversal fails" 'RESTART_SERVICES="tailscaled ../service"'
expect_invalid_service "restart service leading hyphen fails" 'RESTART_SERVICES="tailscaled -badservice"'
expect_invalid_service "restart service glob fails" 'RESTART_SERVICES="tailscaled *"'
