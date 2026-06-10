# Testing

The test suite is shell-native and side-effect safe. It exists to protect pfSense/FreeBSD behavior without requiring pfSense for every development check.

Run:

```sh
make smoke
make test
```

Always syntax-check shell files after changing them:

```sh
sh -n tailscale_watchdogd
sh -n tailscale_watchdog
sh -n tailscale_watchdog.conf.example
sh -n install.sh
sh -n uninstall.sh
```

## Test Strategy

Tests source `tailscale_watchdogd` with:

```sh
TAILSCALE_WATCHDOG_TESTING=1
```

That exposes functions without starting the daemon loop.

Tests use temporary directories and fake commands in a temporary `PATH` for commands such as:

- `tailscale`
- `service`
- `logger`
- `curl`
- `date`
- `jot`
- `netstat`
- `sleep`

This keeps tests from restarting real services, sending real notifications, reading live router state, or depending on local Tailscale connectivity.

## Coverage Areas

Current tests cover:

- shell syntax smoke checks;
- ping output classification fixtures;
- hostile config validation;
- cooldown state reading and writing;
- restart flow with fake services;
- restart deferral with fake interface counters;
- notification handling with fake `curl`;
- per-peer state transitions;
- installer, uninstaller, rc wrapper, and docs static safety checks.

## What Tests Must Not Do

Do not run these from tests unless explicitly authorized for a live-system exercise:

```sh
./install.sh
./uninstall.sh
service tailscale_watchdog start
service tailscale_watchdog stop
service tailscale_watchdog restart
service tailscale_watchdog onestop
service tailscaled restart
service pfsense_tailscaled restart
tailscale ping
```

If a behavior needs one of those commands, fake it in a temporary `PATH`.
