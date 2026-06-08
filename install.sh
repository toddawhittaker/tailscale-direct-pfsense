#!/bin/sh
#
# install.sh — Installer for tailscale-direct-pfsense
#
# Installs the Tailscale watchdog daemon and its rc wrapper on pfSense.
#
# Usage (as root):
#   curl -fsSL \
#     https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/install.sh \
#     | /bin/sh
#
# Or, to review before running (recommended):
#   curl -fsSL \
#     https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/install.sh \
#     -o /tmp/install.sh
#   less /tmp/install.sh
#   /bin/sh /tmp/install.sh
#
# What this script does:
#   1. Verifies it is running as root on pfSense.
#   2. Checks that Tailscale is installed, and warns if it is not currently connected.
#   3. Downloads the daemon, rc wrapper, and example config from GitHub.
#   4. Validates each downloaded file with sh -n (syntax check).
#   5. Installs files atomically (temp file + mv) with correct permissions.
#   6. Does NOT overwrite an existing live config file.
#   7. Enforces safe ownership and permissions on an existing live config.
#   8. Does NOT enable or start the service; that is left to the operator.
#   9. Prints a next-steps summary.
#
# Security model (please read):
#
#   This installer downloads files over HTTPS from GitHub and installs them
#   as root.  Its security depends entirely on:
#
#     1. HTTPS transport integrity (GitHub's TLS certificate).
#     2. The integrity of the GitHub repository itself.
#     3. The security of the repository owner's GitHub account.
#
#   There is no cryptographic signing of release artifacts.  For a personal
#   router project, this is a deliberate and documented tradeoff: adding GPG
#   or minisign signatures would require operators to install additional tools
#   and manage a trust anchor, which is disproportionate overhead for this
#   use case.
#
#   What this means practically:
#     - If GitHub's HTTPS certificate is compromised, this installer is unsafe.
#     - If the GitHub repository is compromised, this installer is unsafe.
#     - SHA256 sums committed to the same repo would not improve this, because
#       an attacker who can push to the repo can update both files and sums
#       together.  They were deliberately omitted for this reason.
#
#   If this risk is unacceptable for your environment, review and install the
#   files manually instead of using this script.

# ---- Environment -----------------------------------------------------------

# Set a known-safe PATH so that curl, tailscale, service, and other tools
# are found consistently regardless of how root invoked this installer.
PATH="/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin"
export PATH

# Set a restrictive umask so that any files created by this script (including
# files in the staging directory before explicit chmod calls) are not
# world-readable by default.  The staging directory itself is created with
# mktemp -d (mode 0700), but umask 077 provides an additional safety net for
# any intermediate writes.
umask 077

# ---- Strict error handling -------------------------------------------------
#
# Exit immediately on error.  This is a safety net; every critical operation
# also has an explicit || die check so that the failure message identifies the
# exact step that failed.
#
# Note: set -e does not trigger inside if-conditions, after ||, or in some
# command substitution contexts.  Explicit checks are used throughout for
# anything that matters.
set -e

# ---- Constants -------------------------------------------------------------

# Repository coordinates.
#
# VERSION is the git ref used to construct download URLs.  This defaults to
# "main" for development convenience.  For production use, pin this to a
# specific release tag (e.g. "v1.0.0") or a full 40-character commit SHA so
# that the installed files cannot change without the installer changing first.
#
# To install a specific version:
#   curl -fsSL .../install.sh | VERSION=v1.0.0 /bin/sh
REPO_OWNER="toddawhittaker"
REPO_NAME="tailscale-direct-pfsense"
VERSION="${VERSION:-main}"

BASE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${VERSION}"

# Installation destinations.
DAEMON_SRC="tailscale_watchdogd"
DAEMON_DST="/usr/local/sbin/tailscale_watchdogd"
DAEMON_MODE="0755"

RC_SRC="tailscale_watchdog"
RC_DST="/usr/local/etc/rc.d/tailscale_watchdog"
RC_MODE="0755"

CONF_SRC="tailscale_watchdog.conf.example"
CONF_DST_EXAMPLE="/usr/local/etc/tailscale_watchdog.conf.example"
CONF_DST_LIVE="/usr/local/etc/tailscale_watchdog.conf"
CONF_MODE="0600"

# rc.conf.local is one common place for rc.conf-style settings on pfSense.
# Verify that this path persists across upgrades for your pfSense workflow.
RCCONF_LOCAL="/etc/rc.conf.local"

