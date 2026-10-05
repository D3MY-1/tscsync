#!/bin/sh
# Installs the TSC sync tool + early-boot and resume units and adds tsc=reliable to all kernels.
# Run as root. Backups go to /root/tscsync-backup/<timestamp>/.
#
# Undo:  grubby --remove-args="tsc=reliable" --update-kernel=ALL
#        systemctl disable tscsync.service tscsync-resume.service
set -eu
SRC=$(cd "$(dirname "$0")" && pwd)
BK=/root/tscsync-backup/$(date +%Y%m%d-%H%M%S)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== preflight: is this the bug tscsync fixes?"
# 1. The kernel must have rejected the TSC at the boot-time cross-CPU sync check
#    (a constant per-core offset), not demoted it later via the clocksource watchdog
#    (drift/jitter) - tsc=reliable would be dangerous there.
if [ "$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)" != tsc ] || ! grep -q 'tsc=reliable' /proc/cmdline; then
    if ! journalctl -k -b --no-pager 2>/dev/null | grep -q 'check_tsc_sync_source failed'; then
        echo "  dmesg shows no 'Marking TSC unstable due to check_tsc_sync_source failed'."
        echo "  Either the TSC is already fine, or it was rejected for a different reason"
        echo "  (e.g. 'clocksource: timekeeping watchdog ... Marking clocksource tsc as unstable')."
        echo "  This tool only fixes a constant boot-time offset. Not installing."; exit 1
    fi
fi
# 2. MSR writes must be allowed (kernel lockdown / Secure Boot blocks them).
if [ -r /sys/kernel/security/lockdown ] && ! grep -q '\[none\]' /sys/kernel/security/lockdown; then
    echo "  kernel lockdown is active ($(cat /sys/kernel/security/lockdown)); MSR writes are blocked."
    echo "  Disable Secure Boot first. Not installing."; exit 1
fi
# 3. The tool itself must see the offset pattern: a small number of cores out of
#    sync with a majority that agree (exit 1 = out of sync found, 0 = all in sync).
gcc -O2 -pthread -o "$TMP/tscsync" "$SRC/tscsync.c"
if "$TMP/tscsync" --measure > "$TMP/measure.txt"; then
    if ! grep -q 'tsc=reliable' /proc/cmdline; then
        echo "  all cores already agree - nothing to fix here. Not installing."; cat "$TMP/measure.txt"; exit 1
    fi
    echo "  (cores currently in sync - tsc=reliable already active, assuming reinstall)"
else
    echo "  out-of-sync core(s) found:"; grep 'out of sync' "$TMP/measure.txt"
fi
echo "  preflight OK"

echo "== backup -> $BK"
mkdir -p "$BK/loader-entries"
cp -a /boot/loader/entries/*.conf "$BK/loader-entries/"
cp -a /etc/default/grub "$BK/grub"
grubby --info=ALL > "$BK/grubby-info-before.txt"

echo "== install tool"
mkdir -p /usr/local/src/tscsync
install -m 0644 "$SRC/tscsync.c" /usr/local/src/tscsync/tscsync.c
gcc -O2 -pthread -o /usr/local/sbin/tscsync /usr/local/src/tscsync/tscsync.c
chmod 0755 /usr/local/sbin/tscsync
restorecon -v /usr/local/sbin/tscsync /usr/local/src/tscsync/tscsync.c || true

echo "== install unit + module autoload"
install -m 0644 "$SRC/msr.conf" /etc/modules-load.d/msr.conf
install -m 0644 "$SRC/tscsync.service" /etc/systemd/system/tscsync.service
install -m 0644 "$SRC/tscsync-resume.service" /etc/systemd/system/tscsync-resume.service
systemctl daemon-reload
systemctl enable tscsync.service tscsync-resume.service

echo "== kernel argument"
grubby --args="tsc=reliable" --update-kernel=ALL
grubby --info=ALL > "$BK/grubby-info-after.txt"

echo "== result"
grubby --info=DEFAULT | grep -E '^(kernel|args)'
systemctl is-enabled tscsync.service tscsync-resume.service
echo "Installed. Reboot when convenient, then check:"
echo "  cat /sys/devices/system/clocksource/clocksource0/current_clocksource   # tsc"
echo "  tscsync --measure                                                       # all ~0"
echo "  journalctl -u tscsync -b                                                # one apply line, no FAILED"
