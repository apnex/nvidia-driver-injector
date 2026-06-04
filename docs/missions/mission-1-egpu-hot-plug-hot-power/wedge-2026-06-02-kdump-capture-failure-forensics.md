# Forensics — 2026-06-02 — kdump capture FAILED → 2 hard reboots, no vmcore

**Verdict: the intentional `echo c` kdump did NOT produce a vmcore. The capture
kernel hung re-probing the wedged eGPU. Two hard resets were needed. The F45
rwsem-owner keystone remains UNconfirmed.** This was a planning error on my part
(see "Lesson").

## Evidence
- **No vmcore.** `/var/crash` has only an unrelated `127.0.0.1-2026-05-25` capture.
  Nothing written 2026-06-02. `pstore` empty.
- **kdump was never validated:** `kdumpctl` logged `WARNING: No vmcore creation
  test performed!` at arm time.
- **The capture initramfs ships `thunderbolt.ko`** (`/boot/initramfs-7.0.9-204…kdump.img`
  contains `drivers/thunderbolt/thunderbolt.ko.xz` + the injector modprobe/udev
  files). So the minimal capture kernel **brings up the TB stack and probes the
  eGPU** on boot.
- **Capture kernel cmdline is eGPU-hostile:** `KDUMP_COMMANDLINE_APPEND` has
  `reset_devices irqpoll nr_cpus=1 pcie_ports=compat panic=10 …` but **none** of
  the main kernel's eGPU-survival args (`thunderbolt.host_reset=false`,
  `iommu=off`, `pci=realloc=on,hpmmioprefsize=32G,resource_alignment=35@0000:03:00.0`).
  So it blind-resets the wedged TB bridge with no survival tuning.
- **BERT firmware error** on the recovery boot (`ACPI: BERT … [Hardware Error]:
  Skipped 1 error records`) confirms the unclean reset(s).
- `crashkernel=256M` — standard but tight; not the primary cause (the hang was the
  device probe, before makedumpfile).

## Root cause
The capture kernel = a minimal kernel that (a) loads `thunderbolt.ko`, (b) runs
`reset_devices`, (c) lacks every eGPU-survival cmdline arg. Booting that **over a
TB-tunnelled eGPU that was already wedged** hangs during TB/PCIe enumeration,
before `makedumpfile` ever runs → no vmcore. **The very hardware we wanted to dump
is what broke the dump.**

## Lesson (own it)
Triggering a kdump crash to "productively reboot + capture" a wedged-eGPU host was
the wrong call. On this platform the capture kernel re-probes the same wedged
TB/eGPU and hangs. Correct order would have been: (1) fix+TEST the capture path
first, or (2) capture the rwsem owner LIVE via drgn (no crash). Cost: 2 reboots, no
vmcore, F45 keystone still open.

## Fix the capture path (so a FUTURE wedge is dumpable)
1. Keep the eGPU OUT of the capture kernel — `rd.driver.blacklist=thunderbolt,nvidia,nvidia_uvm`
   + `module_blacklist=thunderbolt,nvidia` in `KDUMP_COMMANDLINE_APPEND` (the capture
   kernel only needs to read RAM + write NVMe; it must NOT touch the eGPU).
2. Bump `crashkernel=256M → 512M` (headroom for makedumpfile).
3. **Validate**: `kdumpctl test` / a controlled test crash while the eGPU is HEALTHY,
   so the path is proven before it's needed.
4. Rebuild: `kdumpctl rebuild && kdumpctl restart`.

## Getting F45's keystone without a vmcore
- Install `drgn` NOW → next deadlock, read the rwsem `owner` + wait-chain live from
  `/proc/kcore`, no crash.
- Meanwhile reconstruct the cycle from SOURCE (the 4 actor stacks in
  `wedge-2026-06-02-coldboot-apilock-deadlock-stacks.txt` + nvidia_close / deferred-open
  paths) — likely sufficient for the F45 fix design.
