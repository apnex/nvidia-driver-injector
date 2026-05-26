# PCI cmdline audit — runtime hot-plug allocation path

**Status:** v1 2026-05-26 — initial audit based on torvalds/linux master snapshot fetched 2026-05-26
**Purpose:** Enumerate `pci=` cmdline parameters and trace which affect the runtime hot-plug bridge-window allocation path. Convert E19 Run 1's narrow no-op observation into a properly-scoped statement about the cmdline mitigation lane.
**Scope:** `drivers/pci/setup-bus.c`, `drivers/pci/pci.c`, `drivers/pci/probe.c`, `drivers/pci/hotplug/pciehp_pci.c`, `Documentation/admin-guide/kernel-parameters.txt`
**Why:** retracts the inferential overreach in E19/E27 Patch design implications (see commit `fa99a71`). Replaces with audit-grounded claims.

## Section A — Enumeration of `pci=` cmdline parameters

From `drivers/pci/pci.c::pci_setup()` (the canonical `early_param("pci", pci_setup)` parser):

| Parameter | Sets | Affects |
|---|---|---|
| `nomsi` | `pci_no_msi()` | MSI globally disabled |
| `noats` | `pcie_ats_disabled = true` | ATS feature globally disabled |
| `noaer` | `pci_no_aer()` | AER subsystem disabled |
| `earlydump` | `pci_early_dump = true` | PCI config dump at boot |
| `realloc=on/off/auto` | `pci_realloc_enable` (via `pci_realloc_get_opt()`) | **Boot-time allocator retry loop (see Section B). NOT consulted by runtime hot-plug allocator.** |
| `realloc` (no `=`) | implicit `=on` | as above |
| `nodomains` | `pci_no_domains()` | PCI domain support |
| `noari` | `pcie_ari_disabled = true` | ARI globally disabled |
| `notph` | `pci_no_tph()` | TPH globally disabled |
| `resource_alignment=N@BDF` | `resource_alignment_param` (string) | Forces resource alignment for specified device(s). Acts at config-space sizing time — applies in BOTH boot and runtime paths. |
| `ecrc=` | `pcie_ecrc_get_policy()` | End-to-end CRC policy |
| **`hpiosize=N`** | `pci_hotplug_io_size` (variable) | **Additional I/O budget for is_hotplug_bridge buses** (consumed by `__pci_bus_size_bridges` — see Section B) |
| **`hpmmiosize=N`** | `pci_hotplug_mmio_size` | **Additional non-prefetchable MMIO budget for hotplug buses** |
| **`hpmmioprefsize=N`** | `pci_hotplug_mmio_pref_size` | **Additional prefetchable MMIO budget for hotplug buses** (this is the parameter E19 tested) |
| **`hpmemsize=N`** | both `pci_hotplug_mmio_size` AND `pci_hotplug_mmio_pref_size` | Combined-budget syntax (the E21 parameter) |
| **`hpbussize=N`** | `pci_hotplug_bus_size` | Hot-plug bus number reservation per bridge |
| `pcie_bus_tune_off` / `_safe` / `_perf` / `_peer2peer` | `pcie_bus_config` | PCIe bus config policy |
| `pcie_scan_all` | `pci_add_flags(PCI_SCAN_ALL_PCIE_DEVS)` | Scan policy |
| `disable_acs_redir=` | `disable_acs_redir_param` | ACS redirection |
| `config_acs=` | `config_acs_param` | ACS configuration |

Plus cardbus-specific handled by `pci_setup_cardbus()` (not relevant here).

Additionally, the `pcie_aspm=` family (parsed elsewhere — `drivers/pci/pcie/aspm.c`) controls ASPM link power management and is in Section 3 experiment E22.

## Section B — Path comparison: boot-time vs runtime hot-plug allocation

### Boot-time allocator: `pci_assign_unassigned_root_bus_resources()` (setup-bus.c:2170)

Called early during `pci_subsys_init` after device enumeration. Key structure:

