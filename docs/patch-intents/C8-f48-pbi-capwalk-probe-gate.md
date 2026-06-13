---
id: C8-f48-pbi-capwalk-probe-gate
layer: base
source-branch: c8-f48-pbi-capwalk-probe-gate
upstream-candidacy: high
telemetry-tier: nominal
status: v1-implemented-compiled-validated
related-patches: [C7-292-inflight-deadbus-poll-coverage, A13-292-inflight-aer-earlyfree, A14-292-reopen-failfast-gate, C5-crash-safety]
---

# C8-f48-pbi-capwalk-probe-gate — Bound the PBI Capability Walk and Refuse to Probe a Disconnected Device

## Purpose

The driver SHALL NOT spin unboundedly on PCI CONFIG-SPACE reads of a
disconnected device, and SHALL NOT probe a pci_dev the kernel has already
marked surprise-removed. F48 (live, 2026-06-13, apnex.32 campaign cycle-3):
`pciPbiFindCapability` walks the PCI capability list with no TTL and no
all-ones terminator; on a `pci_dev_is_disconnected` device every config read
returns `0xFF` → `cap_base=0xFF` forever → an unkillable 100%-CPU spin in
`nv_pci_probe → RmGetGpuUuidRaw → pciPbiReadUuid`, holding the device lock
(host survives — contained 1-CPU spin — but the device is lost until reboot).
Config space is a THIRD I/O class: covered by neither the os.c MMIO dead-bus
short-circuit (`osIsGpuBusDead`) nor [[C7-292-inflight-deadbus-poll-coverage]]'s
poll-reader table (which scoped re-open MMIO/sysmem polls). The persistent
capability granted: "no probe-time config-space poll can spin unbounded on a
dead device, and a stale marked-disconnected pci_dev is refused at probe
entry — recovery is a re-enumeration (fresh pci_dev), never a spin."

## Mechanism — the two edits

- **C8-e1** `src/nvidia/src/kernel/platform/chipset/pci_pbi.c`
  (`pciPbiFindCapability`): TTL-bound the walk (48, mirroring the kernel's
  `PCI_FIND_CAP_TTL` in `__pci_find_next_cap_ttl`) and treat `0xFF` as a
  terminator (an offset of 0xFF can never hold a 2-byte cap header in
  256-byte config space). Dead bus / malformed list → return 0 ("PBI not
  found") → callers take their existing not-supported path. The same fix
  covers both `pciPbiFindCapability` callers (`pciPbiReadUuid` and the
  version-info reader). The file's other loops are already bounded
  (mutex acquire = single-try; command poll = `poll_limit` + `osDelay`).
- **C8-e2** `kernel-open/nvidia/nv-pci.c` (`nv_pci_probe`, before any
  allocation or chip touch): early `-ENODEV` when
  `os_pci_is_disconnected(pci_dev)` — `pci_dev->error_state` persists across
  driver rebind, so a modprobe after a contained in-flight failure
  ([[A13-292-inflight-aer-earlyfree]]'s marker) re-probes the SAME stale
  pci_dev. Probing a device the kernel has declared gone is never useful;
  re-enumeration (slot-cycle / TB re-auth / cold-plug) creates a fresh
  pci_dev and probes cleanly.

## Requirements

### Requirement: the PBI capability walk terminates on a dead bus

The walk MUST terminate within 48 iterations and MUST treat an all-ones
capability pointer as end-of-list, returning "PBI not found".

#### Scenario: probe of a disconnected device reaches the PBI walk
- GIVEN a pci_dev whose config reads return 0xFF (disconnected/removed)
- WHEN `pciPbiFindCapability` runs
- THEN it returns 0 within 48 iterations and the caller logs
  "Device does not support PBI" and proceeds without UUID

### Requirement: a marked-disconnected pci_dev is refused at probe entry

`nv_pci_probe` MUST return `-ENODEV` before any allocation or chip access
when the device is marked disconnected, and MUST log the `[C8]` refusal line
naming re-enumeration as the recovery.

#### Scenario: modprobe onto a stale surprise-removed pci_dev
- GIVEN a pci_dev with `error_state == pci_channel_io_perm_failure` left by a
  prior contained failure
- WHEN nvidia is modprobed/bound without an intervening re-enumeration
- THEN probe returns -ENODEV promptly (no spin, no device lock held), and a
  subsequent slot-cycle/TB-reauth + bind probes the fresh pci_dev normally

### Requirement: healthy-path behavior is byte-identical

On a live device the TTL/0xFF tests MUST be pure-FALSE no-ops (the walk finds
PBI or hits a genuine 0 terminator well inside 48 steps) and the probe gate
MUST NOT fire.

#### Scenario: clean cold-plug probe
- GIVEN a freshly enumerated healthy device
- WHEN nv_pci_probe runs
- THEN no `[C8]` line is emitted and probe/UUID behavior is unchanged

## Scope boundary

- Does NOT add an `osPciRead*`-class dead-bus short-circuit (the third-class
  general guard) — config reads run at probe before any marker can exist and
  the blast-radius audit has not been done; tracked as a follow-on in the F48
  finding. C8 fixes the one proven-unbounded consumer + gates the only
  proven-reachable path to it.
- Does NOT change PBI semantics on healthy devices, the mutex protocol, or
  the bounded command poll.
- Upstream-bound (base layer): both edits are vendor-correct hardening
  (kernel-idiom TTL walk; do-not-probe-removed-devices), independent of the
  eGPU project specifics.

## Telemetry contract

One `NV_DBG_ERRORS` line on the probe-gate refusal
(`tb_egpu [C8]: refusing to probe disconnected device <bdf> …`). The bounded
walk emits nothing new (existing "Device does not support PBI" INFO line
covers the dead-bus return). No counters.

## Provenance

- Finding: `docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-13-F48-pbi-capwalk-spin.md`
  (live sysrq-l NMI capture of the spin; reachability analysis).
- Catalog: `fake-5090/failure-modes/F48-pbi-capwalk-config-spin.md`.
- Discovered during the apnex.32 #292 live-validation campaign (cycle-3), the
  first time the stack survived long enough to re-probe a stale marked
  device. Sibling of [[C7-292-inflight-deadbus-poll-coverage]] (same
  dead-bus family, different I/O class). Compile-validated against
  7.0.9-204.fc44; healthy-path no-regression validated by the apnex.33
  deploy cold-init.
