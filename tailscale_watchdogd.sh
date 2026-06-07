#!/bin/sh
#
# tailscale_watchdogd
#
# Foreground daemon that checks selected Tailscale peers once per interval.
# If a peer is relayed for FAIL_THRESHOLD consecutive checks, restart
# tailscaled and pfsense_tailscaled, then send a Pushover notification.
#
# Normal healthy operation performs no per-minute disk writes.
#
# Usage:
#   tailscale_watchdogd [-t] [-1] [-d] [-f config_file] [-i seconds] [-n threshold] [-c ping_count]
#
# Options:
#   -t    Test mode: never restart services.
#   -1    One-shot mode: run one check cycle and exit.
#   -d    Debug mode: print classifications and tailscale ping output to stdout.
#   -f    Config file path. Default: /usr/local/etc/tailscale_watchdog.conf.
#   -i    Check interval in seconds. Overrides config/default.
#   -n    Consecutive relayed checks required before restart. Overrides config/default.
#   -c    tailscale ping count. Overrides config/default.
#
# Security notes:
#   - The config file must be owned by root and not group- or world-writable.
#     Permissions are verified with stat(1) before sourcing.
#   - Pushover credentials are passed as curl --form-string arguments, which
#     means they are briefly visible in the process table. On pfSense, process
#     table access is restricted to root, so the practical risk is low.
#   - Peer names are validated to contain only hostname-safe characters before
#     being passed to tailscale ping, and checked for post-sanitization
#     collisions that would cause two peers to share the same state counter.
#
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
TAG="tailscale_watchdog"

# ---- Configuration defaults ------------------------------------------------
#
# These defaults may be overridden by the config file.
# Command-line flags override both defaults and config-file values.
CONFIG_FILE="/usr/local/etc/tailscale_watchdog.conf"
PUSHOVER_TOKEN=""
PUSHOVER_USER=""
PEERS="router router2"
CHECK_INTERVAL=60
FAIL_THRESHOLD=5
PING_COUNT=5
RESTART_COOLDOWN=900
RESTART_SERVICES="tailscaled pfsense_tailscaled"
STATE_DIR="/var/run/tailscale_watchdog"
LAST_RESTART_FILE="${STATE_DIR}/last_restart_attempt"
CURL_TIMEOUT=10

# ---- Runtime flags ---------------------------------------------------------
TEST=0
ONE_SHOT=0
DEBUG=0

# Holds the PID of the background sleep process during the main loop so that
# handle_shutdown can kill it promptly on SIGTERM/SIGINT.
SLEEP_PID=""

# ---- Utility functions -----------------------------------------------------

usage() {
  cat >&2 <<EOF
Usage: $0 [-t] [-1] [-d] [-f config_file] [-i seconds] [-n threshold] [-c ping_count]
Options:
  -t    Test mode: never restart services.
  -1    One-shot mode: run one check cycle and exit.
  -d    Debug mode: print classifications and tailscale ping output to stdout.
  -f    Config file path. Default: ${CONFIG_FILE}.
  -i    Check interval in seconds. Default: ${CHECK_INTERVAL}.
  -n    Consecutive relayed checks required before restart. Default: ${FAIL_THRESHOLD}.
  -c    tailscale ping count. Default: ${PING_COUNT}.
EOF
}

is_positive_int() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$1" -gt 0 ] 2>/dev/null
}

log_msg() {
  logger -t "$TAG" "$*"
  if [ "$DEBUG" -eq 1 ]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  fi
}

debug_msg() {
  if [ "$DEBUG" -eq 1 ]; then
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
  fi
}

