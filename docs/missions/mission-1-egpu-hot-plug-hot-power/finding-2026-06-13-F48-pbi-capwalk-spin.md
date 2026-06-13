# Finding — F48: probe-time PBI capability-walk infinite spin on a disconnected pci_dev (2026-06-13)

**Discovered:** during the apnex.32 live campaign (C7 cycle-3, the recover-disabled control). **Host SURVIVED**
— contained single-CPU spin, NOT an F44 wedge — but the device is unusable and the spinning modprobe is
unkillable (no signal check in the loop) → reboot to clear. Captured live via `sysrq-l` NMI backtrace:
`osPciReadByte ← pciPbiReadUuid ← RmGetGpuUuidRaw ← nv_pci_probe+0x645`.

## Mechanism (vendor latent bug, C6-class)
`src/nvidia/src/kernel/platform/chipset/pci_pbi.c:85-89` — the PBI capability-list walk:
```c
NvU32 cap_base = osPciReadByte(handle, PCI_CAPABILITY_LIST_BASE);
while (cap_base != 0 && pciPbiCheck(handle, cap_base) != NV_OK)
    cap_base = osPciReadByte(handle, cap_base + 1);
```
On a `pci_dev_is_disconnected` device every CONFIG-SPACE read returns `0xFF` instantly → `cap_base=0xFF`
forever (≠0, never matches) → unbounded busy-walk with no delay/no bound/no signal check. The kernel's own
`__pci_find_next_cap_ttl` bounds the walk (TTL=48) and treats 0xFF as a terminator; this loop does neither.

## Why this was previously unreachable (and what exposed it)
- CONFIG-SPACE reads are a **third I/O class**: the os_pci dead-bus short-circuit covers MMIO
  (`osDevReadReg*` → `osIsGpuBusDead`), C7 covers the GSP poll engines + hand-rolled MMIO/sysmem loops —
  **nobody covers `osPciRead*` consumers**, and the C7 13-site table scoped *re-open* polls, not *probe*.
- The trigger state is a **stale marked-disconnected `pci_dev`** (error_state=perm_failure persists across
  driver rebind): A13's AER early-free marked the device during a udev-raced first open; the subsequent
  modprobe re-probed the SAME pci_dev without re-enumeration → PBI walk on all-ones config space.
- All prior recoveries went through fix-bar1's **slot-cycle = fresh pci_dev** → clean cap list → never hit.

## Fix directions (next cycle; NOT yet built)
1. **Bound the walk** (the C6-style primitive fix, upstream-worthy): TTL-bound (48) + treat `0xFF` as
   terminator in `pciPbiGetCapability`; audit pci_pbi.c's other config polls (the command poll at :201 is
   `poll_limit`-bounded ✓; check the mutex loop at :102-126).
2. **Probe gate** (kernel-open): `nv_pci_probe` should bail early (`-ENODEV`) on
   `pci_dev_is_disconnected(pci_dev)` — probing a known-disconnected device is never useful.
3. **Config-space class coverage**: consider an `osPciRead*` dead-bus short-circuit mirroring the MMIO one
   (blast-radius audit needed — config reads are used at probe before any marker exists).

## Campaign status notes (context)
- Rung-3 A14 gate: PASS (13 ms refusal). C7 cycle-1 (min-obs): PASS (storm eliminated, contained, 1037 ms).
  C7 cycle-2 (loglevel 8): PASS — GAP-4 ANSWERED (zero storm lines under the netcon3 amplifier conditions =
  storm removed at SOURCE). Accidental R2 fast-fail regression set: PASS (bounded, not sunk, H2 correct).
- Cycle-3 (recover-disabled control) is INCOMPLETE: udev's modprobe (with modprobe.d Enable=1) won the race
  against the explicit `NVreg_TbEgpuRecoverEnable=0` load, so the control never actually ran disabled; the
  raced first open WAS contained (bounded rc=-5). Then the re-probe hit F48. Re-run the control after the
  F48 fix, setting the param via a temporary modprobe.d drop-in (not a raced CLI modprobe).
