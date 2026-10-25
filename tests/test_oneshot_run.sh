#!/bin/sh

# Regression test: a one-shot test-mode run (-t -1) must finish cleanly.
# check_all_peers once shared its noglob flag with a function its loop calls,
# which unset it.  The run still completed, but printed "[: : bad number" to
# stderr and left globbing off for the rest of the process.
#
# This drives the real main with real argv and the real tailscale ping path,
# so the whole one-shot chain runs: option parsing, validate_config, the
# startup warnings, check_all_peers, check_peer_path, and the direct and
# unknown handlers.  Only load_config_file is replaced: the real one insists
# on a root-owned config and resets PATH, which would drop the fakes below.

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)
FIXTURES="${SCRIPT_DIR}/fixtures"

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

# Answers only "tailscale ping -c N PEER" for the two known peers.  Anything
# else is recorded and fails, so an unexpected call shows up in an assertion.
cat > "${fakebin}/tailscale" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TAILSCALE_LOG"
if [ "$1" = "ping" ] && [ "$2" = "-c" ] && [ "$#" -eq 4 ]; then
  case "$4" in
    router1) cat "${FIXTURES}/ping_direct.txt"; exit 0 ;;
    router2) cat "${FIXTURES}/ping_unknown.txt"; exit 1 ;;
  esac
fi
printf 'unexpected call: tailscale %s\n' "$*" >> "$UNEXPECTED_LOG"
exit 1
EOF

# Test mode must not restart, notify, or sample interface counters.
for tool in service curl netstat; do
  cat > "${fakebin}/${tool}" <<'EOF'
#!/bin/sh
printf 'unexpected call: %s %s\n' "${0##*/}" "$*" >> "$UNEXPECTED_LOG"
exit 1
EOF
done

chmod 755 "${fakebin}"/*

LOGGER_LOG="${tmpdir}/logger.log"
TAILSCALE_LOG="${tmpdir}/tailscale.log"
UNEXPECTED_LOG="${tmpdir}/unexpected.log"
export LOGGER_LOG TAILSCALE_LOG UNEXPECTED_LOG FIXTURES

# Sourcing the daemon set its fixed PATH, so put the fakes first afterwards.
PATH="${fakebin}:/usr/bin:/bin"
export PATH

conf="${tmpdir}/tailscale_watchdog.conf"
cat > "$conf" <<'EOF'
PEERS="router1 router2"
PING_COUNT=2
FAIL_THRESHOLD=3
RESTART_DEFERRAL_ENABLED=0
NOTIFY_PROVIDER="none"
EOF

load_config_file() {
  . "$1"
}

# Runs main in a subshell, the way the rc wrapper would run the daemon, and
# records the shell's noglob setting at the moment main exits.  The EXIT trap
# is set inside the subshell, so it replaces testlib's inherited trap there.
run_oneshot() {
  (
    trap 'case $- in *f*) echo set ;; *) echo unset ;; esac > "${tmpdir}/noglob_at_exit"' EXIT
    set +f
    main "$@"
  ) > "${tmpdir}/stdout" 2> "${tmpdir}/stderr"
  run_rc=$?
}

# The daemon runs without set -u.
set +u
run_oneshot -t -1 -f "$conf"
set -u

assert_eq "one-shot run exits 0" "0" "$run_rc"
assert_eq "one-shot run writes nothing to stderr" "" "$(cat "${tmpdir}/stderr")"
assert_eq "one-shot run writes nothing to stdout" "" "$(cat "${tmpdir}/stdout")"
assert_eq "noglob is off again when the one-shot run exits" "unset" \
  "$(cat "${tmpdir}/noglob_at_exit" 2>/dev/null || printf 'not recorded')"
assert_eq "both peers were pinged, in order, with the configured count" \
  "$(printf 'ping -c 2 router1\nping -c 2 router2')" \
  "$(cat "$TAILSCALE_LOG")"
assert_contains "router1 was classified direct" "$(cat "$LOGGER_LOG")" \
  "Peer router1 is direct (initial classification; was: unknown)"
assert_contains "the run was in test mode" "$(cat "$LOGGER_LOG")" " test=1 "
assert_eq "no unexpected tailscale, service, curl, or netstat call" \
  "missing" "$([ -f "$UNEXPECTED_LOG" ] && cat "$UNEXPECTED_LOG" || printf 'missing')"
