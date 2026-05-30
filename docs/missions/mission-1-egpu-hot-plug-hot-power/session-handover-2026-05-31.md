# MISSION-1 session handover — 2026-05-31

**Purpose:** Full state snapshot for a fresh session to resume without context loss. This session ran the open-arm (#282) forensics through Lane 2, discovered + fixed an A6 coverage defect, and **deployed it to production (apnex.24)**. Supersedes `session-handover-2026-05-30.md`.

## TL;DR — what to know walking in

1. **Production is now `595.71.05-apnex.24`** (was apnex.23 — most memories still say apnex.23; this is the correction). Healthy, pod 1/1. The deploy upgraded apnex.23 → apnex.24 (A9 + A8 v2.2).
2. **The open-arm wedge mechanism is CONFIRMED (Lane 2, n=4):** `nv_open_device → rm_init_adapter → RmInitAdapter → kgspInitRm_IMPL → kgspBootstrap_GH100 → gpuTimeoutCondWait(_kgspLockdownReleasedOrFmcError)` — the **GSP never releases lockdown after FSP boot**. It's a *pre-RPC* sub-wait (earlier than GSP_INIT_DONE). The contained fire shows **no AER/CTO** → it's a **graceful busy-poll holding the GPU lock** (→ H-OA6), not a hung-read CTO.
3. **A real A6 defect was found AND fixed this session: the first-open coverage hole.** A6/A7 gate on `nv->is_external_gpu`, which the blob sets lazily during the first open's `RmInitAdapter` (`osinit.c:1301`) — so the **first open of any bind is unguarded**. A re-probe onto a bad chip makes the dangerous re-init that unguarded first open → wedge (reproduced 2026-05-31, the reset-ladder R0.5 wedge, 2 reboots).
4. **The fix — A9 (deployed, verified):** one line in `nv_pci_probe` setting `is_external_gpu` at probe via E1's `os_pci_is_thunderbolt_attached`. E1/A6/A7 unchanged; monotonic. **Verified non-destructively:** E1 `external GPU detected` now fires AT PROBE (apnex.23 fired it 6 s later, at the first open); first open is A6-wrapped; `tb_egpu_is_external=1`.
5. **SCOPE DISCIPLINE (load-bearing):** A9 **closes the A6-coverable first-open hole** — it does **NOT** "fix the open-arm wedge." It converts an immediate syscall-thread wedge into A6's bounded `-EIO` *with a worker A6 leaks*. The bad-chip survivability is UNTESTED (Phase 3, gated).
6. **EVERYTHING IS LOCAL — nothing pushed all session.** ~40 injector `main` commits + the fork branches `a5–a9` (the version cascade rebased a5–a8 → new SHAs). Pushing = force-push carve-out for a5–a8 + new a9. The push is an unmade decision.

## Current production + repo state

```
Driver:        595.71.05-apnex.24  (C1-C5 + E1 + A1-A9). LIVE, healthy, P8, BAR1 32 GiB.
               /sys/module/nvidia/version == apnex.24 == image tag == node label.
A8 sysfs:      tb_egpu_{state=healthy, is_external=1, f40b_fires, recovery_*, qwd_*}  on 0000:04:00.0
A9 (new):      probe-time is_external_gpu set; first open now A6-guarded (verified).
Pod:           nvidia-driver-injector-<...> 1/1 Running (image apnex.24)
Host:          obpc (NUC15). I RUN ON IT — a hard wedge kills the session; recovery = user reboot.
Injector repo: /root/nvidia-driver-injector, branch main, ~40 commits ahead of origin (NOT pushed)
Fork repo:     /root/open-gpu-kernel-modules, branch a9-egpu-probe-classify.
               Tips (local, NOT pushed): a5 c7856450, a6 94b655fa, a7 3ac5a9a9, a8 a890d7b3, a9 36934600
```

## The session arc (what happened, in order)

1. **#282 design** (chip-free, 7-agent workflow): 12 hypotheses H-OA1..H-OA12; H-OA1 (GSP init RPC) and H-OA2 (pre-`nv_open_device` site) **co-leading**; adversarial critique forced 4 must-fixes. Ledger: `open-arm-forensics-ledger.md`.
2. **Lane 1** (chip-free, over the 13 archived 2026-05-29 wedge captures): **H-OA4 IOMMU / H-OA5 Gen3 / H-OA7 firmware = falsified-as-sole-cause; H-OA8 surprise-removal = FALSIFIED** (Xid==0). The `verify-wedge` journal (sole survivor of the trigger) = Rosetta Stone: `NV_ERR_GPU_IS_LOST` at `GSP_INIT_DONE` → WPR2 downstream (refines `project_wpr2_mechanism_2026_05_06`). Banked into the **#979 forensic draft** (`upstream-979-open-arm-characterization-DRAFT.md`, NOT posted).
3. **Built `tools/oa-harness/`** — committed freeze-safe harness (fsync'd `oa_mark`, BAR1-first, Rung-3.5 D0-pin/A6-assert, precondition, PMU sampler).
4. **Lane 2** (contained, D0-pinned, A6 present): **site CONFIRMED** (above). H-OA10 falsified; Rung 5 no-CTO → H-OA1b/H-OA6. A6 validated for the D0 site.
5. **Reset-efficacy ladder (#286)** — designed as the constructive cure test (does a runtime reset cure?). R0.5 (rebind) **WEDGED the host (2 reboots)**. Forensics (`experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md`, adversarially verified): the **A6 first-open coverage hole**. The ladder is **unsafe + confounded** (all variants rebind → A6 bypassed; FLR/SBR break BAR1) → DANGER banner; needs redesign.
6. **A8 v2.2** — added `tb_egpu_is_external` (exposes the gate flag) for observability + a pre-flight guard.
7. **A9 fix** — brainstorm → spec → plan → executing-plans (superpowers skills). 8-agent design panel caught my **false "osinit.c is a precompiled blob" premise** (it's source-compiled). Recommended the one-line probe-set in a new addon (E1 clean). Implemented, compile-validated, **deployed apnex.24, verified**.
8. **fake-5090 catalog** — corrected my "patches != failure modes" error; added **F42** (leaked-bounded-wait-worker UAF; A7=defense, A6=gap); brought the index current with A6-A9.

## #282 hypothesis state (after Lane 1 + Lane 2)

- **H-OA1** (GSP lockdown-release wait) — **CONFIRMED as the D0-site locus** (n=4). Refined: it's the pre-RPC lockdown wait, not the GSP_INIT_DONE poll. The contained fire is **H-OA1b** (graceful busy-poll, no CTO).
- **H-OA2** (pre-`nv_open_device` / >5s-gap site) — still LIVE, untested (Lane 3); the PM-resume mechanism was partly falsified → "uncharacterized pre-open site."
- **H-OA6** (deadlock-as-primary / lock-holding) — now the **leading host-lock mechanism** (the busy-poll holds the GPU lock; no CTO).
- **H-OA3** (WPR2) → downstream sequela of H-OA1. **H-OA4/5/7** → contributors-only. **H-OA8** → falsified. **H-OA10** → falsified.
- **H-OA9** (no-single-cure / #979 territory) — the running default for the chip-side cause.
- **H-OA11** (BAR mis-mapping), **H-OA12** (PCI-reset differential) — untested (Lane 3 / the confounded reset ladder).

## What's GATED / the decision queue (the immediate next steps)

1. **Phase 3 — destructive validation of A9** (gated, reboot-loop): the first-open-on-a-BAD-chip test. The ONLY thing that upgrades the claim from "hole closed" to "wedge survived." It will either confirm survival or expose A6's leaked-worker behavior. Couples to (2).
2. **A6 leak→join hardening** (the deferred follow-up): A6 leaks its worker (no `flush_work` guard, unlike A7's SH-3). On a bad-chip first open the leaked worker holds the GPU lock (sink-fail-fast UNVERIFIED — `pmu.log` was empty) and is a UAF (F42). The principled fix = a **provably self-terminating, then joined** A6 worker. Queued in `docs/architecture-v5-deep-review-queued.md`; driven by Phase 3.
3. **Push** (unmade decision): everything is local. Force-push carve-out applies to the rebased a5–a8 (+ new a9) and the ~40 injector `main` commits. No NVIDIA PR (gated).
4. **Lane 3** (destructive, #285): H-OA2 site characterization, H-OA6 slack A/B, H-OA12 PCI-reset, cure-vs-contain (Rung 9). Reboot-loop, user present. The reset-ladder (#286) needs redesign first (gate cycle-2 on `tb_egpu_is_external`, or treat as destructive).
5. **Strategic patch review (v5)**: the A6 placement validation + the leak→join lifecycle + the F40-family consolidation. The user wants this AFTER all experiments. Inputs queued in `architecture-v5-deep-review-queued.md`.
6. **Deferred:** #979 follow-up (the open-arm characterization is report-grade once the site/offsets land); cmdline-staleness audit (`pci-cmdline-audit.md §E`, reboot-heavy); soak apnex.24.

## Key commits this session (injector `main`, all LOCAL)

Design/forensics: `9e52244` ledger, `88b1f9e` Lane 1, `63c353e` #979 draft, `a4f011c` oa-harness, `a3b3ee1` Lane 2, `50e326c` reset-wedge forensics, `01f7870` reset-ladder + cmdline audit. Fix: `bcdd58c` A8 v2.2, `745ba8f` spec, `dd643a0` plan, `190a7d0` A9, `9d7ee8f` apnex.24 version bump, `dada918` A9 deploy record. (fake-5090: `5c77807` A6-A9 index, `5474b62` F42.)

## Tasks
- **#282 OPEN-ARM** (in_progress) — Lane 1+2 done; Lane 3 + #979 are the remainder.
- **#287 A9 fix** (DONE), **#288 A8 v2.2 deploy** (DONE).
- #285 Lane 3 destructive (pending), #286 reset-ladder (pending, **unsafe — redesign first**).
- #283 harness (done), #284 Lane 2 (done).

## Method / discipline notes (scars from this session)
- **PMU sampling, not kprobe** for the closed RM on IBT (the standing method).
- **Verify load-bearing premises before acting.** I asserted "osinit.c is an un-editable blob" (FALSE — source-compiled) and "the reset-ladder is survivable" (FALSE — rebind disables A6, wedged the host). Both caught by adversarial agents / the wedge.
- **patches != failure modes** — the fake-5090 catalog documents diseases; patch-coverage facts go in the reverse-map, not as F-entries.
- **`git add -A` swept pre-existing WIP twice** — always stage explicit files.
- **Convention change:** addon patch headers are now canonical `# GENERATED` (regen); prose lives in the intent docs — do NOT redo the prose-preserve dance.
- **Don't claim "survivable" from an unverified assumption** — the spec/commits scope A9 to "hole closed," not "wedge fixed," pending the destructive test.

## Operational realities
- I run **on obpc**; a hard wedge kills the session → user reboots → resume from the fsync'd archives + this handover.
- Destructive work = a **human-in-the-loop reboot loop** (user present per fire).
- After any wedge/replug: **BAR1-via-sysfs FIRST**; no nvidia-smi/MMIO on a suspected-wedged/broken-BAR1 chip.

## Cross-refs
`open-arm-forensics-ledger.md` · `experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md` · `experiments/OA-reset-efficacy-ladder.md` (unsafe) · `upstream-979-open-arm-characterization-DRAFT.md` · `docs/superpowers/specs/2026-05-31-a9-egpu-probe-classify-design.md` · `docs/superpowers/plans/2026-05-31-a9-egpu-probe-classify.md` · `docs/patch-intents/A9-egpu-probe-classify.md` · `docs/architecture-v5-deep-review-queued.md` · `fake-5090/failure-modes/F42-*.md` + `F40-*.md`.
