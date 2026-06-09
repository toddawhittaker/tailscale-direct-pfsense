#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

cd "$REPO_ROOT" || exit 1

assert_success "syntax: tailscale_watchdogd" sh -n tailscale_watchdogd
assert_success "syntax: tailscale_watchdog" sh -n tailscale_watchdog
assert_success "syntax: tailscale_watchdog.conf.example" sh -n tailscale_watchdog.conf.example
assert_success "syntax: install.sh" sh -n install.sh
assert_success "syntax: uninstall.sh" sh -n uninstall.sh
