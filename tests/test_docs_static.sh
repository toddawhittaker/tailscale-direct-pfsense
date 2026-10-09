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

# pfSense boot hook.  pfSense runs only /usr/local/etc/rc.d/*.sh at boot, so
# the hook must appear wherever installed files are listed.  Each needle is a
# whole command line or heading, so prose that merely names the path cannot
# satisfy it.
architecture_text="$(cat "${REPO_ROOT}/docs/architecture.md")"
testing_text="$(cat "${REPO_ROOT}/docs/testing.md")"
hook_path="/usr/local/etc/rc.d/tailscale_watchdog.sh"

assert_contains "README manual install places the boot hook atomically" \
  "$readme_text" "mv -f \"\$tmp\" ${hook_path}"

assert_contains "README manual install stages the boot hook with mktemp" \
  "$readme_text" 'tmp="$(mktemp /usr/local/etc/rc.d/.tailscale_watchdog.sh.XXXXXX)"'

assert_contains "README manual uninstall removes the boot hook" \
  "$readme_text" "rm -f ${hook_path}"

assert_not_contains "README manual install does not overwrite boot hook with direct cp" \
  "$readme_text" "cp tailscale_watchdog.sh ${hook_path}"

assert_contains "README syntax-checks the boot hook" \
  "$readme_text" "sh -n tailscale_watchdog.sh"

assert_contains "README has a reboot troubleshooting entry" \
  "$readme_text" "### The service does not start after a reboot"

assert_contains "README reboot troubleshooting names the boot log" \
  "$readme_text" "grep tailscale_watchdog /tmp/bootup_messages"

assert_contains "AGENTS lists the boot hook as an installed path" \
  "$agents_text" "* \`${hook_path}\`"

assert_contains "AGENTS requires the boot hook to stay a pass-through" \
  "$agents_text" "The hook stays a thin pass-through to \`/usr/sbin/service tailscale_watchdog\`"

assert_contains "AGENTS syntax-checks the boot hook" \
  "$agents_text" "sh -n tailscale_watchdog.sh"

assert_contains "architecture lists the boot hook" \
  "$architecture_text" "- \`${hook_path}\`: pfSense boot hook"

assert_contains "architecture explains the pfSense boot model" \
  "$architecture_text" "## pfSense Boot Model"

assert_contains "script reference documents the boot hook" \
  "$script_reference_text" '## `tailscale_watchdog.sh`'

assert_contains "testing docs syntax-check the boot hook" \
  "$testing_text" "sh -n tailscale_watchdog.sh"

# The code side of the same coupling.
assert_contains "installer installs the boot hook" \
  "$install_text" "HOOK_DST=\"${hook_path}\""

assert_contains "uninstaller removes the boot hook" \
  "$uninstall_text" 'remove_file "$HOOK_DST"'

# Interface group repair: the setting must be pinned in the code, the config
# example, the README, and the maintainer docs.  The anchored forms are the
# assignment lines and section headings, which prose cannot satisfy.
daemon_behavior_text="$(cat "${REPO_ROOT}/docs/daemon-behavior.md")"

assert_contains "daemon defaults interface group repair to off" \
  "$daemon_text" "INTERFACE_GROUP_REPAIR_ENABLED=0
CURL_TIMEOUT=10"

assert_contains "config example sets interface group repair off" \
  "$config_example_text" "
INTERFACE_GROUP_REPAIR_ENABLED=0
"

assert_contains "README config block sets interface group repair off" \
  "$readme_text" "
INTERFACE_GROUP_REPAIR_ENABLED=0
"

assert_contains "README has an interface group repair section" \
  "$readme_text" "### Interface group repair"

assert_contains "README has a LAN traffic troubleshooting entry" \
  "$readme_text" "### LAN traffic over Tailscale fails while the watchdog reports peers direct"

assert_contains "README gives the manual interface group fix" \
  "$readme_text" "ifconfig tailscale0 group Tailscale"

assert_contains "daemon behavior docs have an interface group repair section" \
  "$daemon_behavior_text" "## Interface Group Repair"

assert_contains "AGENTS pins the interface group repair invariant" \
  "$agents_text" "* Interface group repair (\`INTERFACE_GROUP_REPAIR_ENABLED\`) is opt-in and defaults to off"

assert_contains "script reference lists the interface group check" \
  "$script_reference_text" "loop: check_interface_group"

assert_contains "testing docs list interface group coverage" \
  "$testing_text" "- interface group check and repair with fake \`ifconfig\`"

assert_not_contains "config example does not document the fixed interface group name as a setting" \
  "$config_example_text" "IFGROUP_"
