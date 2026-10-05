#!/bin/sh
# Reverts everything install.sh did. Run as root, then reboot.
# After this the kernel boots exactly as before: TSC rejected at boot, clocksource hpet.
set -u
echo "== kernel argument"
grubby --remove-args="tsc=reliable" --update-kernel=ALL
echo "== unit"
systemctl disable tscsync.service tscsync-resume.service 2>/dev/null
rm -f /etc/systemd/system/tscsync.service /etc/systemd/system/tscsync-resume.service /etc/modules-load.d/msr.conf
systemctl daemon-reload
echo "== tool"
rm -f /usr/local/sbin/tscsync
rm -rf /usr/local/src/tscsync
echo "== result"
grubby --info=DEFAULT | grep -E '^(kernel|args)'
echo "Reverted. Backups of the boot entries are still in /root/tscsync-backup/. Reboot to take effect."
