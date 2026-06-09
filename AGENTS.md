# AGENTS.md

## Project overview

This repository contains `tailscale-direct-pfsense`, a small pfSense/FreeBSD watchdog for Tailscale direct connectivity.

The project is intentionally simple:

* POSIX-style `/bin/sh` scripts.
* No compiled components.
* No package manager.
* No runtime dependencies beyond tools already expected on pfSense/FreeBSD plus Tailscale.
* No GUI integration at this stage.
* No systemd, Linux service manager, Python, Node, Go, or container runtime assumptions.

Primary installed files:

* `/usr/local/sbin/tailscale_watchdogd`
* `/usr/local/etc/rc.d/tailscale_watchdog`
* `/usr/local/etc/tailscale_watchdog.conf`
* `/usr/local/etc/tailscale_watchdog.conf.example`

Primary repository files:

* `tailscale_watchdogd` — foreground watchdog daemon.
* `tailscale_watchdog` — pfSense/FreeBSD rc.d service wrapper.
* `tailscale_watchdog.conf.example` — example configuration.
* `install.sh` — installer.
* `uninstall.sh` — uninstaller.
* `README.md` — end-user documentation.
* `LICENSE` — MIT license.

## Design goals

Preserve these design goals unless explicitly asked to change them:

* Keep the implementation small, auditable, and shell-only.
* Prefer boring, defensive shell code over clever abstractions.
* Optimize for pfSense/FreeBSD compatibility, not generic Linux.
* Avoid unnecessary dependencies.
* Avoid background state writes during healthy/direct operation.
* Do not expose private peer names, auth keys, API tokens, or local network details in examples.
* Use generic example peer names such as `router1 router2`.

## Compatibility target

The target runtime is pfSense on FreeBSD.

Assume:

* `/bin/sh`, not Bash.
* FreeBSD userland, not GNU coreutils.
* FreeBSD rc.d conventions, not systemd.
* `service`, `sysrc`, `clog`, `jot`, `date`, `sed`, `grep`, `awk`, `mktemp`, `logger`, `curl`, and Tailscale commands may be present depending on the environment.
* Some checks may be run from a Linux or WSL development machine, but final behavior must remain pfSense/FreeBSD-oriented.

Do not introduce Bash-only syntax such as arrays, `[[ ... ]]`, process substitution, `${var//...}`, or `function name { ... }`.

Do not introduce GNU-specific options unless they are verified to work on FreeBSD/pfSense.

## Shell style

Use conservative `/bin/sh`.

Prefer:

* Quoted variables.
* Explicit error handling.
* Small functions with single responsibilities.
* `case` statements for validation.
* `mktemp` for temporary files.
* Atomic install/update patterns using a temporary file in the destination directory followed by `mv`.
* Clear log messages through `logger`.

Avoid:

* Bashisms.
* Linux-only paths.
* Unquoted variables.
* Parsing `ps` output when a safer PID-file or command-specific method exists.
* Writing secrets or peer names into examples.
* Persisting noisy per-check state.

## Security expectations

This project touches router services. Be conservative.

Do not:

* Auto-enable or auto-start the service from the installer unless explicitly requested.
* Run `install.sh`, `uninstall.sh`, or service restart commands on a live router unless explicitly instructed.
* Add telemetry.
* Add automatic network calls other than documented installer downloads and optional Pushover notifications.
* Store Pushover tokens or user keys in files other than the private live config.
* Print secrets.
* Make the live config world-readable.
* Replace an existing live config without preserving it.

Maintain these file permission expectations:

* Daemon, wrapper, installer, uninstaller: root-owned executable files.
* Live config: `root:wheel`, mode `0600`.
* Example config: non-secret, readable.
* Runtime state: under `/var/run/tailscale_watchdog`.

## Watchdog behavior

The daemon monitors configured peers with `tailscale ping`.

Important behavior to preserve:

* A direct path is healthy.
* Sustained DERP/relay-only paths are counted as failures.
* Unknown/no usable path does not count as relayed and should break the consecutive-relay sequence.
* The daemon restarts configured Tailscale services only after `FAIL_THRESHOLD` consecutive relayed classifications for a peer.
* Restart attempts use randomized cooldown settings:

  * `RESTART_COOLDOWN_MIN`
  * `RESTART_COOLDOWN_MAX`
