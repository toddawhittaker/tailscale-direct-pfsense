# Architecture

`tailscale-direct-pfsense` is intentionally small: a foreground daemon, an rc.d wrapper, an installer, an uninstaller, one example config, and shell-native tests.

The project targets pfSense CE 2.7, which is based on FreeBSD 14. That choice drives the design:

- `/bin/sh` keeps the scripts available on the target system.
- FreeBSD rc.d is the service model, not systemd.
- The daemon stays foreground-only. The rc.d wrapper owns backgrounding, pidfile management, startup diagnostics, and stop behavior.
- Runtime state is minimal and lives under `/var/run/tailscale_watchdog`.
- Healthy/direct operation avoids per-check disk writes.

The base version is worth stating explicitly because the scripts depend on FreeBSD userland behavior that has no Linux equivalent and can differ across FreeBSD releases: `stat -f '%Su'` and `'%Lp'` for the config permission gate, `jot` for the randomized cooldown, and `netstat -ibn` for interface byte counters. CI pins its FreeBSD VM to 14.0 for that reason; when the supported pfSense base moves, that pin and this page should move with it.

## Installed Components

The installer places:

- `/usr/local/sbin/tailscale_watchdogd`: foreground daemon.
- `/usr/local/etc/rc.d/tailscale_watchdog`: rc.d wrapper.
- `/usr/local/etc/rc.d/tailscale_watchdog.sh`: pfSense boot hook, a thin pass-through to the wrapper.
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

When `INTERFACE_GROUP_REPAIR_ENABLED=1`, each cycle also runs `ifconfig tailscale0` before the peer checks. If the interface has lost the `Tailscale` interface group, the daemon re-adds it and runs `/etc/rc.filter_configure_sync`. This check is independent of peer classification, restart, cooldown, and deferral; see `docs/daemon-behavior.md`.

Notifications are dispatched through a provider selector. Pushover is the current provider, and restart/startup notification paths call only the generic `notify` entry point. Future providers should be added behind that dispatch boundary so restart behavior, cooldown behavior, and service control do not need to change.

## pfSense Boot Model

pfSense does not boot `/usr/local/etc/rc.d` the FreeBSD way: it does not run `rcorder` there, and its boot code does not consult `rc.conf.local` itself (`service(8)` does, when the hook calls it). `/etc/rc.start_packages` runs each `/usr/local/etc/rc.d/*.sh` as `<file> start` in the background, and `/etc/rc.stop_packages` runs each as `<file> stop`. The rc.d wrapper has no `.sh` suffix, so the boot hook `tailscale_watchdog.sh` exists to be found. It hands the command to `service(8)`, so the `tailscale_watchdog_enable` check still applies. pfSense also re-runs `rc.start_packages` after boot, so `start` can arrive while the daemon runs; the wrapper treats that as a no-op because its pidfile points at a live process.

The enable check applies to `stop` as well. A daemon started by hand with `onestart` while the service is not enabled is therefore not stopped by `rc.stop_packages`; the hook's `stop` prints rc.subr's "Cannot 'stop'" notice into `/tmp/bootup_messages` and leaves it running. That is deliberate: the hook adds no rcvar bypass, and at shutdown the process dies regardless. Use `service tailscale_watchdog onestop` to stop such a daemon by hand.

## Install And Upgrade Model

The installer downloads over HTTPS, syntax-checks staged shell files, and installs with a temp file plus `mv`. This avoids exposing partially written scripts at installed paths.

The installer does not enable, start, stop, or restart the watchdog service. During an upgrade, a running daemon continues using the old script content until the operator restarts the service.

The uninstaller uses `service tailscale_watchdog onestop` so it can stop the service even if the rcvar is disabled. It removes project files and runtime state, but preserves the live config by default unless the operator explicitly removes it.

## Documentation Split

Keep `README.md` focused on operator tasks: install, configure, test, enable, update, uninstall, and troubleshoot.

Keep maintainer rationale here in `docs/`. This prevents the README from becoming an audit trail while still preserving why safety decisions exist.
