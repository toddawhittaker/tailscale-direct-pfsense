#!/bin/sh
#
# uninstall.sh — Uninstaller for tailscale-direct-pfsense
#
# Removes the Tailscale watchdog daemon and its rc wrapper from pfSense.
# Optionally removes the live config file after asking the operator.
#
# Documentation:
#   https://github.com/toddawhittaker/tailscale-direct-pfsense
#
# Usage (as root):
#   VERSION=v1.2.0
#   curl -fsSL \
#     "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/uninstall.sh" \
#     | /bin/sh
#
# Or, to review before running (recommended):
#   VERSION=v1.2.0
#   curl -fsSL \
#     "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/uninstall.sh" \
#     -o /tmp/uninstall.sh
#   less /tmp/uninstall.sh
#   /bin/sh /tmp/uninstall.sh
#
# What this script does:
#   1. Verifies it is running as root on pfSense.
#   2. Stops the service if it is running (using onestop to bypass rcvar).
#   3. Removes all tailscale_watchdog_* lines from rc.conf.local.
#   4. Removes the daemon, rc wrapper, example config, and runtime state.
#   5. Asks interactively whether to remove the live config file.
#   6. Reports any files it could not remove.
#
# This script does not remove the Tailscale package itself, only the
# watchdog daemon and its associated files.

# ---- Environment -----------------------------------------------------------

# Set a known-safe PATH so that service, sed, stat, and other tools are
# found consistently regardless of how root invoked this uninstaller.
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
export PATH

# ---- No set -e -------------------------------------------------------------
#
# set -e is intentionally not used here.  The uninstaller must continue past
# individual failures (a missing file, a service that is already stopped) and
# report them rather than aborting.  Every operation is checked explicitly.
#
# The installer used set -e because a failure mid-install leaves the system
# in a partially configured state and aborting is safer.  The uninstaller
# has the opposite property: partial removal is better than no removal.

# ---- Constants -------------------------------------------------------------

# SERVICE_NAME must be defined before PIDFILE so the variable expansion
# in the PIDFILE assignment resolves correctly.
STATE_DIR="/var/run/tailscale_watchdog"
RCCONF_LOCAL="/etc/rc.conf.local"
SERVICE_NAME="tailscale_watchdog"
PIDFILE="/var/run/${SERVICE_NAME}.pid"
DOCS_URL="https://github.com/toddawhittaker/tailscale-direct-pfsense"

DAEMON_DST="/usr/local/sbin/tailscale_watchdogd"
RC_DST="/usr/local/etc/rc.d/tailscale_watchdog"
CONF_DST_EXAMPLE="/usr/local/etc/tailscale_watchdog.conf.example"
CONF_DST_LIVE="/usr/local/etc/tailscale_watchdog.conf"

# ---- Tracking --------------------------------------------------------------

# Count operations that could not be completed so a summary can be printed
# at the end.  The uninstaller never aborts mid-run.
WARNINGS=0
ERRORS=0

# Set to 1 in stop_service if the daemon appears to still be running after
# all stop attempts.  Consulted in remove_files to avoid removing the pidfile
# while the daemon is still alive, which would leave an untrackable process.
SERVICE_STILL_RUNNING=0

# ---- Helper functions ------------------------------------------------------

# info MESSAGE...
#
# Prints a normal uninstaller progress line to stdout.
info() {
  printf '[INFO]  %s\n' "$*"
}

# ok MESSAGE...
#
# Prints a successful cleanup step.
ok() {
  printf '[OK]    %s\n' "$*"
}

# warn MESSAGE...
#
# Prints a non-fatal cleanup issue and increments the warning counter so the
# final summary reflects that operator review is needed.
warn() {
  printf '[WARN]  %s\n' "$*"
  WARNINGS=$((WARNINGS + 1))
}

# error MESSAGE...
#
# Prints a failed cleanup operation and increments the error counter.  The
# uninstaller continues after errors so it can remove whatever is still safe
# to remove.
error() {
  printf '[ERROR] %s\n' "$*" >&2
  ERRORS=$((ERRORS + 1))
}

# error_detail MESSAGE...
#
# Prints follow-up context for the most recent error without inflating the
# error count.  Use this for manual remediation commands.
error_detail() {
  printf '[ERROR] %s\n' "$*" >&2
}

# header TITLE
#
# Prints a section heading for operator readability.
header() {
  printf '\n--- %s\n' "$*"
}