* The active cooldown state file is:

  * `/var/run/tailscale_watchdog/next_restart_allowed`
* Healthy/direct operation should not create or update runtime state files every check.
* After a successful restart, peer relay counters should reset.
* If a restart attempt fails, relay counters should remain so the daemon may retry after cooldown rather than waiting for a full new threshold.
* Signal handling should stop the loop promptly, including any active sleep.

## rc.d wrapper behavior

The service wrapper is installed as:

* `/usr/local/etc/rc.d/tailscale_watchdog`

It intentionally has no `.sh` extension.

Preserve these rc.d conventions:

* `# PROVIDE: tailscale_watchdog`
* `# REQUIRE: NETWORKING tailscaled pfsense_tailscaled`
* `# KEYWORD: shutdown`

The wrapper should:

* Run the daemon in the background.
* Maintain a PID file.
* Validate PID files before sending signals.
* Avoid stale PID-file hazards.
* Stop cleanly with TERM, then escalate only when needed.
* Avoid passing debug mode through normal service flags.
* Fail visibly if startup fails.

## Installer expectations

The installer should:

* Require root.
* Verify pfSense/FreeBSD context where practical.
* Download files over HTTPS only.
* Syntax-check shell files before installing.
* Install atomically.
* Preserve any existing live config.
* Install the example config.
* Set secure ownership and permissions.
* Not enable or start the service automatically.
* Print clear next steps.

## Uninstaller expectations

The uninstaller should:

* Require root.
* Stop the service using `onestop` where appropriate.
* Remove installed daemon, rc.d wrapper, and example config.
* Ask before removing the live config.
* Preserve live config by default if no TTY is available.
* Remove runtime state files, including:

  * `/var/run/tailscale_watchdog/next_restart_allowed`
  * any old compatibility state files if present.
* Remove only this project’s rc.conf entries.
* Not uninstall Tailscale itself.

## Validation commands

Before proposing a code change as complete, run the checks that are safe in the current environment.

Always run syntax checks when shell files change:

```sh
sh -n tailscale_watchdogd
sh -n tailscale_watchdog
sh -n tailscale_watchdog.conf.example
sh -n install.sh
sh -n uninstall.sh
```

If `shellcheck` is available, it may be useful, but do not treat ShellCheck as authoritative for pfSense/FreeBSD behavior without review.

Do not run these commands unless explicitly authorized because they may affect a live system:

```sh
./install.sh
./uninstall.sh
service tailscale_watchdog start
service tailscale_watchdog stop
service tailscale_watchdog restart
service tailscale_watchdog onestop
service tailscaled restart
service pfsense_tailscaled restart
```

## Documentation expectations

README changes should be end-user oriented.

Good README content:

* What the project does.
* Requirements.
* Quick install.
* Review-first install.
* Configuration.
* Testing before enabling.
* Enable/start instructions.
* Updating.
* Uninstalling.
* Security notes.
* Troubleshooting.
* AI assistance disclosure.
* MIT license note.

Avoid turning the README into an internal audit trail.

Do not include private peer names, real home network names, tokens, or logs with identifying hostnames. Use `router1 router2` for examples.

## Release expectations

For release work:

* Keep version tags SemVer-style, such as `v1.0.0`.
* Prefer annotated tags.
* Ensure `git status` is clean before tagging.
* Run all `sh -n` checks before release.
* Release notes should describe user-facing changes.
* A GitHub release does not need extra package assets unless explicitly requested.

## Commit expectations

Before committing:

* Show the diff.
* Explain the risk level.
* State what was tested.
* Keep commits focused.
* Do not commit generated local logs, temp files, `.codex-log`, secrets, or local config files.

Suggested `.gitignore` entries if needed:

```gitignore
.codex-log/
*.tmp
*.bak
tailscale_watchdog.conf
```

## Interaction style

When working on this repo:

* Be direct and technical.
* State assumptions.
* Prefer small, reviewable changes.
* Push back on changes that make router operations less safe.
* If behavior differs between Linux and FreeBSD, call that out.
* If a command was not run, say so explicitly.
* If a change affects live router behavior, flag it clearly before proposing it.