# ---- Pre-install state snapshot --------------------------------------------
#
# Capture whether the live config already exists BEFORE install_files runs.
# install_files and print_next_steps both consult this flag; by the time
# either function runs the file will exist regardless, so the snapshot must
# be taken here at the top level.
#
# Reject a symlink at the live config path.  [ -f ] returns true for a
# symlink to a regular file, so the symlink check must come first.  A root
# installer should refuse unexpected filesystem state rather than silently
# follow a symlink to an unintended location.
#
# Also reject any non-regular-file (directory, device node, etc.) at the
# live config path, since that would cause confusing failures later.
if [ -L "$CONF_DST_LIVE" ]; then
  printf '[ERROR] Live config path must not be a symlink: %s\n' \
    "$CONF_DST_LIVE" >&2
  printf '[ERROR] Replace it with a regular root-owned file before running this installer.\n' >&2
  exit 2
fi

if [ -e "$CONF_DST_LIVE" ] && [ ! -f "$CONF_DST_LIVE" ]; then
  printf '[ERROR] Live config path exists but is not a regular file: %s\n' \
    "$CONF_DST_LIVE" >&2
  printf '[ERROR] Remove or rename it before running this installer.\n' >&2
  exit 2
fi

if [ -f "$CONF_DST_LIVE" ]; then
  LIVE_CONFIG_PREEXISTED=1
else
  LIVE_CONFIG_PREEXISTED=0
fi

# ---- Staging directory -----------------------------------------------------
#
# All downloads land in a private mktemp directory.  FreeBSD mktemp -d
# creates the directory with mode 0700, accessible only by root.
# The cleanup trap removes it on exit regardless of success or failure.
STAGE_DIR=""

cleanup() {
  if [ -n "$STAGE_DIR" ] && [ -d "$STAGE_DIR" ]; then
    rm -rf "$STAGE_DIR"
  fi
}
trap cleanup EXIT

# ---- Helper functions ------------------------------------------------------

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  printf '[ERROR] Installation aborted.\n' >&2
  exit 1
}

info() {
  printf '[INFO]  %s\n' "$*"
}

ok() {
  printf '[OK]    %s\n' "$*"
}

warn() {
  printf '[WARN]  %s\n' "$*"
}

header() {
  printf '\n--- %s\n' "$*"
}

# fetch_file URL DEST
#
# Downloads URL to DEST.  Fails clearly if:
#   - the HTTP response indicates an error (-f flag)
#   - the download times out
#   - the resulting file is empty
#
# --proto '=https' and --proto-redir '=https' restrict both the initial
# connection and any redirects to HTTPS only.  This keeps the installer
# aligned with its stated security model: HTTPS transport integrity.
# If the installed version of curl does not support these flags, the
# command will fail loudly, which is preferable to silently allowing a
# downgrade to HTTP for a root installer.
#
# Certificate validation is always on.  -k / --insecure is never used.
fetch_file() {
  url="$1"
  dest="$2"

  info "Downloading: ${url}"

  if ! curl -fsSL \
      --proto '=https' \
      --proto-redir '=https' \
      --max-time 30 \
      --retry 2 \
      --retry-delay 3 \
      "$url" \
      -o "$dest" 2>&1
  then
    die "Download failed: ${url}
  Check your internet connection and that the repository exists at:
  https://github.com/${REPO_OWNER}/${REPO_NAME}"
  fi

  if [ ! -s "$dest" ]; then
    die "Downloaded file is empty: ${url}
  This may mean the file does not exist at the specified VERSION (${VERSION})."
  fi

  ok "Downloaded: $(basename "$dest") ($(wc -c < "$dest" | tr -d ' ') bytes)"
}

# validate_shell_syntax FILE LABEL
#
# Runs sh -n on FILE to check for shell syntax errors before installation.
# LABEL is used in output to describe what kind of file is being checked.
#
# This catches obviously malformed downloads (truncated files, HTML error
# pages served as content, etc.) but is not a security guarantee: a
# syntactically valid file can still contain malicious code.
#
# sh -n reads the file but does not execute it, so no execute permission
# is needed.  The staged files are in a root-only directory (mode 0700)
# and have not yet had their final permissions applied.
#
# Called for all three downloaded files:
#   - The daemon and rc wrapper are executed directly as shell scripts.
#   - The config example is sourced by the daemon as shell code, so it
#     must also be syntactically valid shell.
validate_shell_syntax() {
  file="$1"
  label="$2"
  name="$(basename "$file")"

  if ! /bin/sh -n "$file" 2>/dev/null; then
    # Run again without suppressing stderr to show the error to the operator.
    /bin/sh -n "$file" >&2 || true
    die "Shell syntax check failed for ${name} (${label}).
  The downloaded file may be truncated, corrupt, or an HTML error page.
  Do not install files that fail syntax checking."
  fi

  ok "Syntax check passed: ${name} (${label})"
}

