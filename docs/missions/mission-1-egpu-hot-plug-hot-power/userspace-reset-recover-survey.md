# Userspace reset/recover API survey

**Status:** v1 2026-05-26
**Purpose:** Before committing to driver-level patches that handle reset/recovery, enumerate what's ALREADY available in userspace. Identify which APIs can serve as (a) post-wedge recovery primitives, (b) pre-emptive quiesce primitives before known-risky operations.
**Scope:** sysfs PCI reset/remove/rescan, pciehp slot control, nvidia-smi/NVML, nvidia-modprobe, runtime PM, boltctl, kubernetes-level controls
**Why:** complements the surprise-removal audit. If a recovery primitive already exists, the patch scope shrinks accordingly.

## Section A — sysfs PCI reset/remove/rescan

The PCI core exposes these under `/sys/bus/pci/devices/0000:04:00.0/` (the GPU) and equivalent paths for other devices in the TB subtree:

| Knob | Type | Effect | Tested |
|---|---|---|---|
| `remove` | write `1` | Software-initiated graceful unbind. Sends `pci_remove` callback to the driver, which releases state cleanly. Device disappears from sysfs. | ✓ **E11 Run 1 — SAFE, no wedge, bridge windows preserved** |
| `reset` | write `1` | Issues reset using the method specified in `reset_method`. Currently configured: `flr bus` (FLR preferred, fall back to bus reset). | gated on no-clients (see Section D) |
| `reset_method` | read/write | Currently: `flr bus`. Available reset methods from kernel + device caps. The GPU has FLR support (lspci shows `FLReset+` in DevCap). | read only — confirmed FLR available |
| `rescan` | write `1` | Re-enumerate the device (and its bridge subtree) after a `remove`. Used in pair with `remove` for the E11 flow. | ✓ E11 Run 1 |
| `enable` | read/write | Enable/disable the PCI device. Less destructive than remove. | not tested |
| `power/control` | read/write | Runtime PM control. Currently `on` — never D3cold. | not tested (would require enabling first) |
| `d3cold_allowed` | read/write | Currently `1` — D3cold allowed by ACPI but driver keeps device in D0 | informational |
| `broken_parity_status` | read/write | Parity error tracking | not relevant |

Also at the bus level:

| Path | Effect |
|---|---|
| `/sys/bus/pci/rescan` | Global rescan — re-enumerates the entire PCI tree from root |

## Section B — pciehp slot power-cycle

`/sys/bus/pci/slots/12/` covers bus 0000:02:00 (the TB upstream hub). Its `power` knob, written with `0` then `1`, drives the pciehp hot-add/hot-remove state machine — including powering off and back on the entire TB-tunneled subtree (everything from 02:00.0 down through 04:00.0).

This is **the E02 mechanism**. From this survey's perspective, it's a structurally-different reset primitive — it goes through pciehp's controller rather than the device-level FLR/bus-reset path. Effects:

- **Drives `pciehp_unconfigure_device()` → `pci_stop_and_remove_bus_device()` for every device under the slot**
- Then on power-on: `pciehp_configure_device()` → `pci_scan_slot()` → `pci_assign_unassigned_bridge_resources()` (the runtime hot-plug allocator — see `pci-cmdline-audit.md`)

E02 itself is PENDING; this survey doesn't change its status, but informs the experiment write-up.

## Section C — `nvidia-smi` reset operations

```
nvidia-smi -r            → FLR (default)
nvidia-smi -r bus        → bus reset (more aggressive)
nvidia-smi -pm 0/1       → persistence mode off/on
```

These are NVML-mediated. Internally they call into the driver's reset path which ultimately reaches the kernel's `pci_reset_function()` or equivalent.

**Tested with current healthy GPU:**

```
$ sudo nvidia-smi -r
The following GPUs could not be reset:
  GPU 00000000:04:00.0: In use by another client

1 device is currently being used by one or more other processes (e.g.,
Fabric Manager, CUDA application, graphics application such as an X
server, or a monitoring application such as another instance of
nvidia-smi). Please first kill all processes using this device and all
compute applications running in the system.
```

