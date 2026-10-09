#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

# count_lines FILE: number of lines in FILE, 0 if it does not exist.
count_lines() {
  if [ -f "$1" ]; then
    wc -l < "$1" | tr -d ' '
  else
    echo 0
  fi
}

# count_matches FILE FIXED_STRING: number of lines in FILE containing the string.
count_matches() {
  grep -c -F -e "$2" "$1"
}

tmpdir="$(make_temp_dir)"

# Anything the fake daemon leaves running must die even if an assertion fails
# or the script is interrupted.  This wraps testlib's trap rather than
# replacing it, so temp dirs are still removed and the count still printed.
kill_leftover_daemons() {
  if [ -f "${tmpdir}/daemon_pids" ]; then
    while read -r leftover_pid; do
      case "$leftover_pid" in
        ''|*[!0-9]*) ;;
        *) kill "$leftover_pid" 2>/dev/null ;;
      esac
    done < "${tmpdir}/daemon_pids"
  fi
}
trap 'kill_leftover_daemons; finish_tests' EXIT INT TERM

# ---------------------------------------------------------------------------
# 1. Boot hook dispatch
# ---------------------------------------------------------------------------

hook_src="${REPO_ROOT}/tailscale_watchdog.sh"

assert_eq "hook source names /usr/sbin/service exactly once" \
  "1" "$(count_matches "$hook_src" '/usr/sbin/service')"

hook_dir="${tmpdir}/hook"
mkdir "$hook_dir" || exit 1
service_log="${hook_dir}/service.log"
fake_service="${hook_dir}/fake_service"

cat > "$fake_service" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$(dirname "$0")/service.log"
exit 0
EOF
chmod 755 "$fake_service"

hook_copy="${hook_dir}/tailscale_watchdog.sh"
sed "s#/usr/sbin/service#${fake_service}#" "$hook_src" > "$hook_copy" || exit 1
chmod 755 "$hook_copy"

assert_eq "hook copy no longer references /usr/sbin/service" \
  "0" "$(count_matches "$hook_copy" '/usr/sbin/service')"
assert_eq "hook copy references the fake service exactly once" \
  "1" "$(count_matches "$hook_copy" "$fake_service")"

for cmd in start stop restart status; do
  : > "$service_log"
  "$hook_copy" "$cmd" >/dev/null 2>&1
  rc=$?
  assert_eq "hook '${cmd}' exits 0" "0" "$rc"
  assert_eq "hook '${cmd}' calls service with exactly: tailscale_watchdog ${cmd}" \
    "tailscale_watchdog ${cmd}" "$(cat "$service_log")"
  assert_eq "hook '${cmd}' calls service once" "1" "$(count_lines "$service_log")"
done

: > "$service_log"
err="$("$hook_copy" 2>&1 >/dev/null)"
rc=$?
assert_eq "hook with no argument exits 1" "1" "$rc"
assert_contains "hook with no argument prints usage on stderr" "$err" "Usage:"
assert_eq "hook with no argument does not call service" "0" "$(count_lines "$service_log")"

for bad in bogus onestart; do
  : > "$service_log"
  err="$("$hook_copy" "$bad" 2>&1 >/dev/null)"
  rc=$?
  assert_eq "hook rejects '${bad}' with exit 1" "1" "$rc"
  assert_contains "hook rejecting '${bad}' prints usage on stderr" "$err" "Usage:"
  assert_eq "hook does not forward '${bad}' to service" "0" "$(count_lines "$service_log")"
done

# ---------------------------------------------------------------------------
# 2. A repeated start on the rc.d script is a no-op
# ---------------------------------------------------------------------------

rc_src="${REPO_ROOT}/tailscale_watchdog"
rc_dir="${tmpdir}/rc"
mkdir "$rc_dir" || exit 1

assert_eq "rc script sources /etc/rc.subr exactly once" \
  "1" "$(count_matches "$rc_src" '. /etc/rc.subr')"