# install_file SRC DST MODE
#
# Installs SRC to DST atomically using a temp file and mv.
#
# The temp file is created in the same directory as DST so that the final
# mv is a rename within the same filesystem, which is atomic on POSIX
# systems.  This means a running process that has DST open keeps its file
# descriptor pointing to the old inode; only new opens after the mv see
# the updated file.  For a running shell daemon, this prevents the partial-
# read corruption that can occur when cp overwrites a file in place while
# the shell is executing it.
#
# Each step that can fail cleans up the temp file before calling die so
# that no partial file is left behind in the destination directory.
install_file() {
  src="$1"
  dst="$2"
  mode="$3"

  dst_dir="$(dirname "$dst")"
  dst_base="$(basename "$dst")"

  if [ ! -d "$dst_dir" ]; then
    info "Creating directory: ${dst_dir}"
    mkdir -p "$dst_dir" \
      || die "Failed to create directory: ${dst_dir}"
  fi

  # Guard against a directory or other non-file at the destination path.
  if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
    die "Destination path exists but is not a regular file or symlink: ${dst}"
  fi

  # Create the temp file in the same directory as the destination so that
  # the mv is a same-filesystem rename.
  tmp_dst="$(mktemp "${dst_dir}/.${dst_base}.install.XXXXXX")" \
    || die "Failed to create temporary install file in ${dst_dir}"

  cp "$src" "$tmp_dst" \
    || { rm -f "$tmp_dst"; die "Failed to copy ${src} to ${tmp_dst}"; }

  chmod "$mode" "$tmp_dst" \
    || { rm -f "$tmp_dst"; die "Failed to set permissions ${mode} on ${tmp_dst}"; }

  chown root:wheel "$tmp_dst" \
    || { rm -f "$tmp_dst"; die "Failed to set ownership root:wheel on ${tmp_dst}"; }

  # Atomic rename.  After this point DST refers to the new inode.
  mv -f "$tmp_dst" "$dst" \
    || { rm -f "$tmp_dst"; die "Failed to move ${tmp_dst} into place at ${dst}"; }

  # Verify the final installed file has the expected permissions and owner.
  actual_mode="$(stat -f '%Lp' "$dst" 2>/dev/null)"
  actual_owner="$(stat -f '%Su' "$dst" 2>/dev/null)"

  # stat -f '%Lp' may return with or without a leading zero; normalise by
  # stripping a single leading zero for comparison.
  expected_stripped="${mode#0}"
  if [ "$actual_mode" != "$expected_stripped" ] && \
     [ "$actual_mode" != "$mode" ]; then
    die "Permission verification failed for ${dst}: expected ${mode}, got ${actual_mode}"
  fi

  if [ "$actual_owner" != "root" ]; then
    die "Ownership verification failed for ${dst}: expected root, got ${actual_owner}"
  fi

  ok "Installed: ${dst} (mode ${mode}, owner root:wheel)"
}

# check_rc_provide_token SERVICE_NAME
#
# Checks whether an rc.d script declares a PROVIDE token exactly matching
# SERVICE_NAME.  Parses only the tokens listed after the "# PROVIDE:" marker
# to avoid false matches on substrings in comments or filenames.
check_rc_provide_token() {
  svc="$1"
  found=""

  while IFS= read -r provide_line; do
    tokens="${provide_line#*PROVIDE:}"
    for token in $tokens; do
      if [ "$token" = "$svc" ]; then
        found="$provide_line"
        break 2
      fi
    done
  done << EOF
$(grep -rh "^# PROVIDE:" /etc/rc.d /usr/local/etc/rc.d 2>/dev/null || true)
EOF

  if [ -n "$found" ]; then
    ok "PROVIDE token found for '${svc}': $(printf '%s' "$found" | head -1)"
  else
    warn "No PROVIDE token found for '${svc}'."
    warn "  If '${svc}' is not rc.d-managed, remove it from the"
    warn "  REQUIRE line in ${RC_DST}."
  fi
}

# ---- Preflight checks ------------------------------------------------------