# config_is_safe_to_source FILE
#
# Verifies that FILE is:
#   - a regular file
#   - owned by root
#   - not group-writable or world-writable
#
# Uses stat(1) rather than parsing ls(1) output, which avoids fragile
# positional pattern matching on permission strings that vary across systems
# and can include ACL indicator characters.
#
# stat -f '%Su' returns the owning username.
# stat -f '%Lp' returns the numeric permission bits in octal as a 3- or
# 4-digit string (e.g. "600", "644", "755").  The leading-zero form
# $(( 0$octal & 022 )) causes the shell to interpret the value as octal
# without requiring the non-POSIX 8# base prefix.
config_is_safe_to_source() {
  file="$1"

  if [ ! -f "$file" ]; then
    echo "Config file is not a regular file: $file" >&2
    return 1
  fi

  if ! command -v stat >/dev/null 2>&1; then
    echo "stat(1) not found; cannot verify config file permissions" >&2
    return 1
  fi

  owner="$(stat -f '%Su' "$file" 2>/dev/null)"
  if [ "$owner" != "root" ]; then
    echo "Config file must be owned by root: $file (current owner: ${owner:-unknown})" >&2
    echo "Run: chown root:wheel $file" >&2
    return 1
  fi

  # '%Lp' returns the numeric permission bits in octal, e.g. "600" or "644".
  octal="$(stat -f '%Lp' "$file" 2>/dev/null)"

  # Validate that stat returned a well-formed octal string before using it in
  # arithmetic.  Accept 3- or 4-digit strings composed of octal digits only.
  case "$octal" in
    [0-7][0-7][0-7]|[0-7][0-7][0-7][0-7])
      ;;
    *)
      echo "Could not determine permissions for config file: $file (stat returned: '${octal}')" >&2
      return 1
      ;;
  esac

  # Mask 022: group-write (020) and world-write (002).
  # The leading zero causes the shell to interpret $octal as octal.
  if [ "$(( 0${octal} & 022 ))" -ne 0 ]; then
    echo "Config file must not be group-writable or world-writable: $file (mode: ${octal})" >&2
    echo "Run: chmod 0600 $file" >&2
    return 1
  fi

  return 0
}

load_config_file() {
  file="$1"
  if [ ! -e "$file" ]; then
    return 0
  fi
  if ! config_is_safe_to_source "$file"; then
    exit 2
  fi
  # Shell-style config file.  Sourcing executes arbitrary shell code; the
  # ownership and permission checks above are the primary guard against
  # unintended execution.
  . "$file"
  # Prevent the sourced file from altering command lookup behavior.
  PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
  return 0
}

validate_config() {
  if [ -z "$PEERS" ]; then
    echo "PEERS must not be empty" >&2
    exit 2
  fi

  # Validate each peer name and check for post-sanitization collisions in a
  # single pass.
  #
  # Character validation: Tailscale Magic DNS names are standard DNS hostnames;
  # allow alphanumerics, hyphens, underscores, and dots only.  This prevents
  # shell metacharacter injection when peer names are word-split from $PEERS
  # and passed verbatim to tailscale ping.
  #
  # Collision detection: safe_peer_name maps several distinct peer names to
  # the same shell variable name (e.g. "router-a", "router.a", and "router_a"
  # all become "router_a").  Two peers that collide after sanitization would
  # silently share the same in-memory relay counter, producing incorrect
  # restart decisions.  The seen_safe list uses space-delimited membership
  # testing to detect this before the daemon starts.
  _seen_safe=""
  for _vpeer in $PEERS; do
    case "$_vpeer" in
      *[!A-Za-z0-9._-]*)
        echo "Invalid peer name (contains shell-unsafe characters): ${_vpeer}" >&2
        exit 2
        ;;
    esac
    _vsafe="$(safe_peer_name "$_vpeer")"
    case " ${_seen_safe} " in
      *" ${_vsafe} "*)
        echo "Invalid peer list: '${_vpeer}' collides with another peer after sanitization as '${_vsafe}'" >&2
        exit 2
        ;;
    esac
    _seen_safe="${_seen_safe} ${_vsafe}"
  done
  unset _vpeer _vsafe _seen_safe

  if ! is_positive_int "$CHECK_INTERVAL"; then
    echo "CHECK_INTERVAL must be a positive integer: $CHECK_INTERVAL" >&2
    exit 2
  fi
  if ! is_positive_int "$FAIL_THRESHOLD"; then
    echo "FAIL_THRESHOLD must be a positive integer: $FAIL_THRESHOLD" >&2
    exit 2
  fi
  if ! is_positive_int "$PING_COUNT"; then
    echo "PING_COUNT must be a positive integer: $PING_COUNT" >&2
    exit 2
  fi
  if ! is_positive_int "$RESTART_COOLDOWN"; then
    echo "RESTART_COOLDOWN must be a positive integer: $RESTART_COOLDOWN" >&2
    exit 2
  fi
  if ! is_positive_int "$CURL_TIMEOUT"; then
    echo "CURL_TIMEOUT must be a positive integer: $CURL_TIMEOUT" >&2
    exit 2
  fi
  if [ -z "$RESTART_SERVICES" ]; then
    echo "RESTART_SERVICES must not be empty" >&2
    exit 2
  fi
}

