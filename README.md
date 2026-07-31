# Tailscale Direct Watchdog for pfSense

A lightweight watchdog for pfSense systems running Tailscale.

The watchdog periodically checks selected Tailscale peers. If a peer remains reachable only through a relay for several consecutive checks, it restarts the local Tailscale services to try to restore a direct connection.

This is useful on pfSense routers where Tailscale occasionally falls back to DERP/relay even though direct connectivity normally works.

This is an unofficial community project. It is not affiliated with, endorsed by, or supported by Netgate, the pfSense project, or Tailscale Inc.

## What it does

The watchdog:

- checks configured Tailscale peers using `tailscale ping`
- detects sustained relayed connectivity
- restarts local Tailscale services after a configurable threshold
- applies a randomized cooldown between restart attempts
- optionally sends a notification when it restarts services
- runs as a pfSense/FreeBSD rc service

It does not modify your Tailscale account, ACLs, routes, firewall rules, or Tailscale package installation.

## Requirements

- pfSense CE 2.7, which is based on FreeBSD 14. This is the platform the
  project targets and tests against. Other pfSense versions may work, but the
  scripts rely on FreeBSD userland behavior such as `stat -f`, `jot`, and
  `netstat -ibn`, which can differ on an older base.
- Tailscale installed and authenticated
- root access to the pfSense shell
- `curl` available on the system
- optional: a Pushover account if you want restart notifications

## Quick install

Review-first installation is recommended because the installer runs as root.

The quickest installation method is:

```sh
VERSION=v1.2.0
curl -fsSL \
  "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/install.sh" \
  | VERSION="${VERSION}" /bin/sh
```

For a review-first installation:

```sh
VERSION=v1.2.0
curl -fsSL \
  "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/install.sh" \
  -o /tmp/install.sh

less /tmp/install.sh
VERSION="${VERSION}" /bin/sh /tmp/install.sh
```

The installer:

- checks that it is running as root on pfSense
- checks that Tailscale is installed
- downloads the watchdog daemon, service wrapper, and example config
- installs files in the appropriate locations
- preserves any existing live config file
- does not enable or start the service automatically

After installation, edit the config file before enabling the service.

## Configuration

Edit:

```sh
vi /usr/local/etc/tailscale_watchdog.conf
```

Example configuration:

```sh
# Optional notifications. Pushover is currently the supported provider.
NOTIFY_PROVIDER="pushover"
NOTIFY_ON_STARTUP=1
LOCAL_TAILSCALE_NAME=""
PUSHOVER_TOKEN=""
PUSHOVER_USER=""

# Space-separated Tailscale peer names to monitor.
PEERS="router1 router2"

# Seconds between checks.
CHECK_INTERVAL=60

# Number of consecutive relayed checks before restart.
FAIL_THRESHOLD=5

# Number of tailscale ping attempts per peer per check.
PING_COUNT=5

# Minimum and maximum seconds after a restart attempt before another
# restart attempt is allowed. A random value in this range is selected
# after each restart attempt.
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800

# Delay a restart while local Tailscale interface traffic appears active.
RESTART_DEFERRAL_ENABLED=1
RESTART_DEFERRAL_INTERFACE="tailscale0"
RESTART_DEFERRAL_CHECK_SECONDS=30
RESTART_DEFERRAL_MAX_BYTES=65536
RESTART_DEFERRAL_MAX_ATTEMPTS=10

# Services restarted when the threshold is reached.
RESTART_SERVICES="pfsense_tailscaled"

# Seconds between stopping and starting each service. Range 0-4.
RESTART_SETTLE_SECONDS=3

# Maximum seconds curl may spend attempting a Pushover notification.
CURL_TIMEOUT=10
```

At minimum, set `PEERS` to the Tailscale hostnames you want to monitor.

If you want Pushover notifications, set `NOTIFY_PROVIDER="pushover"` plus both `PUSHOVER_TOKEN` and `PUSHOVER_USER`. If either Pushover value is blank, notifications are skipped. To disable notifications explicitly, set `NOTIFY_PROVIDER="none"`.

By default, the watchdog sends a startup notification when it starts in normal service mode. Startup notifications are not sent for test mode or one-shot runs. To disable startup notifications while keeping restart notifications enabled, set:

```sh
NOTIFY_ON_STARTUP=0
```

Pushover notifications use a title plus a line-oriented message body. The title includes the local router's Tailscale name, and the body includes the router name, event, trigger peer, relay count, and restarted services where applicable.

By default, the router name is detected from local Tailscale status. To force the display name used in notifications, set:

```sh
LOCAL_TAILSCALE_NAME="router0"
```

Keep the config file private:

```sh
chown root:wheel /usr/local/etc/tailscale_watchdog.conf
chmod 0600 /usr/local/etc/tailscale_watchdog.conf
```