# valid_pid VALUE
#
# Returns 0 if VALUE is a plausible process ID: a positive integer greater
# than 1.  Returns 1 otherwise.
#
# Applied to every PID read from the pidfile before it is passed to kill(1).
# Without this guard, a corrupt or maliciously crafted pidfile could cause
# kill to receive a negative value or zero, which on some implementations
# sends a signal to a process group or all processes visible to the caller.
# Since this script runs as root, that risk is not acceptable.
#
# PID 0 and PID 1 are refused because this daemon should never occupy either
# slot, and sending signals to them would be destructive.
valid_pid() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$1" -gt 1 ] 2>/dev/null
}

# remove_file PATH
#
# Removes PATH if it exists.  Reports success, absence, or failure.
# Never aborts; a failed removal is counted as an error.
#
# Both [ -e ] and [ -L ] are checked because [ -e ] returns false for a
# broken symlink (the target does not exist, so stat fails), which would
# cause a broken symlink to be silently reported as absent and left behind.
# [ -L ] returns true for any symlink, broken or not.  rm -f handles
# regular files, valid symlinks, and broken symlinks correctly.
remove_file() {
  path="$1"
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    info "Already absent: ${path}"
    return 0
  fi
  if rm -f "$path" 2>/dev/null; then
    ok "Removed: ${path}"
  else
    error "Failed to remove: ${path}"
    error_detail "  Remove it manually: rm -f ${path}"
  fi
}

# remove_dir PATH
#
# Removes PATH if it exists and is empty.  If the directory is non-empty,
# warns and leaves it in place rather than forcibly removing runtime state
# the operator may want to inspect.
remove_dir() {
  path="$1"
  if [ ! -d "$path" ]; then
    info "Already absent: ${path}"
    return 0
  fi
  if [ -n "$(ls -A "$path" 2>/dev/null)" ]; then
    warn "Directory is not empty and was left in place: ${path}"
    warn "  Remove it manually if no longer needed: rm -rf ${path}"
    return 0
  fi
  if rmdir "$path" 2>/dev/null; then
    ok "Removed empty directory: ${path}"
  else
    error "Failed to remove directory: ${path}"
    error_detail "  Remove it manually: rmdir ${path}"
  fi
}

# ---- Preflight checks ------------------------------------------------------

# preflight_checks
#
# Verifies root and pfSense context before removal.  A missing installation
# is warning-only so the uninstaller can clean up partial installs.
preflight_checks() {
  header "Preflight checks"

  if [ "$(id -u)" -ne 0 ]; then
    printf '[ERROR] This uninstaller must be run as root.\n' >&2
    exit 1
  fi
  ok "Running as root."

  if [ -f /etc/platform ]; then
    platform="$(cat /etc/platform 2>/dev/null)"
    case "$platform" in
      pfSense*)
        ok "Platform detected: ${platform}"
        ;;
      *)
        printf '[ERROR] This uninstaller is intended for pfSense only.\n' >&2
        printf '[ERROR] Detected platform: %s\n' "$platform" >&2
        exit 1
        ;;
    esac
  elif [ -f /etc/inc/globals.inc ]; then
    ok "Platform detected: pfSense (via /etc/inc/globals.inc)"
  else
    printf '[ERROR] Cannot confirm this is a pfSense installation.\n' >&2
    exit 1
  fi

  # Warn if nothing appears to be installed, but do not abort.  The operator
  # may be cleaning up a partial installation.  Check for both regular files
  # and symlinks so that a symlink at either path is recognised as present,
  # consistent with how remove_file handles the same question.
  if [ ! -e "$DAEMON_DST" ] && [ ! -L "$DAEMON_DST" ] && \
     [ ! -e "$RC_DST" ]     && [ ! -L "$RC_DST" ]; then
    warn "Neither ${DAEMON_DST} nor ${RC_DST} found."
    warn "  The watchdog may not be installed on this system."
    warn "  Continuing to clean up any remaining files."
  fi
}

# ---- Stop and disable the service ------------------------------------------

