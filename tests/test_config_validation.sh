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

run_validate "valid config passes" 0 "" ""
run_validate "empty peers fail" 2 'PEERS=""' "PEERS must not be empty"
run_validate "invalid peer characters fail" 2 'PEERS="router1 bad;peer"' "Invalid peer name"
run_validate "sanitized peer collision fails" 2 'PEERS="router-a router.a"' "collides with another peer"
run_validate "non-numeric check interval fails" 2 'CHECK_INTERVAL="x"' "CHECK_INTERVAL must be a positive integer"
run_validate "zero fail threshold fails" 2 'FAIL_THRESHOLD=0' "FAIL_THRESHOLD must be a positive integer"
run_validate "bad ping count fails" 2 'PING_COUNT="-1"' "PING_COUNT must be a positive integer"
run_validate "bad cooldown minimum fails" 2 'RESTART_COOLDOWN_MIN=abc' "RESTART_COOLDOWN_MIN must be a positive integer"
run_validate "bad cooldown maximum fails" 2 'RESTART_COOLDOWN_MAX=abc' "RESTART_COOLDOWN_MAX must be a positive integer"
run_validate "cooldown maximum below minimum fails" 2 'RESTART_COOLDOWN_MIN=1800; RESTART_COOLDOWN_MAX=900' "must be >= RESTART_COOLDOWN_MIN"
run_validate "bad curl timeout fails" 2 'CURL_TIMEOUT=0' "CURL_TIMEOUT must be a positive integer"
run_validate "empty restart services fails" 2 'RESTART_SERVICES=""' "RESTART_SERVICES must not be empty"
