#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

uninstall_text="$(cat "${REPO_ROOT}/uninstall.sh")"

assert_contains "uninstaller requires root" "$uninstall_text" 'if [ "$(id -u)" -ne 0 ]; then'
assert_contains "uninstaller verifies pfSense platform file" "$uninstall_text" "[ -f /etc/platform ]"
assert_contains "uninstaller uses onestop" "$uninstall_text" 'service "$SERVICE_NAME" onestop'
assert_contains "uninstaller removes only project rc.conf assignments" "$uninstall_text" 'sed "/^[[:space:]]*${SERVICE_NAME}_[A-Za-z0-9_]*[[:space:]]*=/d"'
assert_contains "uninstaller edits rc.conf atomically" "$uninstall_text" 'rcconf_tmp="$(mktemp "${RCCONF_LOCAL}.XXXXXX")"'
assert_contains "uninstaller removes current cooldown state" "$uninstall_text" 'remove_file "${STATE_DIR}/next_restart_allowed"'
assert_contains "uninstaller removes runtime state directory" "$uninstall_text" 'remove_dir  "$STATE_DIR"'
assert_contains "uninstaller preserves live config without tty" "$uninstall_text" "Cannot read from terminal; defaulting to preserving live config"
assert_contains "uninstaller asks before live config removal" "$uninstall_text" 'Remove live config file %s? [y/N]'
assert_contains "uninstaller does not remove Tailscale package" "$uninstall_text" "The Tailscale package itself was not removed"
assert_not_contains "uninstaller does not call package remove" "$uninstall_text" "pkg delete tailscale"
assert_not_contains "uninstaller does not remove tailscale binary" "$uninstall_text" "rm -f /usr/local/bin/tailscale"
