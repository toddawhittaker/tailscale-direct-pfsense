#!/bin/sh

set -u

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "${SCRIPT_DIR}/.." && pwd)

. "${SCRIPT_DIR}/lib/testlib.sh"

TAILSCALE_WATCHDOG_TESTING=1
export TAILSCALE_WATCHDOG_TESTING
. "${REPO_ROOT}/tailscale_watchdogd"

classify_fixture() {
  classify_ping_output < "${SCRIPT_DIR}/fixtures/$1"
}

assert_eq "direct pong classifies as direct" \
  "direct" "$(classify_fixture ping_direct.txt)"

assert_eq "DERP-only pong classifies as relayed" \
  "relayed" "$(classify_fixture ping_derp.txt)"

assert_eq "peer-relay pong classifies as relayed" \
  "relayed" "$(classify_fixture ping_peer_relay.txt)"

assert_eq "unknown output classifies as unknown" \
  "unknown" "$(classify_fixture ping_unknown.txt)"

assert_eq "mixed DERP and direct output classifies as direct" \
  "direct" "$(classify_fixture ping_mixed_direct.txt)"
