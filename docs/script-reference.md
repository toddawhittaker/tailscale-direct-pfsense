# Script Reference

This document explains the role of each script and the safety behavior it owns.

## `tailscale_watchdogd`

The daemon is foreground-only. It validates the config file, checks peers, classifies paths, manages in-memory peer counters, applies cooldown and deferral gates, restarts configured services, and sends optional provider-based notifications.

Why it stays foreground:

- rc.d already has the service lifecycle model;
- tests can source daemon functions with `TAILSCALE_WATCHDOG_TESTING=1`;
- foreground behavior avoids hidden daemonization branches.

Important safety choices:

- config is sourced only after root ownership and private permissions are verified;
- peer and service names are validated before command use;
- notification secrets are passed to `curl` through config on stdin, not process arguments;
- cooldown state is written before restart attempts;
- unknown ping output breaks the relayed sequence;
- healthy checks avoid persistent state writes.

Notifications use a small provider dispatcher. `notify` remains the restart and startup notification entry point, and provider-specific functions such as `notify_pushover` own their own secret handling and curl payload shape. New providers should add validation, docs, and fake-command tests without changing restart flow.

## `tailscale_watchdog`

The rc.d wrapper adapts the foreground daemon to pfSense/FreeBSD service management.

It owns:

- backgrounding the daemon;
- writing and validating the pidfile;
- capturing startup output long enough to report early failures;
- stopping with TERM before escalating to KILL;
- removing stale or invalid pidfiles safely.

The wrapper intentionally does not pass debug mode through default service flags. Debug output is for direct foreground test runs.

## `install.sh`

The installer is a root script, so it is deliberately conservative.

It owns:

- pfSense/root preflight checks;
- HTTPS-only downloads from GitHub;
- shell syntax validation before install;
- atomic installation using temp files in destination directories and `mv`;
- live config preservation;
- secure ownership and permissions.

It does not enable, start, stop, or restart the service. Operators must review config and start or restart the service themselves.

## `uninstall.sh`

The uninstaller removes this project without removing Tailscale itself.

It owns:

- stopping the watchdog with `onestop`;
- removing only this project's rc.conf assignments;
- removing installed daemon, rc wrapper, example config, pidfile, and runtime state;
- asking before removing the live config;
- preserving the live config when no TTY is available.

It avoids `set -e` so one failed removal does not prevent later cleanup. Errors and warnings are accumulated for the final summary.

## `tailscale_watchdog.conf.example`

The example config is both documentation and executable shell syntax. Keep it generic and non-secret.

It should show safe defaults and all supported knobs without including real peer names, tokens, local hostnames, or private network details.
