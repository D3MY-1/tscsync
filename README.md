# tscsync

Fix for laptops whose firmware leaves the boot CPU's time-stamp counter (TSC)
seconds behind the other cores, which makes Linux reject the TSC and fall back
to the slow HPET clocksource.

Written for and tested on a **Lenovo Legion Slim 5 14APH8** (82Y5, Ryzen 7
7840HS, BIOS MACN24WW). The same bug is reported on the Legion 5 (5600H),
Legion 5 Pro / Legion Pro 5 (8745HX) and IdeaPad 5 14AHP9, so it is probably
Lenovo-AMD-wide. Nothing here is specific to that hardware.

## Do you have this bug?

```
cat /sys/devices/system/clocksource/clocksource0/current_clocksource   # hpet instead of tsc
journalctl -k -b | grep -i tsc
```
```
TSC synchronization [CPU#0 -> CPU#2]:
Measured 9893444143 cycles TSC warp between CPUs, turning off TSC clock.
tsc: Marking TSC unstable due to check_tsc_sync_source failed
```

If you see **`check_tsc_sync_source failed`** at boot, this tool applies. If
the TSC was instead demoted *later* by the clocksource **watchdog** (`Marking
clocksource 'tsc' as unstable because the skew is too large`), it does **not**:
that is drift/jitter, and forcing `tsc=reliable` there breaks timekeeping.

Confirm with the tool (no root needed):

```
gcc -O2 -pthread -o tscsync tscsync.c
./tscsync --measure
 cpu     TSC - TSC(ref)        seconds
   0        -9893444276      -2.608395  <-- out of sync
   1                  0       0.000000  (ref)
   2                -19      -0.000000
   ...
```

One core seconds off, the rest agreeing to a few cycles: that is the firmware
bug. The offset is different every boot and permanent for the session — it
is not a boot-time race that settles.

## Why it matters

With HPET, every `clock_gettime()` is a syscall plus a slow MMIO read:
~1300 ns instead of ~20 ns (the vDSO fast path only supports the TSC). Games
read the clock hundreds to thousands of times per frame; the cost ranges from
a few percent to 3x in timer-heavy titles. Anything that reads `rdtsc`
directly in userspace (GE-Proton >= 11-7's `QueryPerformanceCounter` fast
path, some anti-cheats) sees the raw offset and breaks outright.

## Why not just `tsc=reliable`?

That is the fix circulating on Reddit. It makes the kernel skip the sync check
and trust the counter as-is, so system time jumps by the offset whenever the
timekeeping tick lands on the lagging core. The desktop feels fine because the
kernel clamps most reads to a <=1 ms hiccup, but `journalctl -u chronyd` shows
multi-second steps and journald logs "Time jumped backwards". Games see
negative frame deltas. Measured on this laptop: -16 s and -8 s clock steps
within two minutes of boot.

`tsc=reliable` is only safe **after** the offset has been removed. That is
what this tool does.

## What it does

`tscsync --apply` measures each core's TSC against the majority (symmetric
ping-pong between pinned threads, the same method as the kernel's
`check_tsc_warp`, so signal latency cancels), then writes `IA32_TSC` (MSR
0x10) on any out-of-sync core through `/dev/cpu/N/msr`, from a thread pinned
to that core. The write's own latency is learned from the residual and
compensated on the next pass; it converges in 2-3 passes to within ~100
cycles (~25 ns). Takes ~50 ms.

`tscsync.service` runs it as early as systemd allows (`DefaultDependencies=no`,
`Before=sysinit.target`). With `tsc=reliable` on the kernel command line the
kernel keeps the TSC, and from that point on every core agrees. If the sync
fails for any reason the unit switches the kernel to HPET, so the failure mode
is "slow but correct", never "broken time".

`tscsync-resume.service` runs the same `tscsync --apply` after every resume from
suspend or hibernation. Hibernation and S3 (`deep`) suspend wake
up through the firmware, which can leave one or more cores' TSCs behind again.
s2idle does not redo CPU start-up, so the resume unit should detect every core
in sync; TSC is still checked and synced if a desync occurs.
Same HPET fallback as the boot unit. Check which suspend mode you use with
`cat /sys/power/mem_sleep` (the bracketed entry is active).

Verified across reboots: `clocksource tsc`, all cores within ~1000 cycles,
`clock_gettime` 18 ns, chrony quiet, GE-Proton 11-7 games fixed.

Known residual: on a Fedora initrd with NVIDIA modules the unit runs ~15 s
after kernel start, so the kernel accumulates a few seconds of error before
the sync and chrony steps the wall clock once at first NTP sync. A dracut
module that runs the sync from the initramfs would remove that; not done yet.

## Requirements

- x86-64 Linux with systemd; `gcc`; `grubby` for the kernel-argument step
  (Fedora/RHEL — on other distros add `tsc=reliable` your bootloader's way).
- **Secure Boot off** (kernel lockdown blocks MSR writes). `install.sh`
  checks this.
- The kernel logs a "Write to unrecognized MSR 0x10" line and sets the
  `CPU_OUT_OF_SPEC` taint flag on every apply. Harmless; expected.

## Install / verify / remove

```
sudo sh install.sh        # preflight checks, backup of boot entries, build, unit, tsc=reliable
sudo reboot

cat /sys/devices/system/clocksource/clocksource0/current_clocksource   # tsc
tscsync --measure                                                       # every row ~0
journalctl -u tscsync -b                                                # "cpu0 pass 1: off=..." -> "in sync"
journalctl -u chronyd -b | grep -E "stepped|wrong by"                   # small or none

sudo systemctl suspend                                                  # or hibernate; after waking:
journalctl -u tscsync-resume -b                                         # one run per resume, no FAILED
tscsync --measure                                                       # every row ~0 again

sudo sh uninstall.sh      # revert everything, then reboot
```

`install.sh` refuses to run if the bug pattern is not present or lockdown is
on. Backups of `/boot/loader/entries/*.conf` and `/etc/default/grub` go to
`/root/tscsync-backup/<timestamp>/`. To recover a boot that went wrong, press
`e` at the GRUB menu and delete `tsc=reliable` for that one boot.

## Files

| file | purpose |
|---|---|
| `tscsync.c` | the tool: `--measure` (read-only), `--apply [--quiet]` (writes MSR) |
| `tscsync.service` | early-boot oneshot unit with HPET fallback |
| `tscsync-resume.service` | re-sync after every resume from suspend/hibernate, same fallback |
| `msr.conf` | `/etc/modules-load.d/` entry so `/dev/cpu/N/msr` exist |
| `install.sh` / `uninstall.sh` | install with preflight + backup / full revert |
| `diag/clk.c` | cost of one `clock_gettime` call |
| `diag/monoc.c` | the kernel's monotonic clock as seen from each core |

## Not covered

- **The moment after resume**: between wake-up and `tscsync-resume.service`
  running, any core(s) the firmware left behind are still out of sync.
  The kernel's timekeeping and any program reading the TSC in this time-window
  will still see the TSC desync, so the clock can jump. NTP corrects this later.
- **Firmware fix**: none known. A Legion Pro 5 owner reported the warp
  persisting after a BIOS update. Lenovo does not publish these through LVFS.

## License

MIT.