### Cooldown behavior

The watchdog waits for `FAIL_THRESHOLD` consecutive relayed checks before attempting a restart. After a restart attempt, it waits a random number of seconds between `RESTART_COOLDOWN_MIN` and `RESTART_COOLDOWN_MAX` before another restart attempt is allowed.

The randomized cooldown helps avoid multiple routers restarting in sync when several of them are monitoring each other.

For example:

```sh
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=1800
```

allows the next restart attempt somewhere between 15 and 30 minutes later.

If you want a fixed cooldown, set both values to the same number:

```sh
RESTART_COOLDOWN_MIN=900
RESTART_COOLDOWN_MAX=900
```

### Restart deferral

By default, the watchdog checks whether the configured Tailscale interface appears quiet before restarting services. This check runs only after a peer reaches `FAIL_THRESHOLD` and the randomized cooldown allows another restart attempt.

The deferral scope is interface-wide, not per peer. That is intentional because restarting local Tailscale services can interrupt all Tailscale traffic on the router, including traffic unrelated to the peer that triggered the threshold.

The watchdog samples total received and sent bytes on `RESTART_DEFERRAL_INTERFACE` for `RESTART_DEFERRAL_CHECK_SECONDS`. If the byte delta is greater than `RESTART_DEFERRAL_MAX_BYTES`, it defers the restart and tries again on a later check. Deferrals are bounded by `RESTART_DEFERRAL_MAX_ATTEMPTS`; after that, the watchdog proceeds with the restart.

A deferred restart does not consume the randomized restart cooldown. The cooldown is written only immediately before an actual restart attempt. If interface activity detection is unavailable or returns unexpected output, the watchdog logs the problem and proceeds with the restart decision.

## Test before enabling

Run a one-time test check:

```sh
/usr/local/sbin/tailscale_watchdogd -t -1 -d
```

Run interactively in test mode:

```sh
/usr/local/sbin/tailscale_watchdogd -t -d
```

In test mode, the watchdog reports what it would do but does not restart services.

## Enable and start the service

Enable the service by editing:

```sh
vi /etc/rc.conf.local
```

Add or update:

```sh
tailscale_watchdog_enable="YES"
```

Start the service:

```sh
service tailscale_watchdog start
```

Check status:

```sh
service tailscale_watchdog status
```

Check logs:

```sh
clog /var/log/system.log | grep tailscale_watchdog | tail -20
```

If your system is not using circular logs, use:

```sh
grep tailscale_watchdog /var/log/system.log | tail -20
```

## Manual installation

Manual installation is useful if you want to review each file yourself.

Clone the repository:

```sh
git clone https://github.com/toddawhittaker/tailscale-direct-pfsense.git
cd tailscale-direct-pfsense
```

Syntax-check the scripts before installing:

```sh
sh -n tailscale_watchdogd
sh -n tailscale_watchdog
sh -n tailscale_watchdog.conf.example
sh -n install.sh
sh -n uninstall.sh
```

Install the daemon atomically:

```sh
tmp="$(mktemp /usr/local/sbin/.tailscale_watchdogd.XXXXXX)"
cp tailscale_watchdogd "$tmp"
chown root:wheel "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" /usr/local/sbin/tailscale_watchdogd
```

Install the service wrapper atomically:

```sh
tmp="$(mktemp /usr/local/etc/rc.d/.tailscale_watchdog.XXXXXX)"
cp tailscale_watchdog "$tmp"
chown root:wheel "$tmp"
chmod 0755 "$tmp"
mv -f "$tmp" /usr/local/etc/rc.d/tailscale_watchdog
```

Install the example config and create a starter live config only if one does not already exist:

```sh
tmp="$(mktemp /usr/local/etc/.tailscale_watchdog.conf.example.XXXXXX)"
cp tailscale_watchdog.conf.example "$tmp"
chown root:wheel "$tmp"
chmod 0644 "$tmp"
mv -f "$tmp" /usr/local/etc/tailscale_watchdog.conf.example

if [ ! -e /usr/local/etc/tailscale_watchdog.conf ]; then
  tmp="$(mktemp /usr/local/etc/.tailscale_watchdog.conf.XXXXXX)"
  cp tailscale_watchdog.conf.example "$tmp"
  chown root:wheel "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" /usr/local/etc/tailscale_watchdog.conf
fi

vi /usr/local/etc/tailscale_watchdog.conf
```

Then test, enable, and start the service as described above.

## Updating

Re-run the installer:

```sh
VERSION=v1.2.0
curl -fsSL \
  "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/install.sh" \
  | VERSION="${VERSION}" /bin/sh
```

The installer updates the daemon, service wrapper, and example config. It preserves your live config at:

```text
/usr/local/etc/tailscale_watchdog.conf
```

