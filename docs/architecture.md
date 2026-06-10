# Architecture

`tailscale-direct-pfsense` is intentionally small: a foreground daemon, an rc.d wrapper, an installer, an uninstaller, one example config, and shell-native tests.

The project targets pfSense on FreeBSD. That choice drives the design:

- `/bin/sh` keeps the scripts available on the target system.
- FreeBSD rc.d is the service model, not systemd.
- The daemon stays foreground-only. The rc.d wrapper owns backgrounding, pidfile management, startup diagnostics, and stop behavior.
- Runtime state is minimal and lives under `/var/run/tailscale_watchdog`.
- Healthy/direct operation avoids per-check disk writes.

## Installed Components

The installer places:

- `/usr/local/sbin/tailscale_watchdogd`: foreground daemon.
- `/usr/local/etc/rc.d/tailscale_watchdog`: rc.d wrapper.
- `/usr/local/etc/tailscale_watchdog.conf.example`: reference config.
- `/usr/local/etc/tailscale_watchdog.conf`: private live config, created only when missing.

The live config may contain notification credentials, so it is expected to be `root:wheel` and mode `0600`. The daemon refuses to source configs with unsafe ownership or permissions.

## Runtime Model

The daemon loops over configured peers and runs `tailscale ping`. It classifies each result as direct, relayed, or unknown. Only consecutive relayed classifications count toward restart eligibility.

Restart impact is global to local Tailscale connectivity, even when one peer triggers the threshold. For that reason:

- cooldown is global, not per peer;
- restart deferral is global, not per peer;
- successful restart resets all peer counters;
- failed restart leaves counters intact so retry can happen after cooldown.

The rc.d wrapper runs the daemon in the background and writes `/var/run/tailscale_watchdog.pid`. It validates pidfile contents before signaling so corrupt or malicious pidfile data cannot be passed to `kill`.

Notifications are dispatched through a provider selector. Pushover is the current provider, and the restart flow calls only the generic `notify` entry point. Future providers should be added behind that dispatch boundary so restart behavior, cooldown behavior, and service control do not need to change.

## Install And Upgrade Model

The installer downloads over HTTPS, syntax-checks staged shell files, and installs with a temp file plus `mv`. This avoids exposing partially written scripts at installed paths.

The installer does not enable, start, stop, or restart the watchdog service. During an upgrade, a running daemon continues using the old script content until the operator restarts the service.

The uninstaller uses `service tailscale_watchdog onestop` so it can stop the service even if the rcvar is disabled. It removes project files and runtime state, but preserves the live config by default unless the operator explicitly removes it.

## Documentation Split

Keep `README.md` focused on operator tasks: install, configure, test, enable, update, uninstall, and troubleshoot.

Keep maintainer rationale here in `docs/`. This prevents the README from becoming an audit trail while still preserving why safety decisions exist.
