# Session handover — 2026-06-04 — pre F44 live-validation (READ FIRST)

Written before a deliberately-risky **live F44 validation** that can hard-wedge
obpc (→ reboot, → this session dies). This doc is the resume point.

## TL;DR — current state
- **apnex.28 is LIVE + healthy + soaking.** It is the COMPLETE F44+F45 fix:
  **C6** (primitive) + **A11** (F45) + **A10-v2** (F44). Loaded
  `595.71.05-apnex.28`, BAR1 **32 GiB**, P8 ~19 W / 32 °C / fan 30%, persistence
  engaged, `tb_egpu_recover_surrenders=0`, `qwd_detections=0`,
  `NVreg_TbEgpuOpenGraceMs=50` live. Pod `1/1 Running`.
- **Nothing regressed.** The fixes are compile- + red-team-verified but NOT yet
  live-exercised against a real event. THAT is the next task.
- BAR1 was recovered earlier this boot via `tools/fix-bar1.sh` — the GPU was
  hot-added AFTER the NUC booted (256 MiB ReBAR), see Operational notes.

## ===== UPDATE 2026-06-04 (post-fastfail) — READ THIS =====
- **`fastfail` live validation PASSED 3/3.** A10-v2's completion-state discriminator
  correctly skips the sink when the worker returns within grace (config-vendor
  `0x10de` = bus alive, next-open rc=0, KFENCE clean, host alive). The narrow F44
  fix works. Run: `/var/log/mission-1-archaeology/ra10v2-fastfail-20260604T052224Z/`.
- **NEW INCIDENTAL FINDING (more important than the PASS):** the A6 open budget
  (200ms) + A10 grace (50ms) are SHORTER than a healthy full cold init (~1.3s), so a
  CUDA open of a cold/uninitialised GPU via the A6-bounded H-OA1 path would be
  mis-classified as a stuck lockdown and **dead-bused**. Latent in this deployment
  (masked by persistence+ordering → 0 production A6 timeouts ever); real for the
  upstream/no-persistence target and recovery races. Twin of the A7 budget bug
  (#279). Full writeup: `finding-2026-06-04-a6-open-budget-vs-healthy-cold-init.md`.
  Fix tracked: tasks **#299** (measure worst-case cold init) → **#300** (raise
  budget+grace, re-validate). A6+A10 intent docs updated with the correction.
- **`lockdown`-mode test is now DE-PRIORITISED:** on healthy hardware it would do a
  1.3s healthy init through H-OA1 → trip the lockdown arm → sink the chip → falsely
  report "contained". Genuine stuck-poll containment needs the fake-5090 F44 model
  (#290), OR run it only AFTER the budget fix (so a healthy init no longer trips it).
- **Recommended next step:** do #299 (non-destructive measurement) → #300 (tune +
  re-validate) BEFORE any lockdown test. The chip is back to healthy production
  (apnex.28, BAR1 32G, injector running).

## The deployed fix (what each patch does)
- **C6** `cond-acquire-rwlock-fix` (base, applies FIRST): corrects the stock
  inverted `os_cond_acquire_rwlock_{read,write}` in `os-interface.c` (rwsem
  trylock returns 1=acquired; the `!` was missing → on contention it returned
  NV_OK and released an unheld lock = rwsem corruption). Latent (no deployed
  COND consumer) but a prerequisite for any F44/F45 COND fix. Live-tested
  (down_write_trylock free=1/held=0).
- **A11** `f45-deadlock-breaker` (addon): F45 = cold-bringup RM-API-rwsem
  deadlock. A stochastic H16 PCIe transient at GSP boot fails RmInitAdapter; the
  single-threaded `nv_open_q` deferred-open worker then parks on a BLOCKING
  `rmapiLockAcquire` in `rm_get_adapter_status` → wedges the close + the pciehp
  flush → reboot-only. Fix = D1 (lock-free early-bail if already lost) + A11
  (is_external_gpu-gated COND_ACQUIRE in `rm_get_adapter_status`). nv.c + osapi.c.
