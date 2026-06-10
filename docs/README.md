# Maintainer Documentation

This directory explains how `tailscale-direct-pfsense` is put together and why the scripts behave the way they do.

The top-level `README.md` is for operators installing and running the watchdog. These docs are for maintainers, reviewers, and coding agents changing the project.

Read these before changing behavior:

- [`architecture.md`](architecture.md) explains the component boundaries and runtime model.
- [`daemon-behavior.md`](daemon-behavior.md) explains peer classification, counters, cooldown, deferral, and restart flow.
- [`script-reference.md`](script-reference.md) explains each shell script and the safety decisions it owns.
- [`testing.md`](testing.md) explains the shell-native test suite and validation commands.

Project constraints:

- Target pfSense/FreeBSD and `/bin/sh`.
- Avoid Bashisms, GNU-only options, systemd assumptions, package managers, compiled components, Python, Node, Go, containers, and heavyweight frameworks.
- Keep examples generic. Use peers such as `router1` and `router2`.
- Do not include secrets, private hostnames, local network names, tokens, or identifying logs.
- Do not run installer, uninstaller, service restart, or real Tailscale commands in tests.