notify() {
  message="$1"
  if [ -z "$PUSHOVER_TOKEN" ] || [ -z "$PUSHOVER_USER" ]; then
    log_msg "Pushover notification skipped: token or user key is empty"
    return 0
  fi
  if ! command -v curl >/dev/null 2>&1; then
    log_msg "Pushover notification failed: curl not found"
    return 1
  fi
  # Note: --form-string passes credentials as multipart/form-data fields,
  # which are transiently visible in the process table.  On pfSense the
  # process table is readable only by root, so the practical exposure is low.
  if ! curl -fsS --max-time "$CURL_TIMEOUT" \
    --form-string "token=${PUSHOVER_TOKEN}" \
    --form-string "user=${PUSHOVER_USER}" \
    --form-string "message=${message}" \
    https://api.pushover.net/1/messages.json >/dev/null 2>&1
  then
    log_msg "Pushover notification failed"
    return 1
  fi
  return 0
}

# ---- Per-peer variable helpers ---------------------------------------------
#
# Peer state is stored in plain shell variables named:
#   tsw_<attr>_<safe_peer_name>
#
# safe_peer_name replaces every character outside [A-Za-z0-9_] with an
# underscore so the composed variable name is always a valid shell identifier.
#
# get_peer_attr and set_peer_attr use eval only to expand or assign a variable
# whose name is constructed from the validated, sanitized components above.
# In get_peer_attr the default value is applied outside eval so that an
# attacker-controlled default string cannot be executed as shell code.

safe_peer_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_]/_/g'
}

peer_var() {
  attr="$1"
  peer="$2"
  safe="$(safe_peer_name "$peer")"
  printf 'tsw_%s_%s' "$attr" "$safe"
}

get_peer_attr() {
  attr="$1"
  peer="$2"
  default="$3"
  var="$(peer_var "$attr" "$peer")"
  # Eval expands only the named variable into _gpa_tmp.
  # The default is applied afterward in plain shell so that the default
  # argument is never passed to eval and cannot be executed as code.
  eval "_gpa_tmp=\"\${${var}}\""
  if [ -z "$_gpa_tmp" ]; then
    printf '%s\n' "$default"
  else
    printf '%s\n' "$_gpa_tmp"
  fi
}

set_peer_attr() {
  attr="$1"
  peer="$2"
  value="$3"
  var="$(peer_var "$attr" "$peer")"
  eval "${var}=\$value"
}

reset_all_peer_state_after_restart() {
  for peer in $PEERS; do
    set_peer_attr count "$peer" 0
    set_peer_attr state "$peer" post_restart
    set_peer_attr threshold_seen "$peer" none
  done
}

# ---- Restart cooldown state ------------------------------------------------