preflight_checks() {
  header "Preflight checks"

  if [ "$(id -u)" -ne 0 ]; then
    die "This installer must be run as root.
  Re-run as root or with: sudo /bin/sh install.sh"
  fi
  ok "Running as root."

  if [ -f /etc/platform ]; then
    platform="$(cat /etc/platform 2>/dev/null)"
    case "$platform" in
      pfSense*)
        ok "Platform detected: ${platform}"
        ;;
      *)
        die "This installer is intended for pfSense only.
  Detected platform: '${platform}' in /etc/platform."
        ;;
    esac
  elif [ -f /etc/inc/globals.inc ]; then
    ok "Platform detected: pfSense (via /etc/inc/globals.inc)"
  else
    die "Cannot confirm this is a pfSense installation.
  /etc/platform not found and /etc/inc/globals.inc not found."
  fi

  if ! command -v curl >/dev/null 2>&1; then
    die "curl is not installed.
  Install the curl package via the pfSense package manager and re-run."
  fi
  ok "curl found: $(command -v curl)"

  if ! command -v tailscale >/dev/null 2>&1; then
    die "tailscale CLI not found.
  Install the Tailscale package in pfSense before running this installer."
  fi
  ok "tailscale CLI found: $(command -v tailscale)"

  if ! command -v tailscaled >/dev/null 2>&1; then
    die "tailscaled not found.
  Install the Tailscale package in pfSense before running this installer."
  fi
  ok "tailscaled found: $(command -v tailscaled)"

  if ! tailscale status >/dev/null 2>&1; then
    warn "tailscale status returned an error."
    warn "  The watchdog will not function until Tailscale is"
    warn "  authenticated and connected.  Continuing installation."
  else
    ok "Tailscale is running and connected."
  fi
}

# ---- Download files --------------------------------------------------------

download_files() {
  header "Downloading files (VERSION=${VERSION})"

  STAGE_DIR="$(mktemp -d "/tmp/tailscale_watchdog_install.XXXXXX")" \
    || die "Failed to create staging directory under /tmp."
  ok "Staging directory: ${STAGE_DIR}"

  fetch_file "${BASE_URL}/${DAEMON_SRC}" "${STAGE_DIR}/${DAEMON_SRC}"
  fetch_file "${BASE_URL}/${RC_SRC}"     "${STAGE_DIR}/${RC_SRC}"
  fetch_file "${BASE_URL}/${CONF_SRC}"   "${STAGE_DIR}/${CONF_SRC}"
}

# ---- Validate downloaded files ---------------------------------------------

validate_files() {
  header "Validating downloaded files"

  validate_shell_syntax "${STAGE_DIR}/${DAEMON_SRC}" "daemon"
  validate_shell_syntax "${STAGE_DIR}/${RC_SRC}"     "rc wrapper"
  validate_shell_syntax "${STAGE_DIR}/${CONF_SRC}"   "config example (sourced as shell)"

  # Confirm we received the right config file and not an HTML error page
  # that happened to pass the syntax check.
  if ! grep -q "^PEERS=" "${STAGE_DIR}/${CONF_SRC}" 2>/dev/null; then
    die "Downloaded config example does not contain a PEERS= line.
  The file may be incorrect or the repository structure may have changed."
  fi
  ok "Config example sanity check passed."
}

# ---- Warn if upgrading while service is running ----------------------------
#
# Called after validate_files so that we only warn about a running service
# if we are actually about to install valid files.

warn_if_service_running() {
  header "Service status check"

  if service tailscale_watchdog status >/dev/null 2>&1; then
    warn "tailscale_watchdog is currently running."
    warn "  This installer will update files but will NOT restart the service."
    warn "  The running daemon will continue using the old version until"
    warn "  you restart it manually after reviewing the config:"
    warn "    service tailscale_watchdog restart"
  else
    ok "tailscale_watchdog is not currently running."
  fi
}

# ---- Install files ---------------------------------------------------------

install_files() {
  header "Installing files"

  install_file \
    "${STAGE_DIR}/${DAEMON_SRC}" \
    "$DAEMON_DST" \
    "$DAEMON_MODE"

  install_file \
    "${STAGE_DIR}/${RC_SRC}" \
    "$RC_DST" \
    "$RC_MODE"

  # Always update the example config so the operator can see new options
  # added in this version.
  install_file \
    "${STAGE_DIR}/${CONF_SRC}" \
    "$CONF_DST_EXAMPLE" \
    "$CONF_MODE"

  if [ "$LIVE_CONFIG_PREEXISTED" -eq 1 ]; then
    # Preserve the operator's config but enforce safe ownership and
    # permissions.  The daemon refuses to source a config that is not
    # root-owned and mode 0600; silently wrong permissions would cause a
    # confusing startup failure.  Changing metadata is safe: the file
    # contents are not modified.
    chown root:wheel "$CONF_DST_LIVE" \
      || die "Failed to set ownership root:wheel on existing live config: ${CONF_DST_LIVE}"
    chmod "$CONF_MODE" "$CONF_DST_LIVE" \
      || die "Failed to set permissions ${CONF_MODE} on existing live config: ${CONF_DST_LIVE}"
    ok "Existing live config preserved and permissions enforced: ${CONF_DST_LIVE}"
    info "Compare with the updated example to check for new options:"
    info "  diff ${CONF_DST_LIVE} ${CONF_DST_EXAMPLE}"
  else
    install_file \
      "${STAGE_DIR}/${CONF_SRC}" \
      "$CONF_DST_LIVE" \
      "$CONF_MODE"
    info "A starter config was installed at ${CONF_DST_LIVE}."
    info "Edit it before enabling the service."
  fi
}