# This fake skips rc.subr's tailscale_watchdog_enable check, so two things
# the hook relies on are not covered here: a start does nothing unless the
# service is enabled, and a stop likewise does nothing (the wrapper sets no
# command or procname, so rc.subr cannot see a running process to exempt).
# Both come from the real rc.subr; reimplementing it here would only test
# the fake.
cat > "${rc_dir}/fake_rc.subr" <<'EOF'
load_rc_config() {
  :
}

run_rc_command() {
  case "$1" in
    start|stop|status|restart)
      "${name}_$1"
      ;;
    *)
      echo "fake rc.subr: unsupported command '$1'" >&2
      exit 99
      ;;
  esac
}
EOF

rc_copy="${rc_dir}/tailscale_watchdog"
sed "s#^\. /etc/rc\.subr\$#. ${rc_dir}/fake_rc.subr#" "$rc_src" > "$rc_copy" || exit 1

assert_eq "rc copy no longer sources /etc/rc.subr" \
  "0" "$(count_matches "$rc_copy" '. /etc/rc.subr')"
assert_eq "rc copy sources the fake rc.subr exactly once" \
  "1" "$(count_matches "$rc_copy" ". ${rc_dir}/fake_rc.subr")"

launch_log="${rc_dir}/launches.log"
pidfile="${rc_dir}/pid"

# The fake daemon records each launch and its pid, then stays alive.
cat > "${rc_dir}/fake_daemon" <<EOF
#!/bin/sh
echo launched >> "${launch_log}"
echo \$\$ >> "${tmpdir}/daemon_pids"
exec sleep 60
EOF
chmod 755 "${rc_dir}/fake_daemon"

run_rc() {
  tailscale_watchdog_pidfile="$pidfile" \
  tailscale_watchdog_command="${rc_dir}/fake_daemon" \
  tailscale_watchdog_flags="" \
  sh "$rc_copy" "$1" 2>&1
}

out1="$(run_rc start)"
rc=$?
assert_eq "first start exits 0" "0" "$rc"
assert_contains "first start reports starting" "$out1" "Starting tailscale_watchdog."
assert_file_exists "first start writes the pidfile" "$pidfile"
pid1="$(cat "$pidfile" 2>/dev/null)"
case "$pid1" in
  ''|*[!0-9]*) pid1_numeric=no ;;
  *) pid1_numeric=yes ;;
esac
assert_eq "pidfile holds a numeric pid" "yes" "$pid1_numeric"
if [ "$pid1_numeric" = yes ] && kill -0 "$pid1" 2>/dev/null; then
  alive=yes
else
  alive=no
fi
assert_eq "pid in pidfile is a live process after first start" "yes" "$alive"
assert_eq "first start launches the daemon once" "1" "$(count_lines "$launch_log")"

out2="$(run_rc start)"
rc=$?
assert_eq "repeat start exits 0" "0" "$rc"
assert_contains "repeat start reports the running pid" \
  "$out2" "tailscale_watchdog already running as pid ${pid1}"
assert_not_contains "repeat start does not report starting" "$out2" "Starting tailscale_watchdog."
assert_eq "repeat start does not launch a second daemon" "1" "$(count_lines "$launch_log")"
assert_eq "repeat start leaves the pidfile unchanged" "$pid1" "$(cat "$pidfile" 2>/dev/null)"

out3="$(run_rc stop)"
rc=$?
assert_eq "stop exits 0" "0" "$rc"
if [ "$pid1_numeric" = yes ] && kill -0 "$pid1" 2>/dev/null; then
  alive=yes
else
  alive=no
fi
assert_eq "daemon process is gone after stop" "no" "$alive"
if [ -f "$pidfile" ]; then
  pidfile_state=present
else
  pidfile_state=absent
fi
assert_eq "stop removes the pidfile" "absent" "$pidfile_state"
