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
config_example_text="$(cat "${REPO_ROOT}/tailscale_watchdog.conf.example")"
script_reference_text="$(cat "${REPO_ROOT}/docs/script-reference.md")"
docs_url="https://github.com/toddawhittaker/tailscale-direct-pfsense"

assert_file_exists "docs index exists" "${REPO_ROOT}/docs/README.md"
assert_file_exists "architecture docs exist" "${REPO_ROOT}/docs/architecture.md"
assert_file_exists "daemon behavior docs exist" "${REPO_ROOT}/docs/daemon-behavior.md"
assert_file_exists "script reference docs exist" "${REPO_ROOT}/docs/script-reference.md"
assert_file_exists "testing docs exist" "${REPO_ROOT}/docs/testing.md"

# CLAUDE.md must remain a symlink to AGENTS.md so Claude Code and Codex read
# one rulebook.  A tool that materializes it as a separate regular file would
# create a second copy that silently drifts from AGENTS.md.
assert_success "CLAUDE.md is a symlink" test -L "${REPO_ROOT}/CLAUDE.md"

assert_eq "CLAUDE.md resolves to AGENTS.md" \
  "AGENTS.md" "$(readlink "${REPO_ROOT}/CLAUDE.md" 2>/dev/null)"

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

assert_contains "README links to maintainer docs" \
  "$readme_text" '[`docs/`](docs/)'

assert_contains "AGENTS references maintainer docs" \
  "$agents_text" 'Use `docs/` for maintainer-focused rationale.'

assert_contains "config example includes notification provider selector" \
  "$config_example_text" 'NOTIFY_PROVIDER="pushover"'

assert_contains "config example includes startup notification setting" \
  "$config_example_text" 'NOTIFY_ON_STARTUP=1'

assert_contains "config example includes local tailscale name setting" \
  "$config_example_text" 'LOCAL_TAILSCALE_NAME=""'

assert_contains "README documents notification provider selector" \
  "$readme_text" 'NOTIFY_PROVIDER="pushover"'

assert_contains "README documents startup notification setting" \
  "$readme_text" 'NOTIFY_ON_STARTUP=0'

assert_contains "README documents local tailscale name override" \
  "$readme_text" 'LOCAL_TAILSCALE_NAME="router0"'

assert_contains "maintainer docs describe notification dispatcher" \
  "$script_reference_text" "Notifications use a small provider dispatcher."

assert_contains "maintainer docs describe line-oriented notifications" \
  "$script_reference_text" "Pushover notifications use a title plus a line-oriented body"

assert_contains "AGENTS mentions new notification provider requirements" \
  "$agents_text" "New notification providers must preserve Pushover compatibility"

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