# ---- rc.d dependency check -------------------------------------------------

check_rc_deps() {
  header "Checking rc.d PROVIDE tokens for REQUIRE dependencies"

  if [ ! -f "$RC_DST" ]; then
    warn "rc wrapper not found at ${RC_DST}; skipping REQUIRE inspection."
    return 0
  fi

  require_line="$(grep "^# REQUIRE:" "$RC_DST" 2>/dev/null | head -1 || true)"

  if [ -z "$require_line" ]; then
    warn "No REQUIRE line found in installed rc wrapper."
    return 0
  fi

  info "Installed rc wrapper declares: ${require_line}"
  info ""

  # Parse the tokens after "# REQUIRE:" and check each one that is not a
  # well-known system pseudo-token.  This avoids spurious warnings for
  # tokens like NETWORKING that are provided by the base system and do not
  # have individual rc.d scripts.
  tokens="${require_line#*REQUIRE:}"
  for token in $tokens; do
    case "$token" in
      NETWORKING|FILESYSTEMS|SERVERS|DAEMON|LOGIN)
        # System pseudo-token provided by the base rc framework; skip.
        continue
        ;;
    esac
    check_rc_provide_token "$token"
  done

  info ""
  info "If a token is missing, edit the REQUIRE line in ${RC_DST}."
}

# ---- Next steps ------------------------------------------------------------

print_next_steps() {
  header "Installation complete"

  cat <<EOF

Files installed:
  ${DAEMON_DST}
  ${RC_DST}
  ${CONF_DST_EXAMPLE}  (reference copy, updated to this version)

EOF

  if [ "$LIVE_CONFIG_PREEXISTED" -eq 1 ]; then
    cat <<EOF
Your existing live config was preserved and permissions were enforced:
  ${CONF_DST_LIVE}

Compare it with the updated example to check for new options:
  diff ${CONF_DST_LIVE} ${CONF_DST_EXAMPLE}

EOF
  else
    cat <<EOF
A starter config was installed:
  ${CONF_DST_LIVE}

Edit it before enabling the service.

EOF
  fi

  cat <<EOF
Next steps:

  1. Edit the config file:

       vi ${CONF_DST_LIVE}

     Required: set PEERS to the Tailscale hostnames you want to monitor.
     Optional: set PUSHOVER_TOKEN and PUSHOVER_USER for notifications.
     The config file must remain owned by root and mode 0600.

  2. Verify the REQUIRE dependencies in the rc wrapper (see output above).
     If the reported PROVIDE tokens do not match, edit:

       vi ${RC_DST}

     and adjust the REQUIRE line near the top.

  3. Test the daemon directly before enabling it as a service:

       ${DAEMON_DST} -t -1 -d

     You should see peer classification output on stderr.
     Use -t (test mode) so no services are restarted during testing.

  4. Enable the service by editing ${RCCONF_LOCAL}:

       vi ${RCCONF_LOCAL}

     Add or update this line:

       tailscale_watchdog_enable="YES"

  5. Start the service:

       service tailscale_watchdog start

  6. Verify it started and check the logs:

       service tailscale_watchdog status

       # pfSense circular log (preferred):
       clog /var/log/system.log | grep tailscale_watchdog | tail -20

       # Fallback if clog is not available:
       grep tailscale_watchdog /var/log/system.log | tail -20

  Note: ${RCCONF_LOCAL} is one common place for rc.conf-style settings.
  Verify that this path persists across upgrades for your pfSense workflow.
  After a firmware upgrade, re-run this installer or manually re-add the
  enable line shown in step 4 if needed.

EOF
}

# ---- Main ------------------------------------------------------------------

main() {
  printf '\n'
  printf '%s\n' "============================================================"
  printf '%s\n' " Tailscale Direct Watchdog — Installer"
  printf ' %s/%s @ %s\n' "$REPO_OWNER" "$REPO_NAME" "$VERSION"
  printf '%s\n' "============================================================"

  preflight_checks
  download_files
  validate_files
  warn_if_service_running
  install_files
  check_rc_deps
  print_next_steps
}

main "$@"