#!/bin/sh
#
# tailscale_watchdog.sh — pfSense boot hook for tailscale_watchdog
#
# Documentation:
#   https://github.com/toddawhittaker/tailscale-direct-pfsense
#
# Why this file exists:
#
#   pfSense does not boot /usr/local/etc/rc.d the way FreeBSD does.  It never
#   runs rcorder over that directory, and its boot code does not consult
#   rc.conf.local itself (service(8) does, when this hook calls it).
#   Instead, /etc/rc.start_packages runs every /usr/local/etc/rc.d/*.sh it
#   finds as "<file> start" in the background, and /etc/rc.stop_packages runs
#   each one as "<file> stop".  The real rc.d script, tailscale_watchdog, has
#   no .sh suffix, so without this hook pfSense never starts the watchdog after
#   a reboot.
#
#   This hook holds no logic of its own.  It hands the command to service(8),
#   so the rc.d script stays the single implementation.  Going through
#   service(8) also keeps the rcvar check: unless rc.conf.local sets
#   tailscale_watchdog_enable="YES", a boot-time start does nothing.
#   Installing this hook therefore does not enable the service.
#
#   pfSense also re-runs rc.start_packages after boot (for example when it
#   restarts all packages), so "start" can arrive while the daemon is already
#   running.  The rc.d script's start refuses to launch a second daemon when
#   its pidfile points at a live process, which makes a repeat start a no-op.

case "$1" in
  start|stop|restart|status)
    exec /usr/sbin/service tailscale_watchdog "$1"
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}" >&2
    exit 1
    ;;
esac
