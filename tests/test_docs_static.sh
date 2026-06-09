#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

readme_text="$(cat "${REPO_ROOT}/README.md")"
daemon_text="$(cat "${REPO_ROOT}/tailscale_watchdogd")"

assert_not_contains "README does not recommend printing Pushover secrets" \
  "$readme_text" "grep '^PUSHOVER_'"

assert_not_contains "README manual install does not overwrite daemon with direct cp" \
  "$readme_text" "cp tailscale_watchdogd /usr/local/sbin/tailscale_watchdogd"

assert_not_contains "README manual install does not overwrite wrapper with direct cp" \
  "$readme_text" "cp tailscale_watchdog /usr/local/etc/rc.d/tailscale_watchdog"

assert_contains "README manual install uses mktemp" \
  "$readme_text" "mktemp /usr/local/sbin/.tailscale_watchdogd.XXXXXX"

assert_contains "daemon defaults use generic peers" \
  "$daemon_text" 'PEERS="router1 router2"'
