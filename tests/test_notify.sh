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

cat > "${fakebin}/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TAILSCALE_LOG"
case "$TAILSCALE_STATUS_FAIL" in
  1)
    exit 1
    ;;
esac
if [ "$1" = "status" ] && [ "$2" = "--self" ] && [ "$3" = "--peers=false" ]; then
  printf '100.64.0.1  router-local  user@example.com  freebsd  -\n'
  exit 0
fi
exit 2
EOF

chmod 755 "${fakebin}/logger" "${fakebin}/curl" "${fakebin}/tailscale"

PATH="${fakebin}:/usr/bin:/bin"
export PATH

CURL_ARG_LOG="${tmpdir}/curl.args"
CURL_CONFIG_COPY="${tmpdir}/curl.conf"
LOGGER_LOG="${tmpdir}/logger.log"
TAILSCALE_LOG="${tmpdir}/tailscale.log"
TAILSCALE_STATUS_FAIL=0
export CURL_ARG_LOG CURL_CONFIG_COPY LOGGER_LOG TAILSCALE_LOG TAILSCALE_STATUS_FAIL

DEBUG=0
CURL_TIMEOUT=10
NOTIFY_PROVIDER="pushover"
PUSHOVER_TOKEN="secret-token"
PUSHOVER_USER="secret-user"
LOCAL_TAILSCALE_NAME=""
RESOLVED_LOCAL_TAILSCALE_NAME=""

assert_success "notify dispatches pushover with fake curl" notify "router1 restarted"

curl_args="$(cat "$CURL_ARG_LOG")"
curl_config="$(cat "$CURL_CONFIG_COPY")"

assert_not_contains "Pushover token is not passed in curl argv" "$curl_args" "secret-token"
assert_not_contains "Pushover user is not passed in curl argv" "$curl_args" "secret-user"
assert_contains "curl config contains Pushover token" "$curl_config" "token=secret-token"
assert_contains "curl config contains Pushover user" "$curl_config" "user=secret-user"
assert_contains "curl args request URL-encoded message" "$curl_args" "--data-urlencode"
assert_contains "curl args contain notification message" "$curl_args" "message=router1 restarted"

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
formatted_message="$(printf 'Router: router-local\nEvent: started')"
assert_success "notify sends title and multi-line body" \
  notify "Tailscale watchdog: router-local started" "$formatted_message"
curl_args="$(cat "$CURL_ARG_LOG")"
assert_contains "curl args contain notification title" \
  "$curl_args" "title=Tailscale watchdog: router-local started"
assert_contains "curl args contain multi-line router field" "$curl_args" "Router: router-local"
assert_contains "curl args contain multi-line event field" "$curl_args" "Event: started"

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
LOCAL_TAILSCALE_NAME=""
RESOLVED_LOCAL_TAILSCALE_NAME=""

startup_title="$(startup_notification_title router-local)"
startup_message="$(startup_notification_message router-local)"
assert_contains "startup title includes router name" "$startup_title" "router-local started"
assert_contains "startup message includes router name" "$startup_message" "Router: router-local"
assert_contains "startup message includes event" "$startup_message" "Event: started"
assert_contains "startup message includes peers" "$startup_message" "Peers: router1 router2"
assert_contains "startup message includes interval" "$startup_message" "Check interval: 60s"
assert_contains "startup message includes threshold" "$startup_message" "Relay threshold: 5 consecutive checks"
assert_contains "startup message includes ping count" "$startup_message" "Ping count: 5"
assert_contains "startup message includes cooldown range" "$startup_message" "Restart cooldown: 900-1800s"
assert_contains "startup message includes restart services" "$startup_message" "Restart services: tailscaled pfsense_tailscaled"
assert_contains "startup message includes deferral settings" "$startup_message" "Restart deferral: enabled on tailscale0"
assert_contains "startup message includes docs URL" "$startup_message" "$DOCS_URL"
assert_not_contains "startup message does not include Pushover token" "$startup_message" "secret-token"
assert_not_contains "startup message does not include Pushover user" "$startup_message" "secret-user"

restart_title="$(restart_notification_title router-local success)"
restart_message="$(restart_notification_message router-local success router1 5)"
assert_contains "restart title includes router name" "$restart_title" "router-local restarted"
assert_contains "restart message includes router name" "$restart_message" "Router: router-local"
assert_contains "restart message includes success event" "$restart_message" "Event: restart completed"
assert_contains "restart message includes trigger peer" "$restart_message" "Trigger peer: router1"
assert_contains "restart message includes relay count" "$restart_message" "Relay count: 5 consecutive checks"
assert_contains "restart message includes services" "$restart_message" "Services: tailscaled pfsense_tailscaled"

restart_title="$(restart_notification_title router-local failure)"
restart_message="$(restart_notification_message router-local failure router1 5)"
assert_contains "failed restart title includes router name" "$restart_title" "router-local restart failed"
assert_contains "failed restart message includes failure event" "$restart_message" "Event: restart failed"

assert_eq "auto-detected local Tailscale name" "router-local" "$(local_tailscale_name)"
assert_contains "local name detection calls tailscale status" \
  "$(cat "$TAILSCALE_LOG" 2>/dev/null)" "status --self --peers=false"

rm -f "$TAILSCALE_LOG"
LOCAL_TAILSCALE_NAME="router-override"
RESOLVED_LOCAL_TAILSCALE_NAME=""
assert_eq "configured local Tailscale name overrides detection" "router-override" "$(local_tailscale_name)"
assert_eq "configured local Tailscale name does not call tailscale" \
  "missing" "$([ -f "$TAILSCALE_LOG" ] && cat "$TAILSCALE_LOG" || printf 'missing')"

LOCAL_TAILSCALE_NAME=""
RESOLVED_LOCAL_TAILSCALE_NAME=""
TAILSCALE_STATUS_FAIL=1
assert_eq "failed local Tailscale name detection returns unknown" "unknown" "$(local_tailscale_name)"
assert_contains "failed local Tailscale name detection logs warning" \
  "$(cat "$LOGGER_LOG" 2>/dev/null)" "Local Tailscale name detection failed"
TAILSCALE_STATUS_FAIL=0

rm -f "$CURL_ARG_LOG" "$CURL_CONFIG_COPY" "$LOGGER_LOG"
NOTIFY_PROVIDER="pushover"
NOTIFY_ON_STARTUP=1
TEST=0
ONE_SHOT=0
LOCAL_TAILSCALE_NAME=""
RESOLVED_LOCAL_TAILSCALE_NAME=""
notify_startup_if_enabled
assert_contains "startup notification calls fake curl" \
  "$(cat "$CURL_ARG_LOG" 2>/dev/null)" "-K"
assert_contains "startup notification sends startup title" \
  "$(cat "$CURL_ARG_LOG" 2>/dev/null)" "title=Tailscale watchdog: router-local started"
assert_contains "startup notification sends startup body" \
  "$(cat "$CURL_ARG_LOG" 2>/dev/null)" "Router: router-local"

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
