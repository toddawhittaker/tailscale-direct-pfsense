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
printf '%s\n' "$@" > "$CURL_ARG_LOG"
while [ "$#" -gt 0 ]; do
  case "$1" in
    -K)
      shift
      if [ "$1" = "-" ]; then
        cat > "$CURL_CONFIG_COPY"
      else
        cp "$1" "$CURL_CONFIG_COPY"
      fi
      ;;
  esac
  shift
done
exit 0
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/curl"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

CURL_ARG_LOG="${tmpdir}/curl.args"
CURL_CONFIG_COPY="${tmpdir}/curl.conf"
LOGGER_LOG="${tmpdir}/logger.log"
export CURL_ARG_LOG CURL_CONFIG_COPY LOGGER_LOG

DEBUG=0
CURL_TIMEOUT=10
NOTIFY_PROVIDER="pushover"
PUSHOVER_TOKEN="secret-token"
PUSHOVER_USER="secret-user"

assert_success "notify dispatches pushover with fake curl" notify "router1 restarted"

curl_args="$(cat "$CURL_ARG_LOG")"
curl_config="$(cat "$CURL_CONFIG_COPY")"

assert_not_contains "Pushover token is not passed in curl argv" "$curl_args" "secret-token"
assert_not_contains "Pushover user is not passed in curl argv" "$curl_args" "secret-user"
assert_contains "curl config contains Pushover token" "$curl_config" "token=secret-token"
assert_contains "curl config contains Pushover user" "$curl_config" "user=secret-user"
assert_contains "curl config contains notification message" "$curl_config" "message=router1 restarted"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_PROVIDER="none"
assert_success "notify provider none skips curl" notify "router1 restarted"
assert_eq "notify provider none does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"
assert_contains "notify provider none logs skip" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Notification skipped: provider is disabled"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_PROVIDER=""
assert_success "blank notify provider skips curl" notify "router1 restarted"
assert_eq "blank notify provider does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_PROVIDER="telegram"
notify "router1 restarted" >/dev/null 2>&1
rc=$?
assert_eq "unsupported notify provider fails" "1" "$rc"
assert_eq "unsupported notify provider does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"
assert_contains "unsupported notify provider logs failure" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Notification failed: unsupported provider 'telegram'"

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
DOCS_URL="https://github.com/toddawhittaker/tailscale-direct-pfsense"
PUSHOVER_TOKEN="secret-token"
PUSHOVER_USER="secret-user"

startup_message="$(startup_notification_message)"
assert_contains "startup message includes peers" "$startup_message" "Peers: router1 router2."
assert_contains "startup message includes interval" "$startup_message" "Check interval: 60s."
assert_contains "startup message includes threshold" "$startup_message" "Relay threshold: 5 consecutive checks."
assert_contains "startup message includes ping count" "$startup_message" "Ping count: 5."
assert_contains "startup message includes cooldown range" "$startup_message" "Restart cooldown: 900-1800s."
assert_contains "startup message includes restart services" "$startup_message" "Restart services: tailscaled pfsense_tailscaled."
assert_contains "startup message includes deferral settings" "$startup_message" "Restart deferral: enabled on tailscale0"
assert_contains "startup message includes docs URL" "$startup_message" "$DOCS_URL"
assert_not_contains "startup message does not include Pushover token" "$startup_message" "secret-token"
assert_not_contains "startup message does not include Pushover user" "$startup_message" "secret-user"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_PROVIDER="pushover"
NOTIFY_ON_STARTUP=1
TEST=0
ONE_SHOT=0
notify_startup_if_enabled
assert_contains "startup notification calls fake curl" \
  "$(cat "$CURL_ARG_LOG" 2>/dev/null)" "-K"
assert_contains "startup notification sends startup message" \
  "$(cat "$CURL_CONFIG_COPY" 2>/dev/null)" "message=Tailscale watchdog started."

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_ON_STARTUP=0
notify_startup_if_enabled
assert_eq "disabled startup notification does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_ON_STARTUP=1
TEST=1
ONE_SHOT=0
notify_startup_if_enabled
assert_eq "test mode startup notification does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
TEST=0
ONE_SHOT=1
notify_startup_if_enabled
assert_eq "one-shot startup notification does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
TEST=0
ONE_SHOT=0
NOTIFY_PROVIDER="none"
notify_startup_if_enabled
assert_eq "provider none startup notification does not call curl" \
  "missing" "$([ -f "$CURL_ARG_LOG" ] && cat "$CURL_ARG_LOG" || printf 'missing')"