# last_restart_epoch NOW
#
# Reads the cooldown state file and returns the epoch timestamp of the last
# restart attempt, or 0 if none is recorded.
#
# NOW must be passed in by the caller (the current epoch from date '+%s') so
# that the future-timestamp check uses the same reference point as the
# elapsed-time calculation in cooldown_remaining, avoiding a race if the
# clock second rolls over between two separate date calls.
#
# If the file contains a future timestamp (corrupt or manually edited), 0 is
# returned and the cooldown is treated as not active.  Returning 0 rather than
# clamping to NOW is important: clamping would cause cooldown_remaining to
# compute elapsed = NOW - NOW = 0, which is less than RESTART_COOLDOWN, and
# would impose a full cooldown window on every call for as long as the corrupt
# file exists.
last_restart_epoch() {
  now="$1"
  if [ ! -r "$LAST_RESTART_FILE" ]; then
    printf '0\n'
    return
  fi
  value="$(cat "$LAST_RESTART_FILE" 2>/dev/null)"
  case "$value" in
    ''|*[!0-9]*)
      printf '0\n'
      return
      ;;
  esac
  if [ "$value" -gt "$now" ]; then
    log_msg "Warning: last restart timestamp is in the future (${value} > ${now}); ignoring cooldown state"
    printf '0\n'
  else
    printf '%s\n' "$value"
  fi
}

cooldown_remaining() {
  now="$(date '+%s')"
  # Pass now to last_restart_epoch so both functions use the same reference
  # point and a clock-second rollover between two date calls cannot produce
  # a spurious negative elapsed value.
  last="$(last_restart_epoch "$now")"
  elapsed=$((now - last))

  # A negative elapsed value means the system clock moved backward (NTP step
  # correction, VM resume, etc.).  Treat it as zero elapsed rather than
  # computing a large spurious cooldown that blocks restarts.
  if [ "$elapsed" -lt 0 ]; then
    log_msg "Warning: clock skew detected (elapsed=${elapsed}s since last restart); ignoring cooldown"
    printf '0\n'
    return
  fi

  if [ "$elapsed" -lt "$RESTART_COOLDOWN" ]; then
    printf '%s\n' $((RESTART_COOLDOWN - elapsed))
  else
    printf '0\n'
  fi
}

mark_restart_attempt() {
  if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    log_msg "Could not create state directory: ${STATE_DIR}"
    return 1
  fi
  # Write only on an actual restart attempt so that normal healthy operation
  # causes no disk writes.  A failure here is logged but not fatal: the
  # consequence is that cooldown persistence is lost across this attempt,
  # which is preferable to blocking the restart entirely.
  if ! date '+%s' > "$LAST_RESTART_FILE" 2>/dev/null; then
    log_msg "Could not write restart cooldown state: ${LAST_RESTART_FILE}"
    return 1
  fi
  return 0
}

# ---- Tailscale path classification -----------------------------------------
#
# Classification policy:
#
#   direct:
#     At least one "pong from ... via ..." line exists that is not DERP and
#     not peer-relay.  This handles the common case where initial pongs use
#     DERP and later pongs upgrade to a direct path.
#
#   relayed:
#     One or more pongs used DERP or peer-relay, and no direct pong appeared.
#
#   unknown:
#     No usable pong path was found (timeout, peer offline, parse failure).

classify_ping_output() {
  awk '
    /^pong from / && / via / {
      if ($0 ~ / via DERP/ || $0 ~ / via peer-relay/) {
        relayed = 1
      } else {
        direct = 1
      }
    }
    END {
      if (direct) {
        print "direct"
      } else if (relayed) {
        print "relayed"
      } else {
        print "unknown"
      }
    }
  '
}

check_peer_path() {
  peer="$1"
  output="$(tailscale ping -c "$PING_COUNT" "$peer" 2>&1)"
  rc=$?
  class="$(printf '%s\n' "$output" | classify_ping_output)"
  if [ "$DEBUG" -eq 1 ]; then
    debug_msg "peer=${peer} class=${class} tailscale_ping_rc=${rc}"
    printf '%s\n' "$output" | sed 's/^/  /'
  fi
  printf '%s\n' "$class"
}

# ---- Restart handling ------------------------------------------------------