# stop_service
#
# Attempts to stop the watchdog and remove only this project's rc.conf.local
# assignments.  It uses onestop so cleanup works even when the rcvar is not
# enabled, then validates pidfile state before deciding whether removal can
# continue safely.
stop_service() {
  header "Stopping and disabling service"

  # Use onestop rather than stop.  The plain stop action checks the rcvar
  # (tailscale_watchdog_enable) and does nothing if the service is disabled
  # or the variable is absent.  onestop bypasses that check and attempts to
  # stop the process regardless of whether the service is currently enabled.
  # For an uninstaller, stopping regardless of enable state is correct.
  if [ -f "$RC_DST" ]; then
    info "Stopping ${SERVICE_NAME} (onestop)..."
    if service "$SERVICE_NAME" onestop 2>/dev/null; then
      ok "Service stopped."
    else
      # onestop can return non-zero if the service was not running.
      # Validate the pidfile to determine the actual process state rather
      # than treating the exit code as definitive.
      pid="$(cat "$PIDFILE" 2>/dev/null)"
      if valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
        error "Service may still be running as pid ${pid}."
        error_detail "  Stop it manually: service ${SERVICE_NAME} onestop"
        error_detail "  Then re-run this uninstaller."
        SERVICE_STILL_RUNNING=1
      else
        ok "Service was not running."
      fi
    fi
  else
    info "rc wrapper not found; skipping service stop."
    # Still check whether the daemon process is running via the pidfile,
    # in case the rc wrapper was already removed in a partial uninstall.
    pid="$(cat "$PIDFILE" 2>/dev/null)"
    if valid_pid "$pid" && kill -0 "$pid" 2>/dev/null; then
      warn "Daemon process appears to be running as pid ${pid} but rc wrapper is absent."
      warn "  Stop it manually: kill -TERM ${pid}"
      SERVICE_STILL_RUNNING=1
    fi
  fi

  # Remove all tailscale_watchdog_* settings from rc.conf.local.
  # This covers tailscale_watchdog_enable, tailscale_watchdog_flags,
  # tailscale_watchdog_command, tailscale_watchdog_pidfile, and any other
  # variables the operator may have added with the service name prefix.
  #
  # sed is used instead of grep -v because grep -v returns exit code 1 when
  # no lines are selected (e.g. if the file contains only the enable line and
  # nothing else).  sed returns 0 regardless of whether any lines matched.
  if [ -f "$RCCONF_LOCAL" ]; then
    if grep -q "^[[:space:]]*${SERVICE_NAME}_" "$RCCONF_LOCAL" 2>/dev/null; then
      info "Removing ${SERVICE_NAME}_* settings from ${RCCONF_LOCAL}..."

      # Write the filtered content to a temp file in the same directory so
      # that the final mv is an atomic same-filesystem rename.  This prevents
      # truncating rc.conf.local if the write fails mid-stream.
      rcconf_tmp="$(mktemp "${RCCONF_LOCAL}.XXXXXX")" || {
        error "Failed to create temp file for editing ${RCCONF_LOCAL}."
        error_detail "  Remove the settings manually by editing ${RCCONF_LOCAL}"
        error_detail "  and deleting any line beginning with ${SERVICE_NAME}_"
        return 0
      }

      # Delete all assignment lines beginning with the service name prefix.
      # The pattern matches lines of the form:
      #   [whitespace]tailscale_watchdog_<identifier>[whitespace]=
      # This covers all rc.conf variables for this service without matching
      # unrelated lines that merely mention the service name in a comment
      # or value.
      if sed "/^[[:space:]]*${SERVICE_NAME}_[A-Za-z0-9_]*[[:space:]]*=/d" \
           "$RCCONF_LOCAL" > "$rcconf_tmp" 2>/dev/null; then

        # Preserve the original permissions and ownership of rc.conf.local.
        orig_mode="$(stat -f '%Lp' "$RCCONF_LOCAL" 2>/dev/null)"
        orig_owner="$(stat -f '%Su:%Sg' "$RCCONF_LOCAL" 2>/dev/null)"

        if mv "$rcconf_tmp" "$RCCONF_LOCAL" 2>/dev/null; then
          # Restoring mode and ownership is best effort: a failure here must
          # not abort the rest of the uninstall, which is why each call keeps
          # its `|| true`.
          if [ -n "$orig_mode" ]; then
            chmod "0${orig_mode}" "$RCCONF_LOCAL" 2>/dev/null || true
          fi
          if [ -n "$orig_owner" ]; then
            chown "$orig_owner" "$RCCONF_LOCAL" 2>/dev/null || true
          fi
          ok "Removed ${SERVICE_NAME}_* settings from ${RCCONF_LOCAL}."
        else
          rm -f "$rcconf_tmp" 2>/dev/null || true
          error "Failed to update ${RCCONF_LOCAL}."
          error_detail "  Remove the settings manually by editing ${RCCONF_LOCAL}"
          error_detail "  and deleting any line beginning with ${SERVICE_NAME}_"
        fi
      else
        rm -f "$rcconf_tmp" 2>/dev/null || true
        error "Failed to filter ${RCCONF_LOCAL}."
        error_detail "  Remove the settings manually by editing ${RCCONF_LOCAL}"
        error_detail "  and deleting any line beginning with ${SERVICE_NAME}_"
      fi
    else
      info "No ${SERVICE_NAME}_* settings found in ${RCCONF_LOCAL}."
    fi
  else
    info "${RCCONF_LOCAL} does not exist; nothing to remove from it."
  fi
}

# ---- Remove installed files ------------------------------------------------

