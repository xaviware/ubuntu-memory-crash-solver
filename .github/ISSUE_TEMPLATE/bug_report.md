---
name: Bug report
about: Report a problem with the script or an unexpected result
title: "[bug] "
labels: bug
assignees: ''
---

## What happened

A clear description of what went wrong.

## Expected behavior

What you expected to happen instead.

## Environment

- OS / version: <!-- e.g. Ubuntu 26.04.1 LTS -->
- Kernel: <!-- uname -r -->
- RAM: <!-- e.g. 8 GB -->
- Swap: <!-- swapon --show -->
- Disk type: <!-- HDD / SSD / eMMC -->
- `zswap` enabled: <!-- cat /sys/module/zswap/parameters/enabled -->

## Diagnostics

```text
# oomctl | head -20
```

```text
# journalctl -u systemd-oomd --since "1 day ago" | grep -iE "killed|pressure"
```

```text
# grep -E "Zswap|Zswapped|MemTotal|SwapTotal" /proc/meminfo
```

## Additional context

Anything else that might help.