restart_tailscale_services() {
  reason_peer="$1"
  reason_count="$2"
  failures=0

  log_msg "Restarting Tailscale services after peer ${reason_peer} was relayed for ${reason_count} consecutive checks"

  # Write the cooldown timestamp only on an actual restart attempt so that
  # normal healthy operation causes no disk writes.
  mark_restart_attempt

  for svc in $RESTART_SERVICES; do
    output="$(service "$svc" restart 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      log_msg "Service restarted successfully: ${svc}"
    else
      failures=$((failures + 1))
      log_msg "Service restart FAILED: ${svc}; rc=${rc}; output=${output}"
    fi
  done

  if [ "$failures" -eq 0 ]; then
    msg="Tailscale watchdog: restarted ${RESTART_SERVICES} after peer ${reason_peer} was relayed for ${reason_count} consecutive checks."
    log_msg "$msg"
    notify "$msg"
    # Reset peer state only on a successful restart.  Preserving the counter
    # on failure means the watchdog can retry as soon as the cooldown expires
    # without waiting for another full FAIL_THRESHOLD cycle to accumulate.
    reset_all_peer_state_after_restart
    return 0
  fi

  msg="Tailscale watchdog: restart FAILED after peer ${reason_peer} was relayed for ${reason_count} consecutive checks."
  log_msg "$msg"
  notify "$msg"
  # Peer state is intentionally not reset here; see comment above.
  return 1
}

maybe_restart_for_peer() {
  peer="$1"
  count="$2"

  if [ "$count" -lt "$FAIL_THRESHOLD" ]; then
    return 0
  fi

  if [ "$TEST" -eq 1 ]; then
    seen="$(get_peer_attr threshold_seen "$peer" none)"
    if [ "$seen" != "test" ]; then
      log_msg "TEST MODE: peer ${peer} reached ${count}/${FAIL_THRESHOLD} relayed checks; would restart ${RESTART_SERVICES}"
      set_peer_attr threshold_seen "$peer" test
    fi
    return 0
  fi

  remaining="$(cooldown_remaining)"
  if [ "$remaining" -gt 0 ]; then
    seen="$(get_peer_attr threshold_seen "$peer" none)"
    if [ "$seen" != "cooldown" ]; then
      log_msg "Peer ${peer} reached ${count}/${FAIL_THRESHOLD} relayed checks, but restart is suppressed by cooldown for ${remaining} more seconds"
      set_peer_attr threshold_seen "$peer" cooldown
    fi
    return 0
  fi

  restart_tailscale_services "$peer" "$count"
  return $?
}

# ---- Per-peer state machine ------------------------------------------------

handle_direct() {
  peer="$1"
  count="$(get_peer_attr count "$peer" 0)"
  state="$(get_peer_attr state "$peer" unknown)"

  case "$state" in
    direct)
      # No state change; suppress log noise during sustained healthy operation.
      ;;
    relayed|post_restart)
      log_msg "Peer ${peer} is direct (was ${state}; relay counter was ${count})"
      ;;
    *)
      # Covers 'unknown' and the implicit empty state on daemon startup.
      log_msg "Peer ${peer} is direct (initial classification; was: ${state})"
      ;;
  esac

  set_peer_attr count "$peer" 0
  set_peer_attr state "$peer" direct
  set_peer_attr threshold_seen "$peer" none
}

handle_relayed() {
  peer="$1"
  count="$(get_peer_attr count "$peer" 0)"
  count=$((count + 1))
  set_peer_attr count "$peer" "$count"
  set_peer_attr state "$peer" relayed
  log_msg "Peer ${peer} is relayed; consecutive relayed checks=${count}/${FAIL_THRESHOLD}"
  maybe_restart_for_peer "$peer" "$count"
}

handle_unknown() {
  peer="$1"
  count="$(get_peer_attr count "$peer" 0)"
  state="$(get_peer_attr state "$peer" unknown)"

  if [ "$count" -gt 0 ]; then
    log_msg "Peer ${peer} path is unknown; breaking relayed sequence and resetting counter from ${count}"
  elif [ "$state" != "unknown" ]; then
    log_msg "Peer ${peer} path is unknown (was ${state})"
  fi

  # An unknown result resets the consecutive-relayed counter.  A transient
  # connectivity loss should not be accumulated toward the restart threshold.
  set_peer_attr count "$peer" 0
  set_peer_attr state "$peer" unknown
  set_peer_attr threshold_seen "$peer" none
}

