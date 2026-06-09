#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"

tmpdir="$(make_temp_dir)"
STATE_DIR="${tmpdir}/state"
NEXT_RESTART_FILE="${STATE_DIR}/next_restart_allowed"
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
fakebin="$(make_temp_dir)"

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

chmod 755 "${fakebin}/logger" "${fakebin}/date"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

now=100000

assert_eq "missing cooldown state permits restart" \
  "0" "$(next_restart_epoch "$now")"

mkdir -p "$STATE_DIR" || exit 1

printf '%s\n' "$((now + 300))" > "$NEXT_RESTART_FILE"
assert_eq "future next_restart_allowed is honored" \
  "$((now + 300))" "$(next_restart_epoch "$now")"

printf '%s\n' "$((now - 300))" > "$NEXT_RESTART_FILE"
assert_eq "past next_restart_allowed is returned for expiry handling" \
  "$((now - 300))" "$(next_restart_epoch "$now")"

printf '%s\n' "not-a-number" > "$NEXT_RESTART_FILE"
assert_eq "garbage cooldown state is ignored" \
  "0" "$(next_restart_epoch "$now")"

printf '%s\n' "$((now + RESTART_COOLDOWN_MAX + 61))" > "$NEXT_RESTART_FILE"
assert_eq "implausibly far future cooldown state is ignored" \
  "0" "$(next_restart_epoch "$now")"

RESTART_COOLDOWN_MIN=777
RESTART_COOLDOWN_MAX=777
assert_eq "fixed cooldown range returns fixed value" \
  "777" "$(random_cooldown_seconds)"

RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
assert_eq "missing jot falls back to minimum cooldown" \
  "900" "$(random_cooldown_seconds)"

cat > "${fakebin}/jot" <<'EOF'
#!/bin/sh
printf '%s\n' bad-output
EOF
chmod 755 "${fakebin}/jot"

assert_eq "bad jot output falls back to minimum cooldown" \
  "900" "$(random_cooldown_seconds)"

cat > "${fakebin}/jot" <<'EOF'
#!/bin/sh
printf '%s\n' 900
EOF
chmod 755 "${fakebin}/jot"

rm -rf "$STATE_DIR"
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
assert_success "mark_restart_attempt writes cooldown atomically" mark_restart_attempt
assert_eq "mark_restart_attempt stores next allowed epoch" \
  "100900" "$(cat "$NEXT_RESTART_FILE")"
assert_eq "mark_restart_attempt leaves no temp files" \
  "0" "$(find "$STATE_DIR" -name '.next_restart_allowed.*' | wc -l | tr -d ' ')"

rm -rf "$STATE_DIR"
ln -s "${tmpdir}/elsewhere" "$STATE_DIR"
assert_eq "symlink state dir is refused" \
  "1" "$(mark_restart_attempt >/dev/null 2>&1; printf '%s' "$?")"