- **A10-v2** `f40b-lockfree-sink` (addon): F44 = re-open lockdown wedge.
  Corrected mechanism (relaxed GSP init locking is ON by default → the worker
  RELEASES the API lock at `kernel_gsp.c:4785` across the poll, holding only the
  GPU GROUP lock; the wedge is the foreground in `flush_work` HOLDING
  `nvl->ldata_lock` while a 2nd ldata_lock contender (rmmod/close/AER) piles up —
  NOT an API-lock inversion). Fix = keep C1 (rm_cleanup COND_ACQUIRE, functional
  via C6) + a **completion-state discriminator** in the A6 OPEN timeout branch:
  a `NVreg_TbEgpuOpenGraceMs` (50ms) grace re-wait. Worker returned within grace
  → FAST-FAIL → skip BOTH sinks (chip stays `pci_channel_io_normal`,
  recoverable). Still stuck → LOCKDOWN → lock-free `os_pci_set_disconnected`
  marker + C5 → poll self-terminates → flush_work joins in ms. A7 unconditional.
  nv.c only (no deep-RM flag).

CORRECTED PREMISE (was repeated as fact, FALSIFIED 2026-06-04): the deployed A6
does NOT "self-heal the fast-fail" — it permanently dead-buses the chip on the
first fast-fail timeout (C5's own `os.c:1942` `os_pci_set_disconnected`; the
fast-fail path never sets `PDB_PROP_GPU_IS_LOST` so the `os.c:1935` idempotency
gate doesn't skip it). A10-v2 makes the fast-fail recoverable IN-DRIVER FOR THE
FIRST TIME.

## ===== THE NEXT TASK: live F44 fast-fail validation =====

**Goal:** prove A10-v2's discriminator on the FAST-FAIL arm — a WPR2-up re-open
no longer permanently sinks the chip (the deployed regression), and it
self-heals. The LOCKDOWN arm gets opportunistically exercised too (the real
wedge containment — high value, real risk).

**Method:** drive re-opens (OA harness, `tools/oa-harness/`) to make the A6
200ms bounded-open timeout fire. Classify each timeout from dmesg:
- FAST-FAIL → new line `…worker returned rc=… within +50ms grace — fast-fail,
  chip NOT sunk (recoverable)`.
- LOCKDOWN → `…worker still in GSP lockdown poll — declaring GPU lost …
  dead-bus marker + sink`.

**Assertions — PASSIVE ONLY (no nvidia-smi/MMIO on a maybe-sunk chip; lesson
`no-rpc-observability-on-broken-bar1`). Use `drgn` (installed 0.2.0 + kernel
BTF present):**
- FAST-FAIL must leave `pdev->error_state == pci_channel_io_normal` (NOT
  `pci_channel_io_perm_failure`); read passively via
  `/sys/bus/pci/devices/0000:04:00.0` config / drgn on the pci_dev.
- `PDB_PROP_GPU_IS_LOST` NOT set (drgn on the OBJGPU) on fast-fail.
- A subsequent open returns rc=0 (chip recoverable) — vs the deployed
  `PERMANENT_FAIL`/sink.
- LOCKDOWN (if hit): host STAYS ALIVE (no wedge), worker self-terminated,
  `flush_work` joined fast, dmesg shows the marker+sink line, then -EIO.
- drgn one-liners to stage: `drgn` → read `prog['nvidia']`… (load the non-stripped
  module symbols: the running `/lib/modules/$(uname -r)/extra/nvidia.ko`); read
  the pci_dev `error_state`, and the global RM API lock owner
  (`g_RmApiLock.pLock`) if a wedge happens (the F45 unnamed-holder question).

**Harness — runner READY (built+reviewed+verified 2026-06-04, UNCOMMITTED in the
working tree):** `tools/oa-harness/rung-a10v2-validate.sh` (+ `drgn-error-state.py`
best-effort helper) supersedes `rung6-a10-validate.sh` (A10-v1/apnex.26 era).
Two modes:
- `fastfail` (DEFAULT, deterministic, wedge-risk-BOUNDED): lowers
  `NVreg_TbEgpuOpenTimeoutMs`→1ms + raises grace→30000ms so a HEALTHY first-open
  trips A6 and the worker returns within grace → exercises the EXACT "chip NOT
  sunk" skip-sink path. Regression gate = a passive **config-space vendor probe**
  (`setpci 0x00.w`: `10de`=bus alive / `ffff`=sunk) — the drgn-FREE authoritative
  sink read (drgn is BTF-only here so `error_state` is corroboration). NOTE:
  next-open rc=0 is NOT load-bearing (the worker completed RmInitAdapter →
  `NV_FLAG_INITIALIZED` set → next open skips the bus), so the config-vendor probe
  is the real discriminator. A lockdown-arm fire in fastfail mode = a HARD ANOMALY
  (halt), not a contained pass.
- `lockdown` (RISKY, explicit): rung6 substrate (no-persist clean LAST-CLOSE →
  WPR2→0 → bootstrap poll). Asserts host ALIVE + "GSP lockdown poll" + bounded dt
  + sink(expected) + fix-bar1 recovery. CAN HARD-WEDGE; kdump can't capture.
Hardened via a 4-lens adversarial review (workflow `ws2kgirub`, 13 findings, ALL
applied) + an independent verify pass (13/13 landed, 0 regressions). Two were
must-fix: (1) a **Ctrl-C param-strand** that stranded `timeout=1ms` and would have
made every production open `-EIO` — fixed with traps-before-mutation + INT/TERM +
backgrounded `& wait` fire + a `RESTORE-PARAMS.txt` breadcrumb (empirically
verified SIGINT→restore); (2) the non-discriminating next-open gate above. Also:
KFENCE detector now `BUG: (KFENCE|KASAN):` (all classes), dmesg anchor-loss →
INCONCLUSIVE (no stale fabrication), `nvidia-smi -pm 0` removed from the unload
path, N≥3 floor + `PASS≥N` verdict. Static: `bash -n` + `shellcheck` clean.
Invoke: `sudo tools/oa-harness/rung-a10v2-validate.sh fastfail 3` (safe-first),
then `... lockdown 3` only with operator at console. The re-open op is
`exec 3</dev/nvidia0` (triggers RmInitAdapter via the A6 worker).

**RISK + STAGING (do ALL before firing):**
1. Operator (you) at the console — a wedge = human reboot loop.
2. Drain real GPU consumers first (none currently — no vLLM/device-plugin; only
   persistence). Disable persistence + drain the injector DS so the harness owns
   the GPU.
3. drgn ready (NOT kdump — PROVEN it can't capture: the capture kernel hangs
   re-probing the wedged eGPU; `wedge-2026-06-02-kdump-capture-failure-forensics.md`).
   Optional: netconsole/serial for sysrq-t over the wedge.
4. The fast-fail arm is SAFE (worst case it sinks wrongly = recoverable, not a
   wedge). The LOCKDOWN arm is the risk: re-opens stochastically hit WPR2-clear
   → if A10-v2's lockdown arm is WRONG, the host hard-wedges (the exact failure
   we fixed). That is the bet.