check_peer() {
  peer="$1"
  class="$(check_peer_path "$peer")"
  case "$class" in
    direct)
      handle_direct "$peer"
      ;;
    relayed)
      handle_relayed "$peer"
      ;;
    *)
      handle_unknown "$peer"
      ;;
  esac
}

check_all_peers() {
  for peer in $PEERS; do
    check_peer "$peer"
  done
}

# ---- Signal handling -------------------------------------------------------

handle_shutdown() {
  log_msg "Daemon stopping"
  # Kill the background sleep process, if present, so the daemon exits
  # promptly rather than waiting up to CHECK_INTERVAL seconds.
  if [ -n "$SLEEP_PID" ]; then
    kill "$SLEEP_PID" 2>/dev/null
    SLEEP_PID=""
  fi
  exit 0
}

# ---- Config path pre-scan --------------------------------------------------
#
# The config file must be loaded before normal option parsing so that
# config-file values are in place when command-line overrides are applied.
# This requires a dedicated pre-scan pass to find any -f argument before
# getopts runs.
#
# Design note: if -f is supplied, the config at that path is loaded during
# this pre-scan.  The getopts block below also captures -f into CONFIG_FILE
# for logging consistency but does not reload the file.  Clustered short
# options (e.g. -df) are not supported; -f must be supplied as a separate
# flag (e.g. -d -f /path/to/config).
next_is_config=0
for arg in "$@"; do
  if [ "$next_is_config" -eq 1 ]; then
    CONFIG_FILE="$arg"
    next_is_config=0
    continue
  fi
  case "$arg" in
    -f)
      next_is_config=1
      ;;
    -f*)
      CONFIG_FILE="${arg#-f}"
      ;;
  esac
done
unset next_is_config arg

load_config_file "$CONFIG_FILE"

# ---- Option parsing --------------------------------------------------------
OPTIND=1
while getopts "t1df:i:n:c:h" opt; do
  case "$opt" in
    t)
      TEST=1
      ;;
    1)
      ONE_SHOT=1
      ;;
    d)
      DEBUG=1
      ;;
    f)
      CONFIG_FILE="$OPTARG"
      # The config file was already loaded during the pre-scan above.
      # This assignment keeps CONFIG_FILE consistent for the startup log message.
      ;;
    i)
      if ! is_positive_int "$OPTARG"; then
        echo "Invalid interval: $OPTARG" >&2
        usage
        exit 2
      fi
      CHECK_INTERVAL="$OPTARG"
      ;;
    n)
      if ! is_positive_int "$OPTARG"; then
        echo "Invalid threshold: $OPTARG" >&2
        usage
        exit 2
      fi
      FAIL_THRESHOLD="$OPTARG"
      ;;
    c)
      if ! is_positive_int "$OPTARG"; then
        echo "Invalid ping count: $OPTARG" >&2
        usage
        exit 2
      fi
      PING_COUNT="$OPTARG"
      ;;
    h|*)
      usage
      exit 2
      ;;
  esac
done
shift $((OPTIND - 1))

if [ "$#" -ne 0 ]; then
  usage
  exit 2
fi

validate_config

trap handle_shutdown INT TERM

log_msg "Daemon started: config=${CONFIG_FILE} peers=\"${PEERS}\" interval=${CHECK_INTERVAL}s threshold=${FAIL_THRESHOLD} ping_count=${PING_COUNT} cooldown=${RESTART_COOLDOWN}s test=${TEST}"

if [ "$ONE_SHOT" -eq 1 ]; then
  check_all_peers
  exit 0
fi

while :; do
  check_all_peers
  # Background the sleep and use wait so that SIGTERM/SIGINT is delivered
  # promptly rather than being deferred until the sleep interval expires.
  # POSIX guarantees traps are checked when wait returns; FreeBSD sh delivers
  # the signal to the process group, causing wait to return immediately.
  sleep "$CHECK_INTERVAL" &
  SLEEP_PID=$!
  wait $SLEEP_PID
  SLEEP_PID=""
done
