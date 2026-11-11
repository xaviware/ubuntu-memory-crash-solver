# Ubuntu Memory Crash Solver

A small, idempotent script + write-up to stop Ubuntu from **killing your desktop
apps "for no reason"** when memory gets tight.

Typical symptom:

> I'm using Cursor/VS Code, I open a browser, and one of them just closes.
> There's no crash dialog and no kernel panic. It feels random.

If that sounds familiar, your apps are very likely being killed by
**`systemd-oomd`**, not crashing.

---

## TL;DR

```bash
git clone https://github.com/xaviware/ubuntu-memory-crash-solver.git
cd ubuntu-memory-crash-solver
sudo bash fix-memory.sh              # oomd + zswap
# or, to also grow the swap file to 8 GB:
sudo bash fix-memory.sh --swap 8G
sudo reboot
```

The script:

1. **Relaxes `systemd-oomd`** from `50% / 20s` to `85% / 60s` (swap limit
   `90%` → `95%`). It still protects against real OOM, but stops killing apps
   during moderate memory pressure.
2. **Optionally grows the active swap file** to a size you choose with
   `--swap SIZE` (e.g. `--swap 8G`). It only enlarges, never shrinks.
3. **Enables `zswap` with `zstd`** (up to 40% of RAM) persistently via
   GRUB + initramfs, so pages are compressed in RAM instead of thrashing a slow
   disk.

No reboot is needed for the oomd change; a reboot is needed for zswap to be
enabled at boot time (the script also tries to enable it at runtime).

---

## Root cause

Since Ubuntu 22.04, `systemd-oomd` is enabled by default and Ubuntu ships
stricter settings than upstream:

| File | Setting |
| --- | --- |
| `/usr/lib/systemd/system/user@.service.d/10-oomd-user-service-defaults.conf` | `ManagedOOMMemoryPressure=kill`, `ManagedOOMMemoryPressureLimit=50%` |
| `/usr/lib/systemd/oomd.conf.d/10-oomd-defaults.conf` | `DefaultMemoryPressureDurationSec=20s` |

That means: **if memory pressure on your user session stays above 50% for more
than 20 seconds, `systemd-oomd` sends `SIGKILL` to the largest eligible cgroup**
— usually your editor or browser.

You can confirm it with:

```bash
journalctl -u systemd-oomd -b | grep Killed
```

Example from the affected machine:

```
Killed .../app-gnome-cursor-30344.scope due to memory pressure
for /user.slice/user-1000.slice/user@1000.service being 82.58% > 50.00%
for > 20s with reclaim activity
```

This is **not** a kernel OOM, **not** a hardware failure, and **not** a bad RAM
module. It is a userspace policy doing exactly what it is configured to do — but
the threshold is too aggressive for machines with 8 GB of RAM.

---

## Why some machines are hit harder