```c
void pci_assign_unassigned_root_bus_resources(struct pci_bus *bus) {
    int tried_times = 0;
    int pci_try_num = 1;
    enum enable_type enable_local;

    /* Don't realloc if asked to do so */
    enable_local = pci_realloc_detect(bus, pci_realloc_enable);
    if (pci_realloc_enabled(enable_local)) {
        int max_depth = pci_bus_get_depth(bus);
        pci_try_num = max_depth + 1;
        dev_info(...);
    }

    while (1) {
        __pci_bus_size_bridges(bus, add_list);     // ← reads hp* hints
        pci_root_bus_distribute_available_resources(bus, add_list);
        __pci_bus_assign_resources(bus, add_list, &fail_head);
        tried_times++;

        if (list_empty(&fail_head)) break;
        if (tried_times >= pci_try_num) { ... break; }

        pci_prepare_next_assign_round(&fail_head, tried_times, leaf_only);  // ← gentle escalation
    }
}
```

**Properties:**
- Retry count = `max_depth + 1` ONLY when `pci_realloc_enable` is on/auto. Otherwise **1 try only.**
- Failure release type starts at `leaf_only` (gentle — releases only the failing leaf bridge's resources). Escalates internally if needed.
- Consumes `pci_hotplug_io_size`, `pci_hotplug_mmio_size`, `pci_hotplug_mmio_pref_size` via `__pci_bus_size_bridges` for `is_hotplug_bridge` buses.

### Runtime hot-plug allocator: `pci_assign_unassigned_bridge_resources()` (setup-bus.c:2251)

Called from `drivers/pci/hotplug/pciehp_pci.c::pciehp_configure_device()` when a device hot-plugs:

```c
void pci_assign_unassigned_bridge_resources(struct pci_dev *bridge) {
    int tried_times = 0;

    while (1) {
        __pci_bus_size_bridges(parent, &add_list);     // ← reads hp* hints (SAME as boot)
        pci_bridge_distribute_available_resources(bridge, &add_list);
        __pci_bridge_assign_resources(bridge, &add_list, &fail_head);
        tried_times++;

        if (list_empty(&fail_head)) break;
        if (tried_times >= 2) {                         // ← FIXED 2-try limit
            pci_dev_res_free_list(&fail_head);
            break;
        }

        pci_prepare_next_assign_round(&fail_head, tried_times, whole_subtree); // ← AGGRESSIVE
    }
}
```

**Properties:**
- Retry count = **fixed 2.** No depth-aware scaling.
- **No `pci_realloc_enable` check.** `pci=realloc=on` does NOT extend retries here.
- Failure release type = `whole_subtree` (more aggressive than boot's `leaf_only`).
- Consumes hp* hints via `__pci_bus_size_bridges` — SAME function as boot.

### Side-by-side

| Property | Boot allocator | Runtime hot-plug allocator |
|---|---|---|
| Entry function | `pci_assign_unassigned_root_bus_resources` | `pci_assign_unassigned_bridge_resources` |
| Called by | early `pci_subsys_init` | `pciehp_configure_device` |
| Retry count | `max_depth + 1` (with realloc) / `1` (without) | **fixed 2** |
| Checks `pci_realloc_enable`? | YES | **NO** |
| Reads `hp*` hints? | YES (via `__pci_bus_size_bridges`) | YES (same function) |
| Initial release strategy | `leaf_only` (gentle, escalates) | `whole_subtree` (aggressive) |

## Section C — Which parameters reach which path

| Parameter | Boot path effect | Runtime hot-plug path effect |
|---|---|---|
| `pci=realloc=on/off/auto` | **YES** — gates the deep retry loop | **NO** — not consulted |
| `pci=hpiosize=N` | YES — extra I/O budget for hotplug bridges | YES — same |
| `pci=hpmmiosize=N` | YES — extra non-prefetchable MMIO | YES — same |
| `pci=hpmmioprefsize=N` (E19) | YES — extra prefetchable MMIO | **YES — but only as "extra"** |
| `pci=hpmemsize=N` (E21) | YES — both mmiosize + mmioprefsize | YES — same |
| `pci=hpbussize=N` | YES — bus number reservation | YES (via depth probe) |
| `pci=resource_alignment=N@BDF` | YES — alignment forced at sizing | YES — same |
| `pcie_aspm=off` (E22) | controls link power; indirect | indirect — may affect when device is "ready" |

**Crucial nuance about hp* hints:** Per `__pci_bus_size_bridges` (line 1430-1435) and `pbus_size_mem` (line 1872-1882), the hp* values are **additional padding** for `is_hotplug_bridge` buses, NOT a forced minimum window size for the bridge that currently holds the GPU. The hint adds extra capacity for FUTURE hot-pluggable children below the bridge, on top of what current devices need. If the bridge already has a satisfied 32G allocation from device requests, the 32G hint is a no-op (the bridge is "big enough already"). If the runtime hot-plug allocator is failing because it can't fit a 32G device into a 288M window, that's a sizing failure that the hint can't fix because the hint is "extra above device needs," not "minimum guaranteed."

This re-frames E19 Run 1: the no-op at cold-plug was expected (current device satisfies allocation; hint adds no value). The hint MIGHT or might not affect runtime hot-plug — it depends on whether the failure mode at runtime is "child device requests not honored" (hint won't help) vs "bridge needs more room for future hot-plug children" (hint would help). The "broken-BAR1 = 288M" we observed at cable-replug is the FIRST case — the GPU's actual request (32G) wasn't honored — so the hint indeed doesn't apply to this failure mode.

## Section D — Design implications (audit-grounded)

### Finding 1: The runtime allocator's structural disadvantage vs boot

Boot uses up to `max_depth + 1` retries (gated on `pci=realloc=on`); runtime uses fixed 2 retries (ungated). For deep PCI hierarchies like a TB-tunneled subtree (root port → TB upstream → TB downstream → GPU = depth 3 or 4), boot has 4-5 chances to converge on the right allocation while runtime has only 2. **This is a likely contributor to the 288M failure at runtime hot-plug.**

### Finding 2: `pci=realloc=on` does not reach the runtime path

Boot's deep retry is gated on `pci_realloc_enable`. The runtime path doesn't check this flag at all. So the boot-time confidence that realloc-on provides ("deep retry available") doesn't transfer to hot-plug events.

### Finding 3: Three concrete patch-shape candidates emerge

A corrective patch could:

**Option A — extend the runtime allocator to check `pci_realloc_enable`:**
```c
/* In pci_assign_unassigned_bridge_resources, before the while loop */
int max_tries = 2;
if (pci_realloc_enabled(pci_realloc_detect(bus, pci_realloc_enable))) {
    max_tries = pci_bus_get_depth(bus) + 1;
}
/* ... use max_tries in the (tried_times >= max_tries) check */
```
Smallest blast radius. Mirrors boot's behavior under the existing cmdline flag. Users who want safer hot-plug behavior add `pci=realloc=on`.

**Option B — increase the runtime retry limit unconditionally:**
Change `if (tried_times >= 2)` to `if (tried_times >= pci_bus_get_depth(bus) + 1)`. No new cmdline knob; just better default. Wider blast radius — affects every hot-plug event globally. Upstream-friendly framing: "fix retry limit asymmetry between boot and hot-plug."

**Option C — mirror `pci_assign_unassigned_root_bus_resources` into the runtime path:**
Most invasive. Use boot's exact logic (retry count, release-type escalation, realloc check) for hot-plug allocation too. Largest change, but produces the cleanest semantic alignment.

All three options derive directly from the audit's identification of the boot-vs-runtime structural asymmetry. They differ in scope and reviewability.

### Finding 4: hp* hints likely don't address THIS failure mode

`hpmmioprefsize` is "additional padding above device needs" not "guaranteed minimum window." Since the failure mode is "device needs 32G but only 288M assigned," the hint can't fix this. The fix needs to be in the retry/escalation logic (Findings 1-3), not the sizing hints.

This is now a properly-bounded version of the earlier (retracted) claim "the bug is missing re-attempt, not missing hint." The retry mechanism IS the patch landing zone, but the path to that conclusion goes through the audit, not single-experiment inference.

### Finding 5: `pcie_aspm=off` (E22) targets a different mechanism

ASPM is link-power-management, not bridge-window allocation. It's plausible E22 affects whether the device is "settled" at the moment hot-plug allocation runs, but doesn't directly affect retry/sizing logic. Worth running for full empirical coverage, but unlikely to fix this specific failure mode.

### Finding 6: `resource_alignment` (E24) DOES reach both paths

The resource_alignment_param affects config-space sizing — `__pci_bus_size_bridges` reads the device's resource sizes which are affected by alignment. Different alignment values could change whether a child's allocation fits in the bridge's available window. Worth running E24's variants empirically.

## Section E — Corrections to prior writeups

### E19 Run 1 (commit `134ba47`, retracted in `fa99a71`)

The retraction in `fa99a71` was correct (the over-claim was unsupported). The audit now provides the properly-grounded replacement:

- **CORRECTLY RETRACTED:** "Eliminates the cmdline mitigation lane" — the audit shows hp* hints DO reach the runtime path (via `__pci_bus_size_bridges`), so the lane isn't closed by E19's result.
- **AUDIT-SUPPORTED REPLACEMENT:** "`pci=hpmmioprefsize=32G` is unlikely to fix THIS failure mode because hp* hints add padding above device needs, not minimum windows. The 288M failure is a device-request-not-honored failure, not a future-headroom-missing failure. Other parameters (`pci=realloc=on` if extended to runtime path; `resource_alignment` variants) may have effects worth empirically testing."

### E27 (commit `134ba47`, retracted in `fa99a71`)

The retraction was correct. The audit provides:

- **CORRECTLY RETRACTED:** "The bug is missing re-attempt, not missing hint" (too strong from one parameter).
- **AUDIT-SUPPORTED:** The runtime hot-plug allocator has structurally fewer retries (2 vs boot's `max_depth+1`) and doesn't honor `pci=realloc=on`. Three patch shapes (A/B/C in Section D) follow from this. Each is structurally different from "extend size hints" — the fix is in the retry/escalation logic. The original directional intuition was right; the audit grounds it in the actual code paths.

### Net update to E27 Patch design implications section

Replace the (retracted) "Missing re-attempt" entry with a new audit-grounded entry summarizing Sections B + D above. Three patch shape options (A/B/C) become the concrete candidates.

## Section F — Open questions still requiring empirical work

1. **`is_hotplug_bridge` flag for 03:00.0** — confirm via `lspci -vvv` whether the bridge that holds our GPU advertises `HotPlug+` in slot capabilities. If yes, hp* hints WOULD apply additional padding there. If no, the hint reaches only TB sub-ports 03:01-03:03 (which already had 10922M each).
2. **`pci_bus_get_depth(bus)` value for our TB hierarchy** — the actual retry count boot uses. Likely 3-4 (root port → TB upstream → TB downstream → GPU). Boot uses 4-5 tries; runtime uses 2.
3. **bpftrace `__pci_bus_size_bridges` at cold-plug** — capture which branch the boot-time path takes for the 03:00.0 sizing. Reference for the patch.
4. **bpftrace `pci_assign_unassigned_bridge_resources` at runtime hot-plug** — capture which branch FAILS in the 2-try loop. Direct evidence for which retry / release-strategy adjustment is needed.
5. **Empirical Section 3 coverage (E20, E21, E22, E24)** — confirm or disconfirm audit predictions about each parameter's effect.

## Cross-references

- `experiments/E18-cmdline-realloc-on.md` — empirical result that informed audit's `pci=realloc=on` analysis
- `experiments/E19-cmdline-hpmmioprefsize.md` — the no-op result that triggered the audit
- `experiments/E27-pci-core-patch.md` — design home for the corrective patch (three options A/B/C will be promoted there)
- `experiments/E07-cable-replug-drain-first.md` — parallel patch effort (TB-unplug-aware teardown)
- Memory: `feedback_single_datapoint_inferential_overreach_2026_05_26` — discipline lesson that motivated this audit
- Kernel source files audited: torvalds/linux master @ snapshot 2026-05-26 (drivers/pci/{pci.c, setup-bus.c, probe.c, hotplug/pciehp_pci.c})
