#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

install_text="$(cat "${REPO_ROOT}/install.sh")"
active_text="$(
  awk '
    in_heredoc {
      if ($0 == heredoc_end) {
        in_heredoc = 0
        heredoc_end = ""
      }
      next
    }
    {
      line = $0
      if (line ~ /^[[:space:]]*#/) {
        next
      }
      if (match(line, /<<[[:space:]]*[-]?[[:space:]]*['\''"]?[A-Za-z_][A-Za-z0-9_]*['\''"]?/)) {
        marker = substr(line, RSTART, RLENGTH)
        sub(/^<<[[:space:]]*[-]?[[:space:]]*['\''"]?/, "", marker)
        sub(/['\''"]?$/, "", marker)
        heredoc_end = marker
        in_heredoc = 1
      }
      print line
    }
  ' "${REPO_ROOT}/install.sh"
)"

assert_contains "installer base URL uses HTTPS" \
  "$install_text" 'BASE_URL="https://raw.githubusercontent.com/'

assert_contains "installer restricts curl protocol to HTTPS" \
  "$install_text" "--proto '=https'"

assert_contains "installer restricts curl redirects to HTTPS" \
  "$install_text" "--proto-redir '=https'"

assert_not_contains "installer does not start watchdog service" \
  "$active_text" "service tailscale_watchdog start"

assert_not_contains "installer does not use onestart" \
  "$active_text" "service tailscale_watchdog onestart"

assert_not_contains "installer does not enable service with sysrc" \
  "$active_text" "sysrc tailscale_watchdog_enable"

assert_not_contains "installer does not write enable line" \
  "$active_text" "tailscale_watchdog_enable=YES"

assert_contains "installer tracks preexisting live config" \
  "$install_text" "LIVE_CONFIG_PREEXISTED=1"

assert_contains "installer preserves existing live config branch" \
  "$install_text" "Existing live config preserved"

assert_contains "installer creates live config only when missing" \
  "$install_text" 'if [ "$LIVE_CONFIG_PREEXISTED" -eq 1 ]; then'

assert_contains "installer installs live config in missing-config branch" \
  "$install_text" '"$CONF_DST_LIVE"'
