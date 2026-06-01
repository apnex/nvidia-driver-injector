# MISSION-1 — current experiment register (single source of truth)

**Updated:** 2026-05-31. **This doc supersedes the per-series indices for CURRENT status + priority.** The older docs (`mission.md`, `matrix.md`, `experiments/README.md`) are kept as historical provenance + execution detail; where they disagree with this register on *status*, this register wins.

**Why this exists:** the investigation grew four parallel series (BAR1 archaeology, open-arm wedge, shutdown, recovery integration) plus a 43-entry failure-mode catalog. The per-series indices each went stale as findings landed. This is the one place that reflects what is actually answered, open, or retired today.

---

## 1. Failure-mode map (the active ones)

Full catalog (43 modes) lives in `fake-5090/failure-modes/`. The modes this mission is actively working:

| Mode | What | Defense / status |
|---|---|---|
| **F41** | Chip ReBAR CTRL resets `0xF→0x8` on TB hot-add → broken-BAR1 (256 MB) | **SOLVED in userspace** by `tools/fix-bar1.sh` (chip CTRL write + pciehp slot-cycle), verified n≥2. **E27** = the in-kernel version (the destination). |
| **F40-open** | `RmInitAdapter` GSP lockdown-release stall on a userspace-recovered chip → host wedge | **Bounded** by A6 (`-EIO`); first-open hole **closed by A9** (apnex.24). Chip-side cause is #979 territory (contain, not cure). |
| **F42** | Leaked F40b bounded-wait worker → UAF if `rmmod`/rebind races it | A7 has the SH-3 `flush_work` guard; **A6 = gap** (Phase 0 is verifying whether this needs closing before the destructive ladder). |
| **F43** | `rm_shutdown_adapter` ~600 ms GSP-unload RPC latency (NOT a hang) | A7 budget `NVreg_TbEgpuShutdownTimeoutMs=1200`. Possibly deletable (v5). |

Sub-mission C (unexpected disconnect / Xid 154 / surprise-removal cascade — F33/F39) is a **separate parallel track** (A2/A3/C5 + the v4 cascade work), not part of the recovery-validation campaign below.

---

## 2. Investigation series — status

