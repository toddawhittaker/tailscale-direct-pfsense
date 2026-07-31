#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

rc_text="$(cat "${REPO_ROOT}/tailscale_watchdog")"

assert_contains "rc wrapper has PROVIDE header" "$rc_text" "# PROVIDE: tailscale_watchdog"
assert_contains "rc wrapper has REQUIRE header" "$rc_text" "# REQUIRE: NETWORKING tailscaled pfsense_tailscaled"
assert_contains "rc wrapper has shutdown keyword" "$rc_text" "# KEYWORD: shutdown"
assert_contains "rc wrapper sources rc.subr" "$rc_text" ". /etc/rc.subr"
assert_contains "rc wrapper loads rc config" "$rc_text" 'load_rc_config "$name"'
assert_contains "rc wrapper defaults daemon command" "$rc_text" 'tailscale_watchdog_command:="/usr/local/sbin/tailscale_watchdogd"'
assert_contains "rc wrapper default flags exclude debug" "$rc_text" 'tailscale_watchdog_flags:="-f /usr/local/etc/tailscale_watchdog.conf"'
assert_not_contains "rc wrapper default flags do not include debug mode" "$rc_text" 'tailscale_watchdog_flags:="-d'
assert_contains "rc wrapper validates pid values" "$rc_text" "valid_pid()"
assert_contains "rc wrapper removes stale pidfile on start" "$rc_text" 'rm -f "$pidfile"'
assert_contains "rc wrapper captures startup output" "$rc_text" 'start_log="$(mktemp "/tmp/${name}.start.XXXXXX")"'
assert_contains "rc wrapper starts daemon in background" "$rc_text" '>"$start_log" 2>&1 &'
# rc.conf flags must word-split, but that split belongs on its own `set --`
# line rather than on the launch line.  A line-level SC2086 suppression covers
# every expansion on the line it precedes, including any added later that does
# need quoting -- and the shellcheck job is blocking, so such a finding would
# never be reported.  These two assertions keep the suppression narrow.
assert_contains "rc wrapper word-splits daemon flags via set --" "$rc_text" \
  'set -- ${tailscale_watchdog_command} ${tailscale_watchdog_flags}'
assert_contains "rc wrapper launches daemon from split arguments" "$rc_text" \
  '"$@" >"$start_log" 2>&1 &'
assert_contains "rc wrapper sends TERM before escalation" "$rc_text" 'kill "$pid" 2>/dev/null'
assert_contains "rc wrapper escalates to KILL only after wait" "$rc_text" 'kill -KILL "$pid" 2>/dev/null'
assert_contains "rc wrapper exposes custom status" "$rc_text" 'status_cmd="${name}_status"'
assert_contains "rc wrapper runs rc command dispatcher" "$rc_text" 'run_rc_command "$1"'
