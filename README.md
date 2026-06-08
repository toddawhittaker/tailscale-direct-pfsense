# Tailscale Direct Watchdog for pfSense

A lightweight watchdog for pfSense systems running Tailscale.

The watchdog periodically checks selected Tailscale peers. If a peer remains reachable only through a relay for several consecutive checks, it restarts the local Tailscale services to try to restore a direct connection.

This is useful on pfSense routers where Tailscale occasionally falls back to DERP/relay even though direct connectivity normally works.

## What it does

The watchdog:

- checks configured Tailscale peers using `tailscale ping`
- detects sustained relayed connectivity
- restarts local Tailscale services after a configurable threshold
- applies a cooldown between restart attempts
- optionally sends a Pushover notification when it restarts services
- runs as a pfSense/FreeBSD rc service

It does not modify your Tailscale account, ACLs, routes, firewall rules, or Tailscale package installation.

## Requirements

- pfSense
- Tailscale installed and authenticated
- root access to the pfSense shell
- `curl` available on the system
- optional: a Pushover account if you want restart notifications

## Quick install

The quickest installation method is:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/install.sh \
  | /bin/sh
```

For a review-first installation:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/install.sh \
  -o /tmp/install.sh

less /tmp/install.sh
/bin/sh /tmp/install.sh
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
# Optional Pushover credentials. Leave empty to disable notifications.
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

# Seconds to wait before another restart attempt is allowed.
RESTART_COOLDOWN=900

# Services restarted when the threshold is reached.
RESTART_SERVICES="tailscaled pfsense_tailscaled"

# Maximum seconds curl may spend attempting a Pushover notification.
CURL_TIMEOUT=10
```

At minimum, set `PEERS` to the Tailscale hostnames you want to monitor.

If you want Pushover notifications, set both `PUSHOVER_TOKEN` and `PUSHOVER_USER`. If either is blank, notifications are skipped.

Keep the config file private:

```sh
chown root:wheel /usr/local/etc/tailscale_watchdog.conf
chmod 0600 /usr/local/etc/tailscale_watchdog.conf
```

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

Install the daemon:

```sh
cp tailscale_watchdogd /usr/local/sbin/tailscale_watchdogd
chown root:wheel /usr/local/sbin/tailscale_watchdogd
chmod 0755 /usr/local/sbin/tailscale_watchdogd
sh -n /usr/local/sbin/tailscale_watchdogd
```

Install the service wrapper:

```sh
cp tailscale_watchdog /usr/local/etc/rc.d/tailscale_watchdog
chown root:wheel /usr/local/etc/rc.d/tailscale_watchdog
chmod 0755 /usr/local/etc/rc.d/tailscale_watchdog
sh -n /usr/local/etc/rc.d/tailscale_watchdog
```

Install the config:

```sh
cp tailscale_watchdog.conf.example /usr/local/etc/tailscale_watchdog.conf
chown root:wheel /usr/local/etc/tailscale_watchdog.conf
chmod 0600 /usr/local/etc/tailscale_watchdog.conf
vi /usr/local/etc/tailscale_watchdog.conf
```

Then test, enable, and start the service as described above.

## Updating

Re-run the installer:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/install.sh \
  | /bin/sh
```

The installer updates the daemon, service wrapper, and example config. It preserves your live config at:

```text
/usr/local/etc/tailscale_watchdog.conf
```

If the service is already running, restart it after the update:

```sh
service tailscale_watchdog restart
```

## Uninstall

To uninstall quickly:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/uninstall.sh \
  | /bin/sh
```

For a review-first uninstall:

```sh
curl -fsSL \
  https://raw.githubusercontent.com/toddawhittaker/tailscale-direct-pfsense/main/uninstall.sh \
  -o /tmp/uninstall.sh

less /tmp/uninstall.sh
/bin/sh /tmp/uninstall.sh
```

The uninstaller:

- stops the watchdog service if it is running
- removes watchdog service settings from `/etc/rc.conf.local`
- removes the daemon, service wrapper, example config, and runtime state
- asks before removing the live config file

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

The live config file may contain Pushover credentials. Keep it owned by root and mode `0600`.

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
- the expected service names are not available on the system

### Notifications are not sent

Check that both values are set:

```sh
grep '^PUSHOVER_' /usr/local/etc/tailscale_watchdog.conf
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

## Development note

This project was developed with AI assistance. The code and documentation were reviewed and edited by me before publication.

## License

This project is licensed under the MIT License. See `LICENSE` for details.