**`nvidia-smi -r` requires zero clients on the GPU.** The device plugin's NVML probes count as clients. Persistence mode itself counts.

**Implication:** `nvidia-smi -r` is NOT a viable wedge-recovery primitive on its own — because the wedge state has clients connected (that's PART of the wedge mechanism). It's also NOT a viable pre-emptive primitive without quiescing all clients first. With quiesce, it works like sysfs `reset` (same underlying mechanism).

## Section D — pre-emptive quiesce mechanisms

For ANY reset operation to succeed, we need to first quiesce all GPU clients. The relevant primitives:

| Step | Command | Effect |
|---|---|---|
| 1. Drain vLLM workload | `kubectl scale -n vllm deployment/vllm --replicas=0` | Removes the primary compute consumer |
| 2. Cordon node | `kubectl cordon obpc` | Prevents new GPU-consuming pods from scheduling during quiesce |
| 3. Delete device plugin pod | `kubectl delete pod -n kube-system nvidia-device-plugin-daemonset-*` | Stops the NVML probe loop (every ~30s). With node cordoned, won't reschedule. |
| 4. Delete injector pod | `kubectl delete pod -n kube-system nvidia-driver-injector-*` | Stops the PC-3 heartbeat. With node cordoned + OnDelete strategy, won't reschedule. Module stays loaded. |
| 5. Disable persistence | `nvidia-smi -pm 0` (on the host) | Disengages persistence mode. Driver releases internal state holders. |
| 6. (Optional) rmmod nvidia chain | `rmmod nvidia_uvm nvidia` | Unloads driver entirely. Zero clients possible. Module would need re-load. |

After step 5 (with steps 1-4 done), `lsof /dev/nvidia*` should return empty and `/sys/module/nvidia/refcnt` should be near-zero (just the bare module reference). Then sysfs `reset`, `remove`, or pciehp slot-power-cycle can proceed without "in use" errors.

This is essentially Recipe A's "full quiesce" from `_STARTING-STATE-RECIPE.md`. **It is the prerequisite for any reliable userspace reset operation.**

## Section E — TB-tunnel programmatic cycle (boltctl)

```
boltctl deauthorize <uuid>   → drop TB tunnel
boltctl authorize <uuid>     → re-establish TB tunnel
```

**Not tested in this survey** — without full quiesce, the deauthorize step would likely produce the same Xid 79/154 cascade as a physical cable yank (because the driver wouldn't know the disconnect is coming and would attempt RPCs to the gone GPU).

**Open question:** with full quiesce (Section D steps 1-5) in place first, does `boltctl deauthorize` produce a clean tear-down without wedging? This is testable but BLOCKED on confirming the surprise-removal patches (P-DISC-1 + P-DISC-2) work or not running it as a separate H7-discrimination experiment. Could be a valid E8 variant.

## Section F — module unload / reload

```
rmmod nvidia_uvm nvidia              → remove modules (requires no users)
modprobe --ignore-install nvidia     → reload (host modprobe.d defaults apply)
```

This is the heavy-weight reset — entirely removes the driver from kernel memory and re-initialises everything. **Only works if no clients hold /dev/nvidia*** — same quiesce prerequisites.

For wedge-recovery: rmmod likely fails too, because if the driver is wedged it cannot be safely removed (some kernel data structure may be held).

## Section G — recovery primitive availability matrix

For each potential recovery scenario, what primitives apply:

| Scenario | Primitive | Effective? | Notes |
|---|---|---|---|
| Healthy GPU, want to reset state | sysfs `reset` | YES with full quiesce | E12 will validate; FLR is the reset_method |
| Healthy GPU, want to test full re-enumeration | sysfs `remove` + `/sys/bus/pci/rescan` | YES — **proven E11 Run 1** | Recipe B; doesn't fire Xid 79/154 cascade |
| Healthy GPU, want to test pciehp path | `echo 0; echo 1 > /sys/bus/pci/slots/12/power` | YES with quiesce (E02 pending) | More aggressive than per-function remove |
| Healthy GPU, want full driver reload | rmmod + modprobe | YES with full quiesce | Heavy but clean |
| **Wedged driver (post Xid 154 cascade)** | sysfs `reset` | NO — "in use by another client" | The wedge state still has clients connected |
| **Wedged driver** | sysfs `remove` | UNTESTED — likely deadlocks | The driver's `pci_remove` callback may not return cleanly |
| **Wedged driver** | rmmod | NO — module busy / deadlocks | If the driver itself is the deadlock site, removing fails |
| **Wedged driver** | pciehp slot power-cycle | UNTESTED — possibly works | This bypasses the driver and goes through pciehp. If the kernel's pciehp controller is not itself deadlocked, this might force a tear-down from outside the driver. |
| **Wedged driver** | forced reboot | YES — confirmed E07 Run 2 | The currently-validated recovery |
| **Pre-emptive quiesce before cable yank** | Section D steps 1-5 | hypothesis: YES | Untested as a complete sequence. E8 proper run would validate. |

## Section H — implications

### What this survey adds to the audit

**Driver-side patches are still required** for the wedge problem. The userspace primitives all REQUIRE a non-wedged driver state to operate. Once the driver is wedged (Xid 154 → assertion cascade), userspace reset operations either fail-fast ("in use") or potentially deadlock.

**However:** there is **one untested primitive that might recover from wedge state without forced reboot — pciehp slot power-cycle on slot 12.** This bypasses the wedged driver and goes through the kernel's pciehp controller. If the kernel's pciehp state machine is not itself deadlocked (it shouldn't be — it runs from a separate context), it could forcibly remove all devices under bus 02:00 (including the wedged driver's GPU), bypassing the driver's broken `pci_remove` callback. This is a worth-knowing recovery primitive even if speculative.

### Implication for patch scope

The wedge fix (P-DISC-1 + P-DISC-2 from `nvidia-driver-surprise-removal-audit.md`) does the right thing: **prevent the wedge from forming in the first place.** Once those patches are in:

- Cable yank → orderly tear-down (no cascade)
- All userspace primitives in Section A-D continue working as expected
- No need for new userspace recovery tooling — the existing primitives suffice

The userspace primitives don't OBVIATE the driver patch — they're complementary tools that REQUIRE the patches to be effective in the wedge scenario.

### Implication for `_STARTING-STATE-RECIPE.md`

Recipe A (cable yank) should be updated post-driver-patches to a simpler quiesce procedure, since the wedge risk would be eliminated. Today's Recipe A requires full quiesce (Section D); with P-DISC-1 + P-DISC-2 in place, "drain workload + cable cycle" might suffice (the device plugin's NVML probes would fast-fail post-disconnect instead of cascading into assertion failures).

## Section I — open follow-ups

1. **Test pciehp slot power-cycle on slot 12** as a wedge-recovery candidate — requires reproducing the wedge first, which currently requires accepting forced-reboot risk. Could be tested AFTER P-DISC-1/2 land (with quiesce in place, the wedge scenario becomes safe to reproduce on demand).
2. **Verify `boltctl deauthorize/authorize` with full quiesce** produces clean broken-BAR1 (not wedge) — would be an alternative to physical cable yank. May obviate the need for physical action during Phase 2 testing.
3. **E12 (FLR via sysfs reset)** pending; this survey shows the prerequisites (full quiesce). When E12 runs, validate the quiesce protocol works.
4. **Compose `quiesce.sh` helper script** — encapsulates Section D's 5-step procedure. Useful for any future test that requires no-clients state. Could live in `tools/` alongside `must-gather.sh`.

## Cross-references

- `nvidia-driver-surprise-removal-audit.md` — companion driver-side audit; this survey reduces the patch scope of P-DISC-1/2 to "prevent wedge formation" only (recovery is handled by existing userspace primitives + reboot fallback)
- `pci-cmdline-audit.md` — companion BAR1 audit (different problem class)
- `experiments/E02-pciehp-slot-power-cycle.md` — uses Section B mechanism
- `experiments/E11-per-function-remove.md` — uses Section A mechanism (proven safe)
- `experiments/E12-flr-reset.md` — uses Section A `reset` mechanism (pending; quiesce required)
- `experiments/_STARTING-STATE-RECIPE.md` Recipe A — Section D is the full quiesce protocol it references
