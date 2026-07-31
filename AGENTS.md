# AGENTS.md

## Scope

`tailscale-direct-pfsense` is a small pfSense/FreeBSD watchdog for Tailscale direct connectivity.

The target platform is pfSense CE 2.7, which is based on FreeBSD 14; CI pins its FreeBSD VM to 14.0 to match. Other versions may work, but the scripts rely on FreeBSD userland behavior such as `stat -f`, `jot`, and `netstat -ibn`, which can differ on an older base. `README.md` Requirements and `docs/architecture.md` state the same target — when the supported base moves, move all three and the CI pin together.

Primary repo files: `tailscale_watchdogd`, `tailscale_watchdog` rc.d wrapper, `tailscale_watchdog.conf.example`, `install.sh`, `uninstall.sh`, `README.md`, `docs/`, `LICENSE`.

This file is the single rulebook for every coding agent working here. `CLAUDE.md` is a symlink to it, so Claude Code and Codex read the same content; keep it a symlink rather than materializing a second file that can drift. Claude Code subagent definitions live in `.claude/agents/` and are the one Claude-specific exception.

* `/usr/local/sbin/tailscale_watchdogd`
* `/usr/local/etc/rc.d/tailscale_watchdog`
* `/usr/local/etc/tailscale_watchdog.conf`
* `/usr/local/etc/tailscale_watchdog.conf.example`

## Non-Negotiables

* Keep the project shell-only, small, auditable, and pfSense/FreeBSD-oriented.
* Target `/bin/sh`, FreeBSD 14 userland, and rc.d; do not assume Bash, GNU coreutils, systemd, Linux service paths, package managers, compiled code, Python, Node, Go, containers, or GUI integration.
* Runtime dependencies must stay limited to expected pfSense/FreeBSD tools plus Tailscale.
* Do not introduce Bashisms: arrays, `[[ ... ]]`, process substitution, `${var//...}`, or `function name { ... }`.
* Do not introduce GNU-specific options unless verified on FreeBSD/pfSense.
* Use generic examples such as `router1 router2`; never include private peer names, auth keys, tokens, hostnames, local network names, or identifying logs.

## Shell Style

Prefer:

* Quoted variables, explicit error handling, small functions, `case` validation.
* Global variables only. Do not introduce `local`; there is none in the project today. Tests source `tailscale_watchdogd` and override globals such as `STATE_DIR`, `NEXT_RESTART_FILE`, and `FAIL_THRESHOLD` directly, so function-scoped variables would make new code untestable.
* `mktemp` for temp files.
* Atomic installs/updates via temp file in destination directory plus `mv`.
* `logger` for daemon/service logs.
* PID files or command-specific mechanisms over parsing `ps`.

Avoid:

* Unquoted variables, Linux-only paths, noisy healthy-state writes, clever shell abstractions, and secrets in examples.

## Security Rules

This touches router services; be conservative.

Do not auto-enable/start service from the installer, run live install/uninstall/service/Tailscale restart commands without authorization, add telemetry, add network calls beyond documented downloads and configured notifications, print secrets, make live config world-readable, store notification secrets outside live config, or replace live config without preserving it.

Permissions: daemon, rc wrapper, installer, uninstaller are root-owned executables.

* Live config: `root:wheel`, mode `0600`.
* Example config: non-secret, readable.
* Runtime state: `/var/run/tailscale_watchdog`. Fixed, not an operator setting: `uninstall.sh` hardcodes that path, so state relocated by a config line would survive uninstall and break the removal guarantee below. See the runtime-state bullet under Daemon Invariants.

## Daemon Invariants

Preserve watchdog behavior:

* Direct path is healthy.
* Sustained DERP/relay-only paths count as failures.
* Unknown/no usable path is not relayed and breaks the consecutive-relay sequence.
* Restart configured Tailscale services only after `FAIL_THRESHOLD` consecutive relayed classifications for a peer.
* Restart services by running `stop`, pausing `RESTART_SETTLE_SECONDS`, then `start` — never `service ... restart`. This mirrors the pfSense GUI's service control and gives `pfsense_tailscaled`'s post-start hook time to see `tailscale0` leave before it waits for it to return; that hook is what runs `tailscale up` and reloads the packet filter. A failing `stop` is not a restart failure; only the `start` decides. See `docs/daemon-behavior.md`.
* The stop-to-start span is a critical section. `handle_shutdown` must record the request and return rather than exit while `RESTART_CRITICAL` is set, so the `start` always runs. Never add an early return between `RESTART_CRITICAL=1` and the matching `RESTART_CRITICAL=0`; leaving the flag set would defer every later signal and the daemon would only ever stop by `SIGKILL`. Exiting between a stop and a start leaves Tailscale down on the router permanently: the watchdog then classifies every peer as `unknown`, which breaks the relayed sequence, so it never restarts the service.
* The `SIGKILL` deadline is a single budget for the whole restart, not per service. `tailscale_watchdog_stop` in the rc wrapper escalates 10 seconds after `TERM` (the 5-second escalation in `kill_and_wait` is a different path, reachable only from a failed pidfile write). So once a shutdown is pending the restart loop skips remaining settles and stops iterating rather than stopping services it has not reached — an untouched service is still running, which is safe. At most one full settle and one start sit on that path; `RESTART_SETTLE_SECONDS` is capped against that single pause. Raise the cap only alongside the wrapper's 10-second window.
* Never run a `service` invocation inside a command substitution — route it through `run_service_command`, which redirects to a temp file. A command substitution puts the child's stdout on a pipe the daemon owns; a `SIGKILL` mid-start closes it and the orphaned `service` dies of `SIGPIPE` before finishing, leaving the service stopped. A file keeps the orphan alive to completion. Command substitution around short-lived helpers such as `cat` is fine; the rule is about the long-running child whose survival matters.
* Internal runtime state shares a namespace with the sourced live config, so `main` calls `reset_runtime_state` immediately after `load_config_file` to discard whatever the config assigned. Put new internal state inside that function — never re-assert an enumerated subset in `main`, which is how `SLEEP_PID` was missed, the one value `handle_shutdown` passes to `kill` as root. Source the live config exactly once: a second source anywhere, including the tempting `[ -r "$f" ] && . "$f"` drop-in, silently undoes the reset.
* `STATE_DIR` and `NEXT_RESTART_FILE` are part of that internal state, and `NEXT_RESTART_FILE` must stay derived from `STATE_DIR` in the same pass. They used to sit in the defaults block with `NEXT_RESTART_FILE` expanded from `STATE_DIR` exactly once, so a config assigning only `STATE_DIR` split the pair: `mark_restart_attempt` created and `mktemp`'d under the new directory and `mv`'d into the old one, the write failed, and `restart_tailscale_services` returned before touching any service — every restart suppressed, silently, for the life of the install. Neither is an operator setting. The uninstaller hardcodes the state directory, so a relocated one survives uninstall; and moving state onto persistent storage decides whether cooldown survives a reboot, which is a behavior decision, not something that should fall out of a stray config line. Keep both out of `README.md` and `tailscale_watchdog.conf.example`: documenting them as settings invites exactly the config line that caused the bug. A config that assigns either is discarded with the rest of the block, and `warn_ignored_state_paths` logs it when the assigned value differs from the fixed one, because a setting that quietly does nothing is indistinguishable from one that is broken.
* Not every rule above is testable, and the ones here are not. Static checks for them were written and removed: a substring check for `$(service ` fell to one extra space, a sourced-once count missed the compound form, and a completeness check was a hand-written list a new variable would simply not appear in. Each rewrite closed the demonstrated hole and left an adjacent one while reading as enforced, which is worse than an honest gap. **These bullets are the control. Do not add a static text check and treat the rule as covered.**
* What tests do cover is behavior, and there the bar is high: fakes must fail loudly rather than swallow an error, and an assertion must be falsifiable by *replacement*, not only deletion — an unanchored `assert_contains` on a name is satisfied by prose that mentions it. Five assertions in this project have shipped unable to fail; when adding one, break the code deliberately and confirm it goes red.
* Restart cooldown uses `RESTART_COOLDOWN_MIN` and `RESTART_COOLDOWN_MAX`.
* Active cooldown state file: `/var/run/tailscale_watchdog/next_restart_allowed`, assigned in `reset_runtime_state` from `STATE_DIR`. Change the path only there, and only together with the uninstaller.
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

Run a single test script directly while iterating:

```sh
sh tests/test_cooldown.sh
```

Register every new test file in `TESTS` in the `Makefile`. That list is explicit, not globbed, so an unregistered test file silently never runs.

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

Use `docs/` for maintainer-focused rationale. Before changing daemon behavior, script safety behavior, installer/uninstaller behavior, or tests, read the relevant `docs/` page and update it when the rationale changes.

New notification providers must preserve Pushover compatibility, avoid logging or argv exposure of secrets, use fake commands in tests, and update README, config example, and maintainer docs.

For releases: use SemVer-style tags such as `v1.0.0`, prefer annotated tags, require clean `git status`, run all `sh -n` checks, and write user-facing release notes. Extra release assets are not required unless requested.

## Interaction

Be direct and technical. State assumptions, prefer small reviewable changes, push back on unsafe router operations, call out Linux vs FreeBSD differences, say when a command was not run, and flag live-router behavior changes clearly.
