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
RESTART_SERVICES="tailscaled pfsense_tailscaled"
RESTART_DEFERRAL_ENABLED=1
RESTART_DEFERRAL_INTERFACE="tailscale0"
RESTART_DEFERRAL_CHECK_SECONDS=30
RESTART_DEFERRAL_MAX_BYTES=65536
RESTART_DEFERRAL_MAX_ATTEMPTS=10
NOTIFY_PROVIDER="pushover"
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

expect_invalid_service "restart service semicolon fails" 'RESTART_SERVICES="tailscaled bad;svc"'
expect_invalid_service "restart service command-substitution-shaped value fails" "RESTART_SERVICES='tailscaled \$(id)'"
expect_invalid_service "restart service path traversal fails" 'RESTART_SERVICES="tailscaled ../service"'
expect_invalid_service "restart service leading hyphen fails" 'RESTART_SERVICES="tailscaled -badservice"'
expect_invalid_service "restart service glob fails" 'RESTART_SERVICES="tailscaled *"'
