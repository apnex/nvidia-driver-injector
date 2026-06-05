# #292 fix — DESIGN-OF-RECORD: in-flight-AER early-free (A13) [2026-06-05]

**Bug:** host hard-wedge on a persistence-OFF re-open of a #979-EQ-diverged TB-tunneled 5090.
**Captured:** 2026-06-05 `captures/netcon2-…-292-pathB-wedge.log`, 3/3 adversarially verified.
**Root cause (source-true):** see `finding-2026-06-05-recovery-bringup-wedge-forensics.md` §CAPTURED v3 +
§Reconciliation. The foreground re-open holds `nvl->ldata_lock` across an unbounded `flush_work` of a
worker stuck in `kgspBootstrap_GH100 → gpuTimeoutCondWait`; an **AER CmpltTO at ~1.02 s** (inside the
in-flight window, **before** the 3000 ms A12 timeout) makes `nv_pci_error_detected` the second `ldata_lock`
contender (F44) → wedge at ~1.07 s, before the A10-v2 timeout+grace discriminator can run.

**Provenance:** design via workflow `lockdown-reopen-wedge-fix-design-v2` (11 agents: 4 ground → 3 design →
3 adversarial review → synthesis). Then **operator review caught a correctness defect the workflow missed**
(the channel-state gate — see §2). This doc is the corrected build spec.

---

