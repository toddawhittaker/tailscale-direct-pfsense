# AGENTS.md

## Scope

`tailscale-direct-pfsense` is a small pfSense/FreeBSD watchdog for Tailscale direct connectivity.

Primary repo files: `tailscale_watchdogd`, `tailscale_watchdog` rc.d wrapper, `tailscale_watchdog.conf.example`, `install.sh`, `uninstall.sh`, `README.md`, `LICENSE`.

* `/usr/local/sbin/tailscale_watchdogd`
* `/usr/local/etc/rc.d/tailscale_watchdog`
* `/usr/local/etc/tailscale_watchdog.conf`
* `/usr/local/etc/tailscale_watchdog.conf.example`

## Non-Negotiables

* Keep the project shell-only, small, auditable, and pfSense/FreeBSD-oriented.
* Target `/bin/sh`, FreeBSD userland, and rc.d; do not assume Bash, GNU coreutils, systemd, Linux service paths, package managers, compiled code, Python, Node, Go, containers, or GUI integration.
* Runtime dependencies must stay limited to expected pfSense/FreeBSD tools plus Tailscale.
* Do not introduce Bashisms: arrays, `[[ ... ]]`, process substitution, `${var//...}`, or `function name { ... }`.
* Do not introduce GNU-specific options unless verified on FreeBSD/pfSense.
* Use generic examples such as `router1 router2`; never include private peer names, auth keys, tokens, hostnames, local network names, or identifying logs.

## Shell Style

Prefer:

* Quoted variables, explicit error handling, small functions, `case` validation.
* `mktemp` for temp files.
* Atomic installs/updates via temp file in destination directory plus `mv`.
* `logger` for daemon/service logs.
* PID files or command-specific mechanisms over parsing `ps`.

Avoid:

* Unquoted variables, Linux-only paths, noisy healthy-state writes, clever shell abstractions, and secrets in examples.

## Security Rules

This touches router services; be conservative.

Do not auto-enable/start service from the installer, run live install/uninstall/service/Tailscale restart commands without authorization, add telemetry, add network calls beyond documented downloads and optional Pushover, print secrets, make live config world-readable, store Pushover secrets outside live config, or replace live config without preserving it.

Permissions: daemon, rc wrapper, installer, uninstaller are root-owned executables.

* Live config: `root:wheel`, mode `0600`.
* Example config: non-secret, readable.
* Runtime state: `/var/run/tailscale_watchdog`.

## Daemon Invariants

Preserve watchdog behavior:

* Direct path is healthy.
* Sustained DERP/relay-only paths count as failures.
* Unknown/no usable path is not relayed and breaks the consecutive-relay sequence.
* Restart configured Tailscale services only after `FAIL_THRESHOLD` consecutive relayed classifications for a peer.
* Restart cooldown uses `RESTART_COOLDOWN_MIN` and `RESTART_COOLDOWN_MAX`.
* Active cooldown state file: `/var/run/tailscale_watchdog/next_restart_allowed`.
* Restart deferral, when enabled, is global, bounded, and must not write cooldown state unless a restart is actually attempted.
* Healthy/direct checks should not create or update runtime state files every check.
* Successful restart resets peer relay counters.
* Failed restart leaves counters intact so retry can happen after cooldown.
* Signal handling should stop the loop promptly, including active sleep.

## rc.d Wrapper Invariants

Installed path: `/usr/local/etc/rc.d/tailscale_watchdog`.

Preserve headers: `# PROVIDE: tailscale_watchdog`, `# REQUIRE: NETWORKING tailscaled pfsense_tailscaled`, `# KEYWORD: shutdown`.

The wrapper must run the daemon in the background, maintain and validate a PID file, avoid stale PID hazards, stop with TERM before escalation, avoid passing debug mode through normal service flags, and fail visibly if startup fails.

## Installer / Uninstaller

Installer must require root, verify pfSense/FreeBSD where practical, download over HTTPS only, syntax-check shell files before installing, install atomically, preserve any live config, install the example config, set secure ownership/permissions, avoid enabling/starting service automatically, and print clear next steps.

Uninstaller must require root, stop with `onestop` where appropriate, remove installed daemon/wrapper/example config, ask before deleting live config, preserve live config by default without a TTY, remove project runtime state including `next_restart_allowed` and old compatibility files, remove only this project’s rc.conf entries, and never uninstall Tailscale.

## Testing and Testable Code

Tests must be `/bin/sh`, shell-native, small, and side-effect safe. Do not introduce Bashisms, Python, Node, Go, containers, or heavyweight frameworks.

Use fixtures, temp directories, fake commands in temporary `PATH`, and static checks. Do not write outside the repo or `/tmp`.

Preferred commands:

```sh
make smoke
make test
```

Tests must not run real live operations unless explicitly authorized:

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

When testing command behavior, fake `tailscale`, `service`, `logger`, `curl`, `date`, or similar tools in a temporary `PATH`.

Write testable shell: pure parsing functions where practical, small side-effect wrappers, overridable paths/state files, and behavior-preserving test guards such as `TAILSCALE_WATCHDOG_TESTING=1`.

Add fixture tests for ping parsing changes, temp-file tests for cooldown/state changes, and static or fake-command tests for installer, uninstaller, and rc.d wrapper safety behavior.

## Validation / Definition of Done

Before calling shell changes complete, run safe checks for changed areas.

Always run these when shell files change:

```sh
sh -n tailscale_watchdogd
sh -n tailscale_watchdog
sh -n tailscale_watchdog.conf.example
sh -n install.sh
sh -n uninstall.sh
```

Run `make smoke` / `make test` when tests exist or behavior changes. `shellcheck` may help, but do not treat it as authoritative for pfSense/FreeBSD.

Do not run live-effect commands listed above unless explicitly authorized.

Before committing: show the diff, explain risk, state tests run, keep commits focused, and do not commit logs, temp files, `.codex-log`, secrets, or local configs such as `tailscale_watchdog.conf`.

## Documentation / Release

README changes should be end-user oriented: purpose, requirements, quick and review-first install, configuration, testing before enabling, enable/start, update, uninstall, security, troubleshooting, AI assistance disclosure, and MIT note. Do not turn README into an internal audit trail.

For releases: use SemVer-style tags such as `v1.0.0`, prefer annotated tags, require clean `git status`, run all `sh -n` checks, and write user-facing release notes. Extra release assets are not required unless requested.

## Interaction

Be direct and technical. State assumptions, prefer small reviewable changes, push back on unsafe router operations, call out Linux vs FreeBSD differences, say when a command was not run, and flag live-router behavior changes clearly.
