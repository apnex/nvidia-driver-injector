# Session handover — 2026-06-04 — A12 implementation (READ FIRST)

> **⚡ UPDATE (later same session): A12 IS NOW IMPLEMENTED + COMPILED + PUSHED.** The "no code yet"
> note below is superseded. Done this session: fork branch `a12-init-funnel` (on a10 tip) carries the
> `nv_bootstrap_bounded` funnel at `nv_start_device` (subsumes A6, bounds all 5 cold-init limbs) +
> the system-resume wrap; version bumped → **apnex.30** (a5). Full composition (19 patches, A12 after
> A10) **compiles** against kernel 7.0.9-204.fc44. Committed + pushed: injector `main` `667fb89`
> (`patches/addon/A12-init-funnel.patch` + intent `docs/patch-intents/A12-init-funnel.md` + manifest);
> fork `a12-init-funnel` + `a5` (apnex.30). Verified: verbatim body-move (range-diff clean), composed
> budget preserved (3000/2000), A3 grafts worker-safe, no `nvlfp` in the worker, flush kept.
> **REMAINING:** (1) **Task 10 — live fastfail validation + apnex.30 cutover, DEFERRED to post-soak,
> operator-present** (rung-a10v2 is disruptive); (2) **runtime-PM `rm_transition_dynamic_power`
> fast-follow** (the 2nd Family-2 site, deliberately not bounded yet — lower severity, no ldata_lock);
> (3) catalog #301 commit decision. Plan: `docs/superpowers/plans/2026-06-04-a12-init-funnel.md`.

Next session: **implement A12** (the complete GSP-bootstrap funnel). This session designed it
(4-pass adversarial), shipped the cold-init budget fix as apnex.29, and wrote the docs. No code for
A12 yet. **Nothing upstream until the user's deliberate gate.**

## TL;DR state at session end
- **apnex.29 is LIVE + soaking.** Host module `595.71.05-apnex.29`, `OpenTimeoutMs=3000` /
  `OpenGraceMs=2000`, BAR1 32 GiB, persistence engaged, injector 1/1. This session's shipped fix:
  the A6/A10 **cold-init budget** (200→3000 / 50→2000) — closes the "a healthy cold open gets
  dead-bused" bug (finding-2026-06-04). Validated live (fastfail 13/13 + budget-verify n=3 +
  cold-silicon n=1) and on the deployed build (n=3).
- **All shipped work committed + pushed + merged to main.** Fork `a5/a6/a10` in-sync with origin;
  injector `c6-cond-acquire-rwlock-fix` (`5ab5294` bundle + `59535ec` runner fix) **merged to main**
  (`481217c`, pushed). main now carries the full apnex.29 composition.
- **The current production chip is the userspace-recovered (EQ-diverged) one** from a physical
  chassis power-cycle this session — persistence mitigates the close-path fragility; a future
  reboot (cold-plug) restores a pristine chip. Not urgent.

## ===== THE NEXT TASK: implement A12 =====

**Read the design-of-record first:** `design/A12-init-funnel-design-of-record-2026-06-04.md`.
It is the full spec. Summary:

**Goal:** extend A6's *proven* bounded-wait + A10-v2 discriminator from the single H-OA1 site to a
**complete funnel** over the **provably-closed** GSP-bootstrap entry set, so a stuck init can never
wedge the host from ANY entry. Closes the H-OA2 gap (#282) — the last clearly-ours in-driver wedge.

**The entry set is closed (proven):** `kgspBootstrap` has exactly 2 RM call sites → 2 families:
- **Family 1 — cold init:** funnel at `nv_start_device` (nv.c:1380 → `rm_init_adapter` nv.c:1527);
  5 limbs (H-OA1 foreground 1947; deferred 1792; `nvidia_dev_get` 5416; `nvidia_dev_get_uuid` 5530;
  probe nv-pci.c:2239). One cut covers all 5 + subsumes A6.
- **Family 2 — power resume:** wrap `rm_power_management(RESUME)` (nv.c:~4550) +
  `rm_transition_dynamic_power` (runtime-PM/RTD3/GC6). 2 site-wraps.

**Mechanism:** `nv_bootstrap_bounded(nv, sp, fn)` reusing A6's shape — dedicated **global
`system_long_wq`** worker (NOT the per-device `open_q`), `wait_for_completion_timeout` + A10-v2 grace
+ C5 dead-bus marker + **`flush_work` join (KEEP — load-bearing)**. In-kernel limbs stay
synchronous-but-bounded (no `ldata_lock` drop). `worker-owned-sp` is an OPTIONAL simplification
(VERIFY-confirmed sound) but not required once the flush is kept.

**MUST honor these red-team constraints (the prior designs broke on them — see the design-of-record
§6.2 + the 4 workflow transcripts):**
1. NO per-device `open_q` for the foreground/in-kernel bound → AB-BA with `ldata_lock`/suspend. Use
   `system_long_wq`.
2. SOUND JOIN across `nv_pci_remove`/`nv_linux_stop_open_q`: arm the dead-bus marker FIRST (lock-free
   `os_pci_set_disconnected`), THEN `cancel_work_sync`/`flush_work` on a per-`nvl`-tracked slot,
   BEFORE `down(&ldata_lock)` (nv-pci.c:2426). `nv_kthread_q_flush` no-ops after stop — do not use it
   as the join.
3. Cover **both** RM bootstrap families (the funnel + the 2 resume wraps) — "bound `rm_init_adapter`"
   ≠ "bound GSP bootstrap".
4. Don't make the bounded worker an A3-recovery AB-BA; keep `nv_system_pm_lock` ordering.
5. The `nv_start_device` body move into `__nv_start_device_locked` must keep the `failed:`/
   `failed_release_irq:` goto labels intact — verbatim move + range-diff.

**Accept + carry the residual:** instant termination of a genuinely-stuck non-lockdown stall is
closed-RM-impossible (① dead-bus covers only the lockdown poll; ② resume holds the RM API lock;
③ timeout ≠ proof of loss → must wait). The **host wedge is fully closed**; the residual is a bounded
recovery *latency* (≤ RM gpuTimeout), **upstream-RM to make instant** — log it in the upstream-plan,
gated.

**Validate:** compile (full composition `make modules`) → `rung-a10v2` fastfail suite n≥3 at
production defaults, confirming all 5 cold-init limbs + a resume path bound (host-alive `-EIO`, not a
wedge); passive-only on a suspect chip → apnex.NN (bump a5/a6/a10→.30 or a new A12 row) → soak.

## Catalog reconciliation (#301) — written, UNCOMMITTED (user review-gated)
- NEW `fake-5090/failure-modes/F46-hoa2-unbounded-init-wedge.md` (the H-OA2 entry).
- UPDATED `F40-reinit-gsp-lockdown-wedge.md` (H-OA1/H-OA2 split banner + apnex.29 budget + verdict).
- UPDATED `fake-5090/failure-modes/README.md` (F46 index row).
- These join the F15–F46 uncommitted backlog the user reviews before bundle-committing — **do NOT
  silently commit the fake-5090 catalog.**

## Standing constraints (verbatim — persist)
- **Upstream PRs HELD** until the user's deliberate gate — even though C6/C3/C5/E1 are tested +
  deployed + soaking. "Tested+deployed" does NOT unlock the gate. Fork pushes + injector-main merges
  are fine. (memory: feedback_no_premature_upstream_filing, reinforced 2026-06-04.)
- **No Claude attribution** in any commit/PR/branch.
- **Subagents on opus.** Run substantive work via the Workflow tool (ultracode).
- **Safety on a suspect chip:** BAR1-via-sysfs first; passive-read only; NO nvidia-smi/MMIO on a
  suspected-wedged/broken-BAR1 chip; recovery = reboot (kdump can't capture the eGPU wedge — drgn
  passive). Physical power-cycle = cold silicon but needs TB re-auth + fix-bar1 (no reboot). Quiesce
  the driver (persistence off → drain injector → rmmod → `drivers_autoprobe=0`) BEFORE any
  unplug/power-cycle to avoid the surprise-removal wedge.
- I run ON obpc — a hard wedge kills the session; destructive work = human-in-the-loop (user present).

## Where everything is
- Design-of-record: `design/A12-init-funnel-design-of-record-2026-06-04.md`.
- The 4 design workflows (this session's transcripts): per-site/funnel/eager/async; perfection;
  constraint-driven; final worker-owned-sp+enumeration. Verdict: instant-perfection impossible,
  proven; wedge perfectly closeable; entry set provably closed.
- Cold-init finding: `finding-2026-06-04-a6-open-budget-vs-healthy-cold-init.md`.
- Validation runner: `tools/oa-harness/rung-a10v2-validate.sh` (version gate accepts apnex.28+).
- Tasks: #282 (open-arm, in_progress), #301 (catalog, pending), #290 (fake-5090 F44/H-OA2 substrate),
  #297 (F45 drgn residual). #299/#300 (cold-init budget) DONE.

## Open / pending
- **A12 implementation** (this handover's task).
- **14-day soak** on apnex.29 (status.sh green; surrenders/qwd 0).
- F44 lockdown-arm + A12 in-kernel-limb validation need the fake-5090 F44 substrate (#290).
- The catalog backlog commit decision (user-driven).
- Upstream C6/C3/C5/E1 + the A12 upstream-RM residual — all behind the deliberate upstream gate.