This was diagnosed on an **iMac18,1 (2017, 21.5")**:

- Intel Core i5-7360U (2C/4T), Intel Iris Plus Graphics 640 (shared memory).
- **8 GB RAM (7.1 GB usable)** — soldered on this model, **not upgradeable**.
- Swap is a **4 GB file on a 5400 rpm mechanical HDD**
  (`APPLE HDD HTS541010A9E632`, `rotational=1`).
- `zswap` disabled by default (`enabled=N`).
- Typical workload: Electron editors (Cursor/VS Code), Chromium/Firefox,
  GNOME, Docker containers, etc.

With a slow HDD, memory reclaim is extremely slow. Pressure builds up, stays
high, and `systemd-oomd` pulls the trigger long before the kernel would.

The same pattern applies to laptops/desktops with **4–8 GB RAM and/or a slow
disk (HDD, eMMC, SD card)**.

---

## What the script changes

### 1. `systemd-oomd` drop-ins

`/etc/systemd/oomd.conf.d/99-memory-crash-solver.conf`

```ini
[OOM]
DefaultMemoryPressureLimit=90%
DefaultMemoryPressureDurationSec=60s
SwapUsedLimit=95%
```

`/etc/systemd/system/user@.service.d/99-memory-crash-solver.conf`

```ini
[Service]
ManagedOOMMemoryPressureLimit=85%
```

Result: the user session is only acted on when pressure is **> 85% for 60 s**,
instead of **> 50% for 20 s**. The kernel OOM killer still handles genuine
exhaustion.

### 2. Optional: grow the swap file

```bash
sudo bash fix-memory.sh --swap 8G
```

The script detects the active swap **file** (not a partition), backs up nothing
here, and:

- only grows it (requesting a smaller size is a no-op);
- runs `swapoff`, `fallocate` (with a `dd` fallback), `chmod 600`, `mkswap`,
  and `swapon`;
- does **not** modify `/etc/fstab` (the path stays the same).

`swapoff` pulls swapped pages back into RAM, so close heavy apps first. On an
8 GB machine with `zswap`, 8 GB of swap is a reasonable amount of headroom. On
a 5400 rpm HDD, `zswap` absorbs most of the traffic; the disk is only used when
the compressed pool is full.

### 3. `zswap` with `zstd`

- Adds `zstd` and `lz4` to `/etc/initramfs-tools/modules`.
- Adds `zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=40` to
  `GRUB_CMDLINE_LINUX_DEFAULT`.
- Regenerates initramfs and GRUB.

Why `zswap` and not `zram`? Ubuntu's official guidance
([Enable memory compression](https://wiki.ubuntu.com/Enable_memory_compression))
recommends **zswap + zstd** for systems with **2–8 GB RAM** and for **slow
disks (HDDs)**, because Ubuntu already ships a swap file. `zram` is the better
choice when there is no swap storage at all.

> If your system has no `initramfs-tools`/GRUB (e.g. you use a different
> bootloader), apply the equivalent settings manually — see below.

---

## Requirements

- Ubuntu 22.04+ (or any distro using `systemd-oomd` and `initramfs-tools` +
  GRUB) — tested on **Ubuntu 26.04.1 LTS, kernel 7.0**.
- Root access (`sudo`).
- A swap device/file (Ubuntu default). `zswap` is a compressed cache in front
  of it, not a replacement.

---

## Usage

```text
sudo bash fix-memory.sh [--swap SIZE]

  (no options)   Relax systemd-oomd and enable zswap (zstd).
  --swap SIZE    Also grow the active swap file to SIZE (e.g. 8G, 8192M).
                 Only enlarges; needs free disk space and enough RAM for the
                 temporary swapoff.
  -h, --help     Show help.
```

Examples:

```bash
sudo bash fix-memory.sh              # oomd + zswap
sudo bash fix-memory.sh --swap 8G    # oomd + zswap + 8 GB swap
sudo reboot
```

The script is idempotent, creates timestamped backups (`.bak.YYYYMMDD-HHMMSS`)
of any file it modifies, and prints a verification summary.

### Verify after reboot

```bash
# oomd thresholds
oomctl | head -20
# expect: Memory Pressure Limit: 85.00% / Duration: 60s

# swap
swapon --show
free -h

# zswap
cat /sys/module/zswap/parameters/enabled          # Y
cat /sys/module/zswap/parameters/compressor       # zstd
cat /sys/module/zswap/parameters/max_pool_percent # 40
grep -E 'Zswap|Zswapped' /proc/meminfo
```

`Zswap:` should grow over time as the system compresses pages. To see whether
kills stop happening:

```bash
journalctl -u systemd-oomd --since "1 day ago" | grep Killed
```

---

## Manual alternative (no script)

### oomd

```bash
sudo install -d /etc/systemd/oomd.conf.d /etc/systemd/system/user@.service.d

sudo tee /etc/systemd/oomd.conf.d/99-memory-crash-solver.conf >/dev/null <<'EOF'
[OOM]
DefaultMemoryPressureLimit=90%
DefaultMemoryPressureDurationSec=60s
SwapUsedLimit=95%
EOF

sudo tee /etc/systemd/system/user@.service.d/99-memory-crash-solver.conf >/dev/null <<'EOF'
[Service]
ManagedOOMMemoryPressureLimit=85%
EOF

sudo systemctl daemon-reload
sudo systemctl restart systemd-oomd
```

If you prefer to disable pressure-based kills for your user session entirely,
set `ManagedOOMMemoryPressure=auto` in the `[Service]` drop-in instead. Be aware
that on very slow disks the kernel may then take much longer to react to real
exhaustion.

### zswap

```bash
# 1. Compressor modules available at early boot
echo zstd | sudo tee -a /etc/initramfs-tools/modules
echo lz4  | sudo tee -a /etc/initramfs-tools/modules

# 2. Kernel parameters (edit GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub)
#    append: zswap.enabled=1 zswap.compressor=zstd zswap.max_pool_percent=40

sudo update-initramfs -u
sudo update-grub
sudo reboot
```

### Grow the swap file

```bash
# Close heavy apps first: swapoff moves pages back into RAM.
sudo swapoff /swap.img
sudo fallocate -l 8G /swap.img      # or: sudo dd if=/dev/zero of=/swap.img bs=1M count=8192
sudo chmod 600 /swap.img
sudo mkswap /swap.img
sudo swapon /swap.img
```

`/etc/fstab` does not need to change (same path). Verify with `swapon --show`.

---

## Tuning knobs

| Setting | Default (Ubuntu) | This script | Effect |
| --- | --- | --- | --- |
| `ManagedOOMMemoryPressureLimit` | `50%` | `85%` | Higher = fewer premature kills |
| `DefaultMemoryPressureDurationSec` | `20s` | `60s` | Pressure must persist longer |
| `SwapUsedLimit` | `90%` | `95%` | Less swap-based killing |
| `zswap.max_pool_percent` | `20` | `40` | Larger compressed pool |
| `zswap.compressor` | `lzo` | `zstd` | Better compression ratio |

If 85% is still too aggressive or too lax for your machine, adjust the
`ManagedOOMMemoryPressureLimit` value.

---

## Rollback

```bash
sudo rm -f /etc/systemd/oomd.conf.d/99-memory-crash-solver.conf \
           /etc/systemd/system/user@.service.d/99-memory-crash-solver.conf

# Restore the GRUB backup created by the script (adjust the timestamp):
sudo cp -a /etc/default/grub.bak.<TIMESTAMP> /etc/default/grub

# Remove zstd/lz4 lines you added to /etc/initramfs-tools/modules, then:
sudo update-initramfs -u
sudo update-grub
sudo systemctl daemon-reload
sudo systemctl restart systemd-oomd
sudo reboot
```

Other options:

```bash
# Keep oomd but stop it from monitoring/acting on your session:
#   set ManagedOOMMemoryPressure=auto on user@.service

# Or disable systemd-oomd completely (not recommended without a replacement):
sudo systemctl disable --now systemd-oomd
```

---

## Notes and caveats

- This fixes **premature userspace kills**. If you are genuinely out of RAM,
  something will still be killed — but only when it is actually necessary.
- It does **not** add RAM. On soldered-RAM machines, reducing memory usage
  (fewer Electron apps/tabs, stopping Docker containers, lighter browser) and
  moving swap to an SSD remain the best long-term improvements.
- The `DMAR ... [02:00.0]` messages some iMacs show are related to the Broadcom
  Wi-Fi card and are **unrelated** to these kills.
- Verify your own logs before and after; thresholds that work for an 8 GB
  machine may need adjustment for 4 GB or 16 GB systems.

---

## License

MIT — see [LICENSE](LICENSE).