If the service is already running, restart it after the update:

```sh
service tailscale_watchdog restart
```

### Upgrading from a config that lists `tailscaled`

Because your live config is preserved, an older `RESTART_SERVICES` line survives the update. If yours reads:

```sh
RESTART_SERVICES="tailscaled pfsense_tailscaled"
```

change it to:

```sh
RESTART_SERVICES="pfsense_tailscaled"
```

Restarting `pfsense_tailscaled` already cycles `tailscaled` underneath, and it additionally runs `tailscale up`, restores the `tailscale0` interface group, and reloads the packet filter. Restarting `tailscaled` as well just bounces the daemon a second time without any of that. This matches what the pfSense GUI's service control does.

Optionally add the settle pause, which defaults to 3 seconds if the setting is absent:

```sh
RESTART_SETTLE_SECONDS=3
```

## Uninstall

To uninstall quickly:

```sh
VERSION=v1.2.0
curl -fsSL \
  "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/uninstall.sh" \
  | /bin/sh
```

For a review-first uninstall:

```sh
VERSION=v1.2.0
curl -fsSL \
  "https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/${VERSION}/uninstall.sh" \
  -o /tmp/uninstall.sh

less /tmp/uninstall.sh
/bin/sh /tmp/uninstall.sh
```

The uninstaller:

- stops the watchdog service if it is running
- removes watchdog service settings from `/etc/rc.conf.local`
- removes the daemon, service wrapper, example config, and runtime state
- asks before removing the live config file
- preserves the live config by default if no interactive TTY is available

It does not remove the Tailscale package.

## Manual uninstall

Stop the service:

```sh
service tailscale_watchdog onestop
```

Remove service settings from `/etc/rc.conf.local`:

```sh
vi /etc/rc.conf.local
```

Remove any lines beginning with:

```text
tailscale_watchdog_
```

Remove installed files:

```sh
rm -f /usr/local/sbin/tailscale_watchdogd
rm -f /usr/local/etc/rc.d/tailscale_watchdog
rm -f /usr/local/etc/tailscale_watchdog.conf.example
rm -f /var/run/tailscale_watchdog.pid
rm -rf /var/run/tailscale_watchdog
```

Optionally remove your live config:

```sh
rm -f /usr/local/etc/tailscale_watchdog.conf
```

## Security notes

The quick install and uninstall commands download scripts from GitHub and run them as root. Review the scripts first if that risk is not acceptable for your environment.

The installer uses HTTPS GitHub URLs, but the project does not currently provide signed release artifacts.

The live config file may contain notification credentials. Keep it owned by root and mode `0600`.

## Troubleshooting

### The daemon test reports an unknown path

An `unknown` result usually means the peer did not respond in a way the watchdog could classify. Check that the peer name is correct and reachable from this router:

```sh
tailscale ping PEER_NAME
```

### The service does not start

Run the daemon directly in test mode:

```sh
/usr/local/sbin/tailscale_watchdogd -t -1 -d
```

Common causes include:

- invalid config syntax
- config file permissions are too open
- invalid peer names
- Tailscale is not authenticated or running
- the expected service names are not available on the system; adjust `RESTART_SERVICES` to match the local pfSense service names

### Notifications are not sent

Confirm the selected provider:

```sh
grep '^NOTIFY_PROVIDER=' /usr/local/etc/tailscale_watchdog.conf
```

For Pushover, check whether both values are set without printing the credentials:

```sh
awk -F= '
  /^PUSHOVER_/ {
    value = $2
    gsub(/[[:space:]"]/, "", value)
    if (value == "") {
      print $1 "=empty"
    } else {
      print $1 "=set"
    }
  }
' /usr/local/etc/tailscale_watchdog.conf
```

Also confirm `curl` is installed:

```sh
command -v curl
```

### The service runs but logs are quiet

That is normal when peers are direct and healthy. The watchdog logs startup, shutdown, relay events, restart attempts, restart results, and notable errors. It does not log every successful check.

## Limitations

This tool attempts to recover from sustained relayed connectivity by restarting local Tailscale services. It does not diagnose the underlying network cause.

Relay fallback can be caused by NAT behavior, firewall policy, ISP path changes, remote peer conditions, or Tailscale control-plane state. If relayed connectivity returns repeatedly, investigate the network path rather than relying only on restarts.

## Development tests

The test suite is shell-only and does not run installer, uninstaller, service restart, or Tailscale commands against the live system.

Run syntax smoke tests:

```sh
make smoke
```

Run the full test suite:

```sh
make test
```

For maintainer-focused details about the scripts, state model, and safety decisions, see [`docs/`](docs/).

## Development note

This project was developed with AI assistance. The code and documentation were reviewed and edited by the project maintainer before publication.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