# remove_files
#
# Removes installed project files and runtime state.  The pidfile is left in
# place if the daemon may still be running so the process does not become
# untrackable.
remove_files() {
  header "Removing installed files"

  remove_file "$DAEMON_DST"
  remove_file "$RC_DST"
  remove_file "$CONF_DST_EXAMPLE"

  # Remove runtime state files.  Both filenames are attempted to handle
  # upgrades from earlier versions of the daemon:
  #   next_restart_allowed  — written by current and future versions
  remove_file "${STATE_DIR}/next_restart_allowed"
  remove_dir  "$STATE_DIR"

  if [ "$SERVICE_STILL_RUNNING" -eq 1 ]; then
    warn "Leaving pidfile in place because the daemon may still be running: ${PIDFILE}"
    warn "  After stopping the daemon manually, remove it: rm -f ${PIDFILE}"
  else
    remove_file "$PIDFILE"
  fi
}

# ---- Ask about live config -------------------------------------------------

# ask_remove_live_config
#
# Gives the operator an explicit choice before deleting the private live
# config.  In non-interactive contexts it preserves the file because silently
# deleting credentials is riskier than leaving them for manual cleanup.
ask_remove_live_config() {
  header "Live configuration file"

  # Check for both a regular file and any symlink (including broken symlinks).
  # [ -f ] returns false for a broken symlink because the target does not
  # exist; [ -L ] catches any symlink regardless of whether the target exists.
  # rm -f handles both cases correctly.
  if [ ! -f "$CONF_DST_LIVE" ] && [ ! -L "$CONF_DST_LIVE" ]; then
    info "Live config not found: ${CONF_DST_LIVE}"
    info "Nothing to remove."
    return 0
  fi

  info "Found live config: ${CONF_DST_LIVE}"
  info "This file contains your peer names and Pushover credentials."
  info "Removing it is permanent."
  printf '\n'

  # Loop until we get a clear yes or no.  Read from /dev/tty directly so
  # the prompt works even when the script is piped through sh from curl
  # (where stdin is the pipe, not the terminal).
  #
  # If /dev/tty is not available (truly non-interactive environment),
  # default to preserving the config.  Destroying credentials silently
  # is worse than leaving them in place.
  while true; do
    printf 'Remove live config file %s? [y/N] ' "$CONF_DST_LIVE"

    if read -r answer < /dev/tty 2>/dev/null; then
      case "$answer" in
        [Yy]|[Yy][Ee][Ss])
          remove_file "$CONF_DST_LIVE"
          return 0
          ;;
        [Nn]|[Nn][Oo]|'')
          ok "Live config preserved: ${CONF_DST_LIVE}"
          info "Remove it manually when no longer needed:"
          info "  rm -f ${CONF_DST_LIVE}"
          return 0
          ;;
        *)
          printf '  Please answer y or n.\n'
          ;;
      esac
    else
      printf '\n'
      warn "Cannot read from terminal; defaulting to preserving live config."
      warn "  Remove it manually if desired: rm -f ${CONF_DST_LIVE}"
      return 0
    fi
  done
}

# ---- Summary ---------------------------------------------------------------

# print_summary
#
# Reports accumulated warnings and errors after all cleanup attempts.  This
# function does not mutate the counters; the summary must reflect work already
# attempted.
print_summary() {
  header "Uninstallation summary"

  if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    ok "Uninstallation completed with no errors or warnings."
  elif [ "$ERRORS" -eq 0 ]; then
    ok "Uninstallation completed with ${WARNINGS} warning(s)."
    # Use printf rather than warn() here so that printing the summary does
    # not increment WARNINGS after the count has already been reported.
    printf '[WARN]  Review the warnings above and address any items marked [WARN].\n'
  else
    printf '[ERROR] Uninstallation completed with %s error(s) and %s warning(s).\n' \
      "$ERRORS" "$WARNINGS" >&2
    printf '[ERROR] Review the output above and resolve items marked [ERROR].\n' >&2
  fi

  printf '\n'
  info "The Tailscale package itself was not removed."
  info "To remove Tailscale, use the pfSense package manager."
  info "Documentation: ${DOCS_URL}"
  printf '\n'
}

# ---- Main ------------------------------------------------------------------

# main
#
# Runs the uninstaller phases in an order that stops the daemon before file
# removal, preserves or deletes live config last, and always prints a final
# operator summary.
main() {
  printf '\n'
  printf '%s\n' "============================================================"
  printf '%s\n' " Tailscale Direct Watchdog — Uninstaller"
  printf ' Documentation: %s\n' "$DOCS_URL"
  printf '%s\n' "============================================================"

  preflight_checks
  stop_service
  remove_files
  ask_remove_live_config
  print_summary
}

main "$@"