## If the live test WEDGES — recovery (no clean kdump)
Order, gentlest first (all PROVEN this campaign):
1. Passive first: BAR1 via sysfs, `lspci`, `dmesg` — NO nvidia-smi/MMIO.
2. drgn-read `g_RmApiLock` owner + the wedged task stacks (sysrq-t to dmesg) to
   confirm the cycle BEFORE recovering.
3. The wedge is a kernel rwsem/ldata_lock deadlock with an unkillable kthread —
   FLR, TB unauthorize/reauthorize, and cable replug do NOT break it (all tried
   2026-06-02; `wedge-2026-06-02-coldboot-apilock-deadlock.md`). The only
   recovery is **reboot**. kdump-as-recovery FAILED (capture kernel hangs) — a
   plain reboot is cleaner. Preserve the running nvidia.ko symbols first if you
   want a (likely-failing) vmcore.
4. Post-reboot: the GPU may come up broken-BAR1 if hot-added — `fix-bar1.sh`.
   Un-drain the injector DS; it auto-loads apnex.28 (the #298 entrypoint fix
   handles version-mismatch reload).

## Session's shipped work (all pushed)
- Fork `apnex/open-gpu-kernel-modules` branches: `c6-cond-acquire-rwlock-fix`
  (1f196b61), `a11-f45-deadlock-breaker` (2532aac9), `a10-f40b-lockfree-sink`
  (e51a664e, A10-v2, amended over the abandoned A10-v1 d2a4e514),
  `a5-version-and-toggles` (bumped → apnex.28).