| Series | Question | Status |
|---|---|---|
| **BAR1 archaeology** (`matrix.md`, E01–E27; hypothesis **H10**) | Does any software path recover BAR1=32 GB on a re-plugged eGPU? | **ANSWERED 2026-05-28.** `fix-bar1.sh` is the trigger — it *is* **E16 (chip RBAR-CTRL write) + E2 (pciehp slot-cycle)** chained. H10 **CONFIRMED**; exit-criterion (a) met. **E2–E24 SUPERSEDED** (they hunted for a trigger we found). **E27** (in-kernel) stays live. |
| **Shutdown** (SH-0..3, #278–281) | Why does `rm_shutdown_adapter` "hang"? | **DONE.** It's a ~600 ms RPC, not a hang → produced the **F43**/**F42** split (2026-05-31). Closed. |
| **Open-arm** (OA Lanes 1–3, #282; `open-arm-forensics-ledger.md`) | F40-open root cause | **Lane 1+2 DONE** — site pinned (GSP lockdown-release, `kgspBootstrap_GH100 → gpuTimeoutCondWait`). **Lane 3 (destructive) + Rung-9 cure-vs-contain OPEN** (#285). |
| **Reset-efficacy ladder** (#286) | Does a runtime reset *cure* the open-arm wedge? | **RETIRED** — confounded/unsafe (the 2026-05-31 R0.5 reboot); subsumed into the recovery-validation campaign below (the cure question becomes the operational determinism question). |

---

## 3. Current prioritised work

1. **[ACTIVE] Deterministic userspace recovery validation** — prove a re-plugged eGPU recovers deterministically in userspace (`fix-bar1 --bind` + persistence + A9 net), until E27 retires it; the deterministic recipe *is* E27's acceptance spec. **Phase 0 (chip-free) COMPLETE 2026-05-31** — verdict: A9-bounded `-EIO` is **NOT clean** (source-confirmed F42 UAF on A6's open path, widened by A9), so the destructive ladder is **hard-gated on R0 = the A6 leak→join hardening** (chip-free). Plan (R0 + harness gates + R1–R3 + E27 spec + the R0 stop-rule): [`../../superpowers/plans/2026-05-31-deterministic-recovery-validation.md`](../../superpowers/plans/2026-05-31-deterministic-recovery-validation.md). The capstone that composes F41-recovery + F40-open containment + F42 + persistence. **UPDATE 2026-06-01: R0 deployed (apnex.25, A6 flush→join closing the F42 UAF) + R1 baseline-determinism PASSED 5/5, ZERO reboots** (`r1-baseline-determinism-20260601T044533Z`) — userspace recovery is **deterministic for the non-adversarial path** (broken-BAR1 → `fix-bar1 --bind` → 32768/Gen3/persistence/CUDA-ready, H2D 2.71–2.75 GB/s, A6 never armed). **Recipe sharpened:** complete recovery = `fix-bar1 --bind` **+ `nvidia_uvm` bringup** (`modprobe nvidia_uvm` + `nvidia-modprobe -u -c 0`) — fix-bar1-alone is nvidia-smi-ready but NOT CUDA/vLLM-ready; E27 acceptance must mean *CUDA-ready*. **R2 + R3 COMPLETE 2026-06-01 (zero reboots):** **R2 CONTAINED 10/10** (`rung2.sh` — every divergent fire bounded to `-EIO` ~210 ms, every worker JOINED, 0 KFENCE UAF, 0 wedge) and **R3 RACE-SAFE 10/10** (`rung3.sh` — immediate post-`-EIO` `rmmod` bounded 53–86 ms, no F42 double-UAF) with **CUDA-functional** post-fire recovery (nvbandwidth H2D 2.72–2.76 GB/s, 10/10). **Session-wide: 0 real KFENCE use-after-free across ~21 deliberate fires** ⇒ R0's `flush_work` empirically closes F42; the R0 stop-rule resolved favorably (worker self-terminates in ~60–80 ms, not the feared 4–30 s). The userspace recovery is now validated on the **clean path (R1) AND the adversarial bad-chip-open path (R2/R3)**. **NOT covered:** physical surprise-removal / live chassis power-cycle with the driver active (separate unrecovered wedge class = sub-mission B). Remaining rung: **R4** cure-vs-contain (lower-priority science, = the re-asked retired #286, now safe post-R0).
2. **[NEXT] E27** — in-kernel BAR1 recovery on the TB hot-add path (`pci_rebar_set_size` + bridge-window sizing). Spec'd by #1. The proper retirement of the userspace path. (`experiments/E27-pci-core-patch.md`.)
3. **[OPEN, lower] OA Lane 3 / cure-vs-contain** (#285) — the open-arm *science* (does any reset clear the divergence, or is it #979 territory). Can fold into #1's adversarial rung or run separately, reboot-loop.
4. **[RETIRED] #286** — subsumed by #1.
5. **[SUPERSEDED] E2–E24** — BAR1 archaeology answered. Keep **E27** (kernel target); **E25/E26** remain as kernel-alternative fallbacks.
6. **[PARALLEL] Sub-mission C** — surprise-removal / Xid-154 resilience (E8/E9 + cascade-class v4). Separate track; not gated on the above.

---

## 4. Terminology — two different "Phase 3"s

- **`matrix.md` "Phase 3"** = upstream kernel work (E25–E27). Still valid usage there.
- **The A9 plan's "Phase 3"** = the destructive validation phase of the deterministic-recovery campaign (item 1 above).

When ambiguous, say "**E27 / kernel work**" vs "**recovery-validation destructive phase**."

---

## 5. Sub-mission status (de-staled from mission.md's 2026-05-25 snapshot)

| Sub-mission | mission.md (2026-05-25) | Current (2026-05-31) |
|---|---|---|
| **A — hot-plug** (cable insert) | "probably works on idle GPU" | Re-plug → broken-BAR1 (F41) is **recoverable in userspace** via `fix-bar1.sh`; the determinism of that recovery is what item-1 validates. |
| **B — hot-power** (chassis power-cycle) | "definitively broken, multi-month" | **De-stale:** the broken-BAR1 outcome is **recoverable** via `fix-bar1.sh` (software slot-cycle = the bridge re-enum trigger H10 sought). E27 is the in-kernel fix. Not "definitively broken" — recoverable-with-a-userspace-step. |
| **C — unexpected disconnect** (Xid 154) | "partially handled, gap" | Still the surprise-removal wedge class; separate track (item 6). |

---

## 6. Cross-references

- `mission.md` — root doc + H1–H10 registry (2026-05-25 snapshot; see banner there).
- `matrix.md` — Phase-2 BAR1 archaeology matrix (H10 answered; see banner there).
- `experiments/README.md` + `experiments/E*.md` — per-experiment execution detail.
- `open-arm-forensics-ledger.md` — the live OA (F40-open) investigation (Lanes/Rungs).
- `shutdown-hang-ledger.md` — the closed SH investigation (→ F43/F42).
- `experiments/h1-userspace-recovery-2026-05-28.md` — the verified `fix-bar1` recovery (answers H10).
- `tools/fix-bar1.sh` — the recovery procedure under validation.
- `fake-5090/failure-modes/` — the full 43-mode catalog (F40 / F41 / F42 / F43).