## 1. Chosen approach
**Ship (A') as the primary structural fix + (C') as phase-2 defense-in-depth. Reject (B').**

- **(A') — early lock-free dead-bus marker in `nv_pci_error_detected`, gated on a new per-`nvl` in-flight
  flag.** When an uncorrectable AER fires while a chip-touching bootstrap worker is in-flight on this nv,
  set `os_pci_set_disconnected()` immediately. The stuck worker's GSP poll cond
  (`_kgspLockdownReleasedOrFmcError → osIsGpuBusDead → 0xFFFFFFFF`) self-terminates in **one iteration**,
  the worker returns, the foreground's `wait_for_completion_timeout` takes the **BUDGET arm**, releases
  `ldata_lock` — **before** the AER thread can become the F44 second contender. Reuses the *exact*
  marker→one-iteration-termination chain the deployed A10-v2 lockdown arm already relies on (nv.c:1993),
  just triggered earlier on the correct signal. Verified end-to-end in source.
- **(C') — funnel fail-fast** (phase-2): return `-EIO` from `nv_bootstrap_bounded` before `queue_work` when
  `external ∧ last-close-WPR2-cleared ∧ diverged-sticky`. Probabilistic (the diverged bit is invisible to
  the driver in the live case — it relies on a userspace `fix-bar1` sysfs assertion that can land one open
  late), so it **must ship with (A'), never instead**. Deferred to phase-2.
- **(B') — drop `ldata_lock` across the wait — REJECTED.** Decisive source fact `nv-pci.c:2481`:
  `if ((atomic64_read(&nvl->usage_count) != 0) && !(nv->is_external_gpu))` — eGPU remove **skips** the
  usage_count drain-wait, so B''s pre-pin is ineffective on the #292 device class → reopens the F42
  teardown-vs-init UAF. Least-sovereign (L1 restructure). Hold only as a fallback (it won't be needed).

---

## 2. ⚠ CORRECTION over the workflow's design — the gate must NOT test channel state
The workflow's (A') gated the marker on `state != pci_channel_io_normal` and called the trigger a
"**fatal** AER." **That is wrong and would miss the captured wedge.** The captured AER is **Uncorrectable
*Non-Fatal*** and `error_detected` fired with **`channel state=1` = `pci_channel_io_normal`**
(`netcon2.log:882-886`). `state != pci_channel_io_normal` ⇒ false on the real case ⇒ the fix would not
fire and the host would still wedge.

**Corrected gate: `bootstrap_in_flight` alone (no channel-state test).** Safe because
`nv_pci_error_detected` is only invoked for **uncorrectable** errors (correctable → the separate
`cor_error_detected`); an uncorrectable AER during an in-flight external-GPU bootstrap reliably means a
doomed init for **any** severity → setting the dead-bus marker is correct. R2/R3 non-regression is
unchanged: the WPR2-fast-fail path responds to MMIO (no CmpltTO, no uncorrectable AER) so it never enters
`error_detected` → marker never set → chip stays recoverable.

---

## 3. Patch plan — new tip-of-stack addon `A13-292-inflight-aer-earlyfree`
Implemented as a **new addon patch at the tip** (after A12), not folded into A3/A12: the fork is a
branch-stack (mid-stack edits need a rebase), and nv.c/nv-pci.c/nv-linux.h are shared base files (not
dedicated addon TUs), so a self-contained tip patch is geometry-clean. All three edits + the field live in
A13. Add `A13-292-inflight-aer-earlyfree  addon  -  fork:a13-292-inflight-aer-earlyfree` to `patches/manifest`
after A12.

**Edit 1 — field. `kernel-open/common/inc/nv-linux.h`, in `nv_linux_state_t` (after the A3 `recover` field):**
```c
    /* #292 (A13) in-flight-AER early-free gate. Lock-free atomic. Set by
     * nv_bootstrap_bounded(A12) while a chip-touching bootstrap worker is
     * QUEUED; read by nv_pci_error_detected to free a stuck worker via the
     * lock-free os_pci_set_disconnected marker. On nvl (NOT ->recover) so it
     * works with NVreg_TbEgpuRecoverEnable=0. */
    atomic_t bootstrap_in_flight;
```
Zero-init by `NV_KZALLOC` of nvl; optional explicit `atomic_set(...,0)` near `NV_INIT_MUTEX(&nvl->ldata_lock)`.

**Edit 2 — set/clear flag in `nv_bootstrap_bounded` (`kernel-open/nvidia/nv.c`):**
- `atomic_set(&nvl->bootstrap_in_flight, 1);` immediately **before** `queue_work` (nv.c:1921).
- Clear `atomic_set(..., 0);` on **both** arms the instant the worker is provably MMIO-done:
  immediately after `rc = w->rc;` in the **BUDGET arm** (nv.c:1928) **and** immediately after
  `flush_work(&w->work);` in the **TIMEOUT arm** (nv.c:2028). No common-tail clear (closes the
  budget-success false-positive window — review must-fix). Covers system-resume too (rides the funnel via
  `__nv_pm_resume_locked`). `nv_dynpower_bounded` holds no `ldata_lock` → out of scope for v1.

**Edit 3 — early marker in `nv_pci_error_detected` (`kernel-open/nvidia/nv-pci.c`), after nvl resolution
(~2957) and before `tb_egpu_recover_pre_schedule_gates` (~2959):**
```c
    /* #292 (A13) in-flight-AER early-free: an uncorrectable AER while a
     * bootstrap worker is queued on this nv means the chip fell off the bus
     * mid-init. Set the LOCK-FREE dead-bus marker NOW so the stuck GSP poll
     * self-terminates (osIsGpuBusDead) and the ldata_lock-holding foreground
     * is released before this AER thread becomes the F44 second contender.
     * Gate = bootstrap_in_flight ALONE (do NOT test channel state: the real
     * #292 AER is Uncorrectable NON-fatal / pci_channel_io_normal). A normal
     * recoverable AER with no in-flight bootstrap never sets the marker and
     * still reaches GATE_OK -> NEED_RESET. Lockless: pci_get_drvdata +
     * os_pci_set_disconnected (WRITE_ONCE) + atomic_read — never blocks on
     * ldata_lock. */
    if (nvl != NULL && atomic_read(&nvl->bootstrap_in_flight))
    {
        nv_printf(NV_DBG_ERRORS,
            "tb_egpu recover: AER during in-flight bootstrap -> early dead-bus "
            "marker to free stuck open worker (#292)\n");
        os_pci_set_disconnected(NV_STATE_PTR(nvl)->handle);
    }
```
Falls through into the existing switch. Intended consequence: `pre_schedule_gates` now sees
`os_pci_is_disconnected==NV_TRUE` → GATE_SURRENDER → DISCONNECT (correct for a diverged chip; R4 = resets
contain-only, none cure).

---

## 4. Regression safety (must-not-regress checklist)
- **WPR2-fast-fail not sunk (R2/R3/R4):** fast-fail never enters `error_detected` (responds to MMIO, no
  uncorrectable AER) ⇒ marker never set; flag cleared at worker-return. A10-v2 grace arm byte-identical.
- **Legit recover NEED_RESET:** no in-flight worker ⇒ block skipped ⇒ GATE_OK→NEED_RESET intact.
- **`error_detected` never blocks on `ldata_lock`:** marker write is lockless (verified) and sits before
  the gate/switch.
- **A10-v2 discriminator preserved:** early-freed worker returns ⇒ foreground takes the **BUDGET arm**
  (reads `w->rc`, no-op `flush_work` join); grace/lockdown text untouched.
- **flush_work JOIN GUARD on every path (R0/R3):** kept; only made fast. No detached worker.
- **No new PCIe reset (R4):** marker → DISCONNECT, no reset.
- **non-eGPU / NVreg gates:** flag only set on the is_external funnel path; `NVreg_TbEgpuRecoverEnable=0`
  still works (flag on nvl, not `->recover`); `st==NULL` deref stays unreachable.
- **nvl lifetime (F42):** foreground holds `ldata_lock` continuously across the window; nvl freed only
  under `ldata_lock` ⇒ the lockless flag read is always on a live nvl.

**Harness asserts that must still pass:** R2 (`scheduled==completed+timed_out`, cycle-2 bounded `-EIO`,
0 KFENCE UAF, re-recover 32768 MiB), R3 (post-`-EIO` rmmod bounded <15 s, 0 UAF), R4 (per-fire
`is_external==1`, BAR1≥32768, resets contain-only). `tools/oa-harness/rung{2,3,4}.sh`.

---

## 5. Validation strategy (no live wedge required for confidence; ≤1 gated live confirm)
- **Tier 1 — static/source proof (done):** A13 triggers the already-validated A10-v2 marker chain earlier
  on an existing signal; fast-fail unreachable; recoverable-AER path unchanged; nvl-lifetime safe.
- **Tier 1.5 — compile-validation (this cycle, mandatory per project rule):** `make modules` against
  `/usr/src/kernels/7.0.9-204.fc44`. Apply ≠ validated.
- **Tier 2 — fake-5090 #290 fault-injection (build it):** GSP-lockdown busy-poll stub + mock
  `os_pci_is_disconnected` + synthetic `error_detected` with `bootstrap_in_flight` asserted. Positive:
  marker → stub poll exits in one iter → foreground completes. Negative: `bootstrap_in_flight==0` →
  GATE_OK→NEED_RESET. Re-run rung2/rung3 to confirm fast-fail byte-identical.
- **Tier 3 — ≤1 gated live confirm:** diverged 32 G chip, persistence-OFF LAST-CLOSE → re-open;
  **recover-disabled control first** (`NVreg_TbEgpuRecoverEnable=0` — A13 must still fire); kernel-side
  `/proc/sysrq-trigger` capture (keyboard SysRq dead) + `softlockup_panic=1`/`hardlockup_panic=1`/kdump.
  Accept: worker no longer parked in `gpuTimeoutCondWait`; host survives; foreground `-EIO`; subsequent
  rmmod/re-open bounded; 0 new UAF; cold-plug re-recovers 32768 MiB CUDA-functional (verify via nvbandwidth
  H2D >1.0 GB/s — do NOT trust a bare "recovered" string; the #304 BAR1=0 false-success can mask off-bus).
  **User at console; reboot-likely.**

---

## 6. Risks (ranked)
1. **(C') divergence invisible to driver (HIGH, defines why C' is phase-2)** — userspace assertion can land
   one open late; (A') is the structural backstop. Open: a passive probe-time PCIe-LnkSta/Eq-status
   divergence proxy (no chip-touch) — needs a hardware-signature survey before relying on it.
2. **(A') budget-success false-positive window (MEDIUM)** — resolved by the both-arms flag-clear; verify in
   the fake-5090 negative test.
3. **Dynpower/Family-2 (MEDIUM)** — open + system-resume covered (ride the funnel); `nv_dynpower_bounded`
   holds no `ldata_lock` → follow-on only.
4. **fake-5090 cannot model real AER timing (LOW)** — irrelevant; A13 is signal-driven not timing-driven;
   the 06-05 capture already proved the diverged chip raises the AER.

**Bottom line:** ship **A13/(A')** with the corrected `bootstrap_in_flight`-only gate + both-arms flag-clear;
compile-validate now; fake-5090 + one gated live confirm before deploy (apnex.31). **(C')** = phase-2.
**(B')** rejected.
