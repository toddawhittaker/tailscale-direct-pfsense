# Daemon Behavior

The daemon monitors configured peers and restarts local Tailscale services only after sustained evidence that a monitored peer is relay-only.

## Peer Classification

`tailscale ping` output is classified as:

- `direct`: at least one usable `pong from ... via ...` line is not DERP and not peer-relay.
- `relayed`: one or more usable pongs are DERP or peer-relay, and no direct pong appears.
- `unknown`: no usable pong path is found.

Unknown output breaks the relayed sequence. It is not treated as relayed because timeouts, parse changes, offline peers, and transient command failures are not enough evidence to restart router services.

## Peer State

The daemon stores per-peer state in memory:

- relay count;
- last state;
- threshold marker used to avoid repeating the same suppression log on every loop.

No per-peer state is persisted across daemon restarts. That keeps normal operation quiet and avoids turning every health check into a disk write.

## Restart Controls

Restart controls are global because restarting local Tailscale services affects all Tailscale traffic on the router.

The active cooldown file is:

```text
/var/run/tailscale_watchdog/next_restart_allowed
```

The file stores the epoch when another restart attempt is allowed. The daemon writes it immediately before a real service restart attempt. That means a failed restart still consumes cooldown, which prevents immediate retry loops.

Restart deferral, when enabled, samples interface-wide byte counters on `RESTART_DEFERRAL_INTERFACE`. If traffic is above `RESTART_DEFERRAL_MAX_BYTES`, the daemon defers without writing cooldown. Deferrals are bounded by `RESTART_DEFERRAL_MAX_ATTEMPTS`.

If activity detection is unavailable, malformed, interrupted, or otherwise unsupported, the daemon logs the problem and proceeds with the restart decision. That preserves the older behavior instead of letting a broken activity check suppress restarts forever.

## Decision Flow

```mermaid
flowchart TD
  A[Check peer with tailscale ping] --> B{Path classification}
  B -->|direct| C[Reset peer relay counter]
  B -->|unknown| D[Break relay sequence]
  B -->|relayed| E[Increment peer relay counter]
  E --> F{Counter >= FAIL_THRESHOLD?}
  F -->|no| G[Wait for next check]
  F -->|yes| H{Test mode?}
  H -->|yes| I[Log would restart]
  H -->|no| J{Cooldown active?}
  J -->|yes| K[Suppress restart]
  J -->|no| L{Deferral enabled and traffic active?}
  L -->|yes| M[Defer restart without writing cooldown]
  L -->|no / unavailable / max attempts| N[Write next restart cooldown]
  N --> O[Restart configured services]
  O -->|success| P[Reset all peer counters]
  O -->|failure| Q[Keep counters for retry after cooldown]
```

## Logging

The daemon logs notable transitions, suppression decisions, restart decisions, restart cooldown selection, service restart results, notification failures, and shutdown. When enabled and configured, it also sends a startup notification for normal long-running daemon starts. Notifications include the local router's Tailscale name, detected from local Tailscale status unless `LOCAL_TAILSCALE_NAME` is set in the config.

It does not log every successful direct check. Quiet logs during healthy operation are intentional.

Peer names are safe to log and send in notifications. Provider secrets such as tokens, user keys, and webhook URLs are not.
