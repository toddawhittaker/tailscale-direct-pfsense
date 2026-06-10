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
