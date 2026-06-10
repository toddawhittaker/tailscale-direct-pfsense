#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

readme_text="$(cat "${REPO_ROOT}/README.md")"
daemon_text="$(cat "${REPO_ROOT}/tailscale_watchdogd")"
rc_text="$(cat "${REPO_ROOT}/tailscale_watchdog")"
install_text="$(cat "${REPO_ROOT}/install.sh")"
uninstall_text="$(cat "${REPO_ROOT}/uninstall.sh")"
agents_text="$(cat "${REPO_ROOT}/AGENTS.md")"
docs_url="https://github.com/toddawhittaker/tailscale-direct-pfsense"

assert_file_exists "docs index exists" "${REPO_ROOT}/docs/README.md"
assert_file_exists "architecture docs exist" "${REPO_ROOT}/docs/architecture.md"
assert_file_exists "daemon behavior docs exist" "${REPO_ROOT}/docs/daemon-behavior.md"
assert_file_exists "script reference docs exist" "${REPO_ROOT}/docs/script-reference.md"
assert_file_exists "testing docs exist" "${REPO_ROOT}/docs/testing.md"

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

assert_contains "README includes Mermaid decision flow" \
  "$readme_text" '```mermaid'

assert_contains "README links to maintainer docs" \
  "$readme_text" '[`docs/`](docs/)'

assert_contains "AGENTS references maintainer docs" \
  "$agents_text" 'Use `docs/` for maintainer-focused rationale.'

assert_contains "daemon header includes documentation URL" \
  "$daemon_text" "$docs_url"

assert_contains "daemon startup log includes docs field" \
  "$daemon_text" 'docs=${DOCS_URL}'

assert_contains "daemon startup log uses compact cooldown range" \
  "$daemon_text" 'cooldown=(min=${RESTART_COOLDOWN_MIN}s,max=${RESTART_COOLDOWN_MAX}s)'

assert_contains "rc wrapper header includes documentation URL" \
  "$rc_text" "$docs_url"

assert_contains "installer header includes documentation URL" \
  "$install_text" "$docs_url"

assert_contains "installer output includes documentation URL" \
  "$install_text" 'Documentation:'

assert_contains "uninstaller header includes documentation URL" \
  "$uninstall_text" "$docs_url"

assert_contains "uninstaller output includes documentation URL" \
  "$uninstall_text" 'Documentation:'