- Injector branch `c6-cond-acquire-rwlock-fix` (pushed): C6+A11+A10-v2 carved
  into `patches/`, manifest rows (C6 first base; A11+A10 last addons), intent
  docs (C6/A11/A10), entrypoint #298 fix, forensics + workflow JSONs, daemonset
  → apnex.28. NOT yet merged to injector main.
- Version cascade: apnex.25 (pre-session) → apnex.27 (C6+A11) → **apnex.28**
  (+A10-v2). apnex.26 was the aborted A10-v1 (skipped).

## Operational notes (recurring gotchas)
- **Power-on order:** cold-plug the GPU BEFORE/WITH the NUC. GPU-on-AFTER-boot =
  TB hot-add = ReBAR resets to 256 MiB = broken-BAR1 every time → `fix-bar1.sh`
  (ReBAR write + pciehp slot-cycle). Same for cable replug / chassis power-cycle.
- **Firmware symlink (task #294):** `nv.c:27` builds the GSP path from the FULL
  version string; a host-side .ko at a NEW apnex.NN needs
  `ln -sfn 595.71.05 /lib/firmware/nvidia/595.71.05-apnex.NN` (the container
  entrypoint does this for its built version).
- **#298 entrypoint fix (deployed in apnex.28):** version-mismatch deploys now
  AUTO-RELOAD (detect loaded != target → rmmod deps-first → load target). No
  manual drain dance for version bumps. Validated live 2026-06-04.
- Subagents on opus. No Claude attribution in commits. Fork push OK; NVIDIA-repo
  PR gated on tested fix. drgn passive-only on a suspect chip.

## Open / pending (after the live test)
- **F44 LOCKDOWN arm** — source-derived only; safe on-demand validation needs
  the **fake-5090 F44 model (#290)** (a synthetic lockdown-poll substrate, no
  hardware wedge). Multi-day build, deferred.
- **F45 deferred-open** — needs the cold-init transient + drgn-confirm the rwsem
  holder transient-vs-permanent (#297 residual; MEDIUM confidence until then).
- **14-day soak** gate (status.sh green; surrenders/qwd 0; no host hard-lock).
- **Doc cleanup:** F45 fake-5090 entry written but UNCOMMITTED (user's catalog
  review — `/root/fake-5090/failure-modes/F45-coldinit-apilock-deadlock.md` +
  README rows); a "self-heal" correction banner on
  `wedge-2026-06-02-lockdown-reopen-forensics.md` (A10-v2 intent already carries
  the authoritative correction).
- **Upstream:** C6 is a genuine NVIDIA bug — upstream-report candidate AFTER the
  soak, on explicit go-ahead (no-premature-upstream policy).

## Key files
- Design records: `f45-deadlock-fix-design-workflow-2026-06-02.json`,
  `f44-a10v2-rederive-workflow-2026-06-02.json`,
  `a10-v2-surgical-design-workflow-2026-06-02.json` (all in this mission dir).
- RCAs: `wedge-2026-06-02-coldboot-apilock-deadlock.md` (F45),
  `wedge-2026-06-02-lockdown-reopen-forensics.md` (F44),
  `wedge-2026-06-02-kdump-capture-failure-forensics.md`.
- Intent docs: `docs/patch-intents/{C6,A11,A10}-*.md`.
- Catalog: `/root/fake-5090/failure-modes/{F44,F45}-*.md` (F45 uncommitted).
