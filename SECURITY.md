# Security Policy

## Supported Versions

This project is small and maintained as a source repository rather than a packaged product.

Security fixes are intended for:

- the current `main` branch
- the latest published release tag, if releases are being used

Older commits and older release tags may not receive backported fixes unless explicitly stated in the release notes.

## Reporting a Vulnerability

Please do not post suspected vulnerabilities publicly until they have been reviewed.

Preferred reporting path:

1. Use GitHub's private vulnerability reporting feature if it is enabled for this repository.
2. If private reporting is not available, contact the maintainer privately using contact information on the maintainer's GitHub profile.
3. If neither option is available, open a minimal public issue that says you have a security concern and need a private contact path. Do not include exploit details, secrets, private configs, or logs in that issue.

When reporting, include:

- the affected file or behavior
- the version, commit, or branch tested
- the pfSense/FreeBSD version if relevant
- clear reproduction steps using sanitized values
- the expected impact

## Sensitive Information

Do not post real router configs, full logs, screenshots, or command output publicly without reviewing and redacting them first.

Redact or replace:

- Pushover tokens and user keys
- Tailscale auth keys, API keys, node keys, or tailnet details
- private peer names if they identify your network
- local hostnames, domains, usernames, paths, or IP addresses
- subnet routes, firewall details, or other internal network information

Use generic examples such as:

```sh
PEERS="router1 router2"
PUSHOVER_TOKEN="REDACTED"
PUSHOVER_USER="REDACTED"
```

Peer names may appear in normal watchdog logs and notifications by design. Treat those logs as potentially sensitive if your peer names reveal private network details.

## Project Scope

This is an unofficial community project.

It is not affiliated with, endorsed by, or supported by:

- Netgate or the pfSense project
- Tailscale Inc.

Security issues in pfSense, FreeBSD, Tailscale, Pushover, or GitHub should be reported to those projects or vendors through their own security processes.

## Operational Safety

This project runs on a router and can restart local Tailscale services. Security fixes should preserve the existing safety model unless a behavior change is explicitly documented.

Important expectations:

- do not leak secrets in process arguments, logs, tests, examples, or documentation
- do not make the live config world-readable
- do not overwrite existing live configs without preserving them
- do not auto-enable or auto-start the watchdog service from the installer
- do not run installer, uninstaller, service restart, or Tailscale commands against a live system during routine testing

## Disclosure

The maintainer will aim to acknowledge valid reports promptly and coordinate a fix before public disclosure. Timelines may vary because this is a personal/open-source project.

After a fix is available, the public issue, pull request, commit, or release notes should describe the vulnerability at a useful level without exposing private reporter details or unnecessary exploit material.
