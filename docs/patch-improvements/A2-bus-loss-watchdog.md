---
id: A2-bus-loss-watchdog
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: cd1fe0888e7b2d135b0bb27214e32d31c9b382c3
v2-tip-sha: cd1fe0888e7b2d135b0bb27214e32d31c9b382c3
status: accepted
intent-updates: []
---

# A2-bus-loss-watchdog — improvement triage

## Triangulation sources

- **Vanilla NVIDIA 595.71.05** — A2 introduces two wholly-new files
  (`kernel-open/nvidia/nv-tb-egpu-qwd.c` and `.h`) and three additive
  hunks: one field in `kernel-open/common/inc/nv-linux.h` (forward-declared
  opaque `struct tb_egpu_qwd *qwd;` on `nv_linux_state_s`), one `#include`
  + one init call + one stop call in `kernel-open/nvidia/nv-pci.c`, and one
  source-list line in `kernel-open/nvidia/nvidia-sources.Kbuild`. No
  vanilla translation-unit logic is modified. Vanilla triangulation pivots
  to the kernel kthread + sysfs API surface:
  - `<linux/kthread.h>`: `kthread_run`, `kthread_should_stop`,
    `kthread_stop`. `kthread_stop` blocks until the thread observes
    `kthread_should_stop()` and returns.
  - `<linux/delay.h>`: `msleep_interruptible(unsigned int msecs)` —
    interruptible by `kthread_stop`, returns the unslept remainder.
  - `<linux/atomic.h>`: `atomic_inc`, `atomic_read`, `atomic_set` on
    `atomic_t` (signed 32-bit). Wrap at `INT_MAX` is implementation-defined
    in C but defined as wrap-around in the kernel's `atomic_t`
    contract (per `Documentation/atomic_t.txt`).
  - `<linux/sysfs.h>` + `<linux/device.h>`: `DEVICE_ATTR`,
    `sysfs_create_group`, `sysfs_remove_group`. Attribute-group removal
    blocks until all in-flight `show` callbacks return — load-bearing
    for A2's teardown ordering.
- **v2 intent:** `docs/patch-intents/A2-bus-loss-watchdog.md` (status
  `reviewed`).
- **v2 review:** `docs/patch-reviews/A2-bus-loss-watchdog.md` (status
  `accepted`; documents 4 deltas — D1 should-fix `tb_egpu_dump_aer_trigger_event`
  hoist deferred to A3, D2 nice-to-have detection-counter wrap-guard
  deferred, D3 out-of-scope task-binding drift rejected, D4 no must-fix
  sentinel).
- **aorus-5090 ancestor patches** (verified per M1+M2 against
  `0014`/`0015` filenames + symbol grep on `tb_egpu_qwatchdog|qwd|
  PMC_BOOT_0|NVreg_TbEgpuWatchdog`):
  - `patches/0014-Lever-Q-watchdog-kthread.patch` (lines 1-352) —
    the canonical ancestor: introduced the `tb_egpu_qwatchdog_thread`
    kthread (lines 147-235), `tb_egpu_qwatchdog_init`/`_stop`
    lifecycle (lines 237-302), module-parameter surface
    `NVreg_TbEgpuWatchdogEnable` + `NVreg_TbEgpuWatchdogIntervalMs`
    (lines 125-136), the `[10, 60000]` clamp (lines 138-139), the
    `0xFFFFFFFF` dead-bus constant (line 145), the per-device kthread
    name `aorus-qwd-<bus><slot>` (line 264), and the once-per-episode
    latch via `detected_logged` (lines 206-225). A2's v1 source is a
    near-verbatim de-brand of this patch with the rename
    `aorus-qwd-*` → `tb-egpu-qwd-*`, `qwatchdog` → `qwd`, and the
    addition of S3 detection state (`last_detection_jiffies`,
    `last_pmc_boot_0`, `last_aer`).
  - `patches/0015-Lever-Q-watchdog-sysfs-counters.patch` (lines 1-81)
    — added the original sysfs counter surface (only 2 attributes:
    `tb_egpu_qwatchdog_cycles`, `tb_egpu_qwatchdog_detections`,
    via two `DEVICE_ATTR`s). A2's v1 has expanded this to 5
    attributes (added `_last_detection_jiffies`, `_last_pmc_boot_0`,
    `_last_aer_summary`) and replaced the per-attribute
    `device_create_file`/`device_remove_file` calls with an
    `attribute_group` registered via `sysfs_create_group` /
    `sysfs_remove_group` (correct ordering vs. `kthread_stop`).
- **aorus-5090 docs consulted (M1+M2 verification):**
  - `docs/lever-Q-design.md` lines 169-340 — the canonical Q-lever
    design rationale. **Highly relevant.** Lines 169-340 cover
    Q-passive (the ioctl-path wrapper, owned by C5/A3 in the new
    geometry — NOT A2's surface). Lines 285-321 cover Q-active
    (post-read PMC_BOOT_0 verification, also NOT A2). Lines 335-345
    cover **Q-watchdog**, which is the line of descent for A2 —
    documented as "future, optional" with the deferred status
    "Not needed if Q-active works as expected" at line 344. The
    2026-05-05 Mode B silent freeze (referenced from the patch
    file-comment) elevated the deferred Q-watchdog to v1 status.
    Lines 99-127 (hardware constraint discussion: single MMIO read
    is uninterruptible at the C level; PCIe completion timeout
    50us-50ms; TB-tunnel behaviour unknown) are foundational for
    why the active heartbeat is needed at all.
  - `docs/reliability-hypothesis-ledger.md` lines 29-39 — **H1**:
    "Q-watchdog kthread MMIO probe converts Mode A → Mode B".
    **Highly relevant — load-bearing for A2's design.** This is
    the Heisenbug A/B hypothesis that justifies the runtime
    kill-switch (`NVreg_TbEgpuQwdEnable`) + the per-device cycle
    counter. H1 status is "OPEN" (n=1 each side — within stochastic
    noise per H3). The hypothesis directly informs A2's surface:
    the kill switch must be runtime-toggleable (not build-time)
    so the experiment can flip within a session. Lines 134-137
    (H9a fallout context) note the watchdog provides
    AER-independent Mode B detection, which is the v1 mechanism.
  - `docs/lever-R-design.md` — checked per binding. Lines 196,
    226, 471 mention "Q-watchdog daemon"/"composes with B3
    watchdog daemon" — but Lever R is the FLR-orchestration
    layer (A3's predecessor), and the kthread-lifecycle
    discussion (lines 317, 335, 370, 377, 457-461) is about
    FLR-wedge watchdogs, NOT the bus-loss watchdog A2
    implements. **Drop per M1** — Lever R covers different
    territory (recovery dispatch + FLR wrapping), not the
    Q-watchdog kthread A2 carries.
  - `docs/recovery.md` — checked per binding. Searched for
    `watchdog|kthread|qwd|Q-watch` and found zero matches. The
    recovery operator-runbook does not document the
    bus-loss-detection layer. **Drop per M1** — not relevant
    to A2's detection-half scope.
- **Community-signal entries** — A2 is one of two patches with
  tagged community signal (per `_community-signal.md` summary
  line 132 — the other is A3):
  - **#1132** (lines 68-72) — *RTX 5070: `__nv_drm_gem_nvkms_map`
    BAR1→BAR3 mapping … krcWatchdog GPU lock*. Different
    failure mechanism (BAR1/BAR3 boundary-spanning DMA mapping
    on rBAR-disabled host) but **same Mode-B silent-freeze
    symptom space** that A2's Q-watchdog catches. Per M5
    framing: this is **code-path adjacency, not exact match**.
    krcWatchdog is the in-driver watchdog NVIDIA already
    ships at the RM layer; A2's Q-watchdog runs at the
    kernel-module layer above krcWatchdog at 5 Hz and catches
    what krcWatchdog misses on TB-tunneled paths.
    **upstream-PR-rationale strengthening** — does not affect
    A2's v3 surface.
  - **#1111** (lines 74-78) — *GSP firmware halt on sm_120 …
    sustained zero-gap llama.cpp inference — silent hard hang*.
    The community-signal flags this as "**strongest single
    match** for the Mode-B class our A2 watchdog targets —
    'silent freeze with nothing in dmesg' is the exact
    failure-mode signature." Per M5 framing: this is
    **code-path adjacency with high confidence** — same
    symptom signature, same observability gap (dmesg
    silent), same DMA-path locus (sustained inference). Does
    NOT demonstrably exercise A2's PMC_BOOT_0 polling path
    (the reporter has no instrumentation). The signal
    strengthens the upstream rationale for the Q-watchdog
    detection layer; it does not surface a v3 code defect.
    Both #1132 and #1111 are unrelated to A1's I8 cascade.

## v1 archaeology

The A2 surface consolidates **2 aorus-5090 ancestor patches** into a
single addon translation unit (with `lever-Q-design.md` providing the
design rationale and the reliability ledger providing the Heisenbug
acknowledgement). The carve was applied 2026-05-22 in the addon-recarve
campaign (`project_addon_recarve_merged_2026_05_22`).

- **Original design intent (Q-watchdog kthread):**
  `patches/0014-Lever-Q-watchdog-kthread.patch` lines 64-110
  (file-level comment block) — establishes the Q-active/Q-passive/
  Q-watchdog taxonomy and explicitly cites the 2026-05-05 Mode B
  silent freeze (`loop-2026-05-05-165029`) as the motivating
  incident: "the freeze locus was DMA-path (mid model upload),
  where no MMIO reads fire from userspace context, so Q-active
  stayed silent. With Q-watchdog, the bus drop is detected within
  ~NVreg_TbEgpuWatchdogIntervalMs of failure regardless of which
  subsystem caused the wedge." Lines 95-110 declare the L1
  sovereignty justification + Heisenbug acknowledgement which
  the v1 file comment preserves verbatim (renamed prefix only).

- **Original design intent (5 Hz polling cadence):**
  `docs/lever-Q-design.md` lines 99-127 (hardware constraint
  section) + `patches/0014` lines 132-139 (the
  `NVreg_TbEgpuWatchdogIntervalMs = 200` default + `[10, 60000]`
  clamp). Rationale chain: PCIe completion timeout is
  ~50us-50ms; on a TB-tunneled link the actual stall duration is
  unknown but bounded by the hardware completion timeout; 200 ms
  polling is fast enough to catch a dead bus within one cycle of
  the hardware-determined detection floor, and slow enough that
  the active-MMIO-probe-as-Heisenbug-perturbation concern is
  minimised. The interval is re-read every cycle (intent
  Requirement 2; v1 source lines 124-129) so runtime tuning
  takes effect without a kthread restart.

- **Original design intent (per-device kthread, not global):**
  `patches/0014` lines 263-265 — `kthread_run(..., "aorus-qwd-%02x%02x",
  nv->pci_info.bus, nv->pci_info.slot)`. Self-identifying in `ps`
  output; per-device lifecycle binding matches `pci_remove`'s
  per-device semantics. A2 v1 preserves this verbatim with the
  rename `aorus-qwd-*` → `tb-egpu-qwd-*` (v1 source line at
  `kthread_run` call site uses `"tb-egpu-qwd-%02x%02x"`).

- **Original design intent (kill-switch is RUNTIME-toggleable
  not build-time):**
  `docs/reliability-hypothesis-ledger.md` lines 29-39 (H1 entry)
  — the kill-switch + cycle counter exist **specifically** to
  let the operator A/B-test whether the watchdog itself perturbs
  the bug. The hypothesis was generated from Test 1 vs Test 2 on
  2026-05-05 evening (one Mode B, one Mode A; n=1 each side,
  within stochastic noise). H1 status remains "OPEN" as of the
  ledger's last update — A2's v1 surface preserves the runtime
  toggle as the load-bearing affordance for closing H1. This is
  the **load-bearing latent invariant** for A2's v1: the
  build-time `CONFIG_NV_TB_EGPU` gate (A5's master toggle)
  CANNOT subsume `NVreg_TbEgpuQwdEnable` because the
  experiment requires within-session toggleability.

- **Constraints discovered (single MMIO read is uninterruptible
  at C level):**
  `docs/lever-Q-design.md` lines 114-118 — "A single MMIO read
  instruction (`(b)->Reg032[(o)/4]`) is uninterruptible at the C
  level. The CPU stalls until the chipset returns a value or the
  hardware completion timeout fires. Software has no way to bound
  this from outside the read." This is why A2's design does NOT
  attempt `read_poll_timeout` semantics — the kthread relies on
  the hardware completion timeout (typically 50ms) for the read
  to return at all; the once-the-read-returns code is what
  declares the disconnect.

- **Constraints discovered (PMC_BOOT_0 is the dead-bus oracle):**
  `patches/0014` lines 141-145 — PMC_BOOT_0 lives at BAR0 offset 0
  across all NVIDIA architectures; the dead-bus signature
  `0xFFFFFFFF` is the PCIe-layer fill value after the hardware
  completion timeout. Lines 192-201 of the patch use
  `regs32[TB_EGPU_QWATCHDOG_PMC_BOOT_0_OFFSET]` directly without
  `READ_ONCE` — A2's v1 source upgrades this to `READ_ONCE` on
  a `volatile NvU32 *` (single non-tearing 32-bit load), which is
  a strict robustness improvement over the aorus ancestor. The
  cast establishes MMIO semantics on x86_64; on non-x86 the
  proper idiom would be `ioread32` but A2 is x86-only.

- **Alternatives considered + rejected (passive observer vs
  active heartbeat):**
  `docs/lever-Q-design.md` lines 39-43 — earlier-design
  alternatives (NMI watchdog, AER-trigger-based detection,
  workqueue-driven sanity checks) all fail in Mode B because
  the failure mode is "no MMIO read fires, no AER fires, no
  ioctl runs". The active heartbeat is the cheapest mechanism
  that detects bus loss regardless of which subsystem stalled.
  A2 v1 preserves this design choice.

- **Alternatives considered + rejected (single global kthread
  vs per-device kthread):**
  `docs/recovery.md` does not cover this; `lever-Q-design.md`
  treats the kthread as "future, optional" (line 344) without
  enumerating multi-device geometry. The per-device choice
  emerged from the addon-recarve: each `pci_dev`'s kthread has
  a lifetime bound to its `nv_pci_probe`/`_remove`, which is
  the natural per-device boundary. A2 v1 preserves this.

- **Alternatives considered + rejected (build-time
  `CONFIG_NV_TB_EGPU` gate subsumes runtime kill-switch):**
  H1 ledger entry (`docs/reliability-hypothesis-ledger.md`
  lines 29-39) makes the build-time-only gate insufficient.
  A2 v1's runtime kill-switch is the H1-experiment affordance;
  A5's master `CONFIG_NV_TB_EGPU` gates the build artefact
  separately. The two surfaces coexist.

- **Forgotten / latent invariants surfaced (DPM = D0 forced via
  modprobe.d):**
  `patches/0014` lines 31-36 (the `nv_pci_probe` hunk comment)
  document the DPM assumption: "On this hardware
  NVreg_DynamicPowerManagement=0 (forced via etc/modprobe.d) and
  udev keeps power/control=on + d3cold_allowed=0, so the device
  stays in D0 and the kthread can safely read MMIO indefinitely.
  Failure here is non-fatal — driver continues without watchdog,
  falling back to the existing Q-active wrapper." This is the
  contract that A2's `os_pci_is_disconnected` early-skip
  depends on — if the driver started in DPM-on mode, the
  kthread could race with a D0→D3 transition mid-read. The
  comment is preserved verbatim in A2 v1's `nv-pci.c` hunk.

- **Forgotten / latent invariants surfaced
  (`detected_logged` is kthread-local, NOT atomic):**
  `patches/0014` line 155 — `int detected_logged = 0;` is a
  C local variable inside `tb_egpu_qwatchdog_thread`. There is
  only one kthread per device, so single-thread access; no
  atomic needed. A2 v1 preserves this verbatim. The latch
  resets on every healthy read (line 226 of the ancestor; same
  in A2 v1) so a future episode logs again.

## Improvements considered

### A2-bus-loss-watchdog-I1 — Re-examine D1: hoist `tb_egpu_dump_aer_trigger_event` call site from A3 into A2's detection latch

- **Lens:** sovereignty (cross-cluster coupling) / duty
- **Current state:** A2 v1 source (`nv-tb-egpu-qwd.c` lines
  155-179 of the carve) latches the per-episode state
  (`last_detection_jiffies`, `last_pmc_boot_0`) inside the
  `if (!detected_logged)` block but does NOT call
  `tb_egpu_dump_aer_trigger_event(...)` to populate the
  embedded `last_aer` snapshot. The intent's
  Requirement 3 (file lines 132-153) explicitly defers the
  call to [[A3-recovery]] which patches it in at A2's
  translation unit. Until A3 lands on the cumulative stack,
  `qwd->last_aer.valid == 0` after a real dead-bus
  detection and the sysfs reader emits the placeholder
  "(no detection event yet — qwd has run %d cycles)\n".
  The intent's Scope-boundary § (lines 287-292) and v2
  review's D1 (lines 492-498) both record the deferral.
- **Proposed state:** add a single line
  `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "watchdog",
  &qwd->last_aer);` inside A2's detection latch at the
  site immediately after the `qwd->last_pmc_boot_0 = boot_0;`
  assignment. A2 then becomes the full owner of its
  detection latch path; A3's only interaction with A2's
  translation unit is reading `nvl->qwd->last_aer` for its
  recovery decision.
- **Value:** removes the sibling-addon coupling that the
  addon-recarve was designed to eliminate — A3 patching
  into A2's translation unit is exactly the cross-cluster
  edit pattern the carve aimed to prevent. With the hoist,
  A3's `.patch` does not modify A2's source file; A2 is
  the sole writer of `qwd->last_aer`.
- **Cost:** +1 line in A2's `.c`; +1 line update in the
  intent's Scope-boundary (remove the disclaimer) and
  Requirement 3 (move the call ownership from A3 to A2);
  -N lines deleted from A3's eventual patch (since the
  inline edit goes away).
- **Verification mode:** A (code-reading against v2
  review's D1 rationale at `docs/patch-reviews/A2-bus-loss-watchdog.md`
  lines 492-498) + B (after A3 lands, sysfs read of
  `tb_egpu_qwd_last_aer_summary` after a detection
  emits the populated snapshot rather than the
  placeholder).
- **Intent impact:** refine Requirement 3 + Scope boundary.
- **Triage decision:** **defer**
- **Resolution:** **deferred to A3's review (Task 11)** per
  v2 review's explicit deferral. A3 owns the recovery
  state machine that consumes the snapshot; resolving
  the call-site ownership at A2's review without A3's
  perspective risks a v2-of-v2 follow-on (A3's reviewer
  may have visibility into the recovery dispatch path
  that argues for keeping the call in A3, even though
  the addon-recarve design argues against it). The
  deferral does NOT block A2's v3 sign-off because the
  v1 mechanism (storage owned by A2, call patched in by
  A3) is internally consistent and the placeholder
  semantics is operator-visible. Per the M6
  re-examination methodology: aorus archaeology
  (`patches/0014` does not include the dump call;
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch` —
  A1's canonical ancestor — defines the dump function
  but does not call it from the watchdog) surfaces no
  new evidence to flip the deferral. The architectural
  question (which addon owns the call site) is settled
  in A3's review on the merits.

### A2-bus-loss-watchdog-I2 — Re-examine D2: detection counter wrap-guard / semantics correction

- **Lens:** robustness / naming / invariant clarity
- **Current state:** v1 source lines (in `tb_egpu_qwd_thread`):
  ```c
  if (boot_0 == TB_EGPU_QWD_DEAD_BUS_VALUE)
  {
      atomic_inc(&qwd->detections);

      if (!detected_logged)
      {
          detected_logged = 1;
          // ... log + latch ...
      }
      os_pci_set_disconnected(nv->handle);
  }
  ```
  The `atomic_inc(&qwd->detections);` fires on **every dead-bus
  cycle**, not just the latched first detection of an episode.
  The intent's sysfs prose at Requirement 4 (lines 200-204)
  documents the counter as `tb_egpu_qwd_detections` —
  "dead-bus episodes detected". v2 review (lines 320-328) notes
  the semantic drift: counter says "episodes" but increments
  per cycle. v2 review also notes the wrap concern: `atomic_t`
  is signed int; at 5 Hz polling the counter wraps after ~13
  years of CONTINUOUS detection — orders of magnitude past any
  realistic soak.
- **Proposed state:** two candidate fixes:
  - **(a) align with the documented semantic:** move
    `atomic_inc(&qwd->detections);` inside the
    `if (!detected_logged)` latch so it fires once per episode
    (matching the log-line cadence and the sysfs name "episodes").
    Net change: 1 line moved.
  - **(b) preserve current semantic, fix the wrap:** clamp via
    `atomic_inc_unless_negative` or document the wrap behaviour
    explicitly in the intent.
- **Value:** **(a)** would correct a low-key documentation lie
  in the sysfs surface name and align counter cadence with the
  log-line cadence. **(b)** would close a theoretical (13-year)
  wrap window. Neither addresses a real-world bug — at 5 Hz, no
  realistic soak hits `INT_MAX`; the documentation drift between
  "cycles within episode" vs "episodes" is internal and the
  watchdog daemon (per the addon manifest) reads the counter as
  an opaque monotonic value.
- **Cost:** **(a)** changes a stable diagnostic surface that
  has been baked into the watchdog daemon and incident analysis
  since legacy P3 (the aorus ancestor `patches/0014` lines
  202-205 already had `atomic_inc(&qwd->detections);` OUTSIDE
  the `if (!detected_logged)` latch — see ancestor lines
  202-225). Any downstream tool that has built dashboards on
  `tb_egpu_qwd_detections` as "dead-bus cycles" would
  interpret the change as a soak rate regression. **(b)**
  adds defensive code for a non-existent failure mode.
- **Verification mode:** A (code-reading vs aorus ancestor
  + v2 review's D2 rationale).
- **Intent impact:** none — both candidate fixes are
  behavioural, and the v3 disposition is to uphold v2's defer.
- **Triage decision:** **defer**
- **Resolution:** **upheld (deferred)** per v2-D2. M6
  re-examination: aorus archaeology
  (`patches/0014-Lever-Q-watchdog-kthread.patch` lines
  202-225) confirms the per-cycle increment is the
  **original semantic** carried verbatim from the
  legacy P3 watchdog. The "episodes detected" sysfs name
  is the documentation lie, NOT the counter behaviour. The
  fix is consumer-coordinated (the watchdog daemon and any
  ML observability tooling that reads this surface) and
  belongs to Task 14's cross-patch consistency audit or a
  post-soak follow-on. The wrap window (13 years at 5 Hz)
  is not a real defect class. **Default-reject discipline
  applied** per the plan's bloat-budget guidance for A2:
  the change has no production value and a non-zero risk
  of breaking the watchdog daemon's expectations.

### A2-bus-loss-watchdog-I3 — A2-A1 contract verification post-I8 (DPC offset semantic change)

- **Lens:** invariant clarity / robustness (cross-patch
  contract verification)
- **Current state:** A2's sysfs reader
  `tb_egpu_qwd_last_aer_summary_show` formats the snapshot's
  `dpc_status` field via the format string `"... DPC_Status=0x%04x ..."`
  passing `s->dpc_status`. After A1's I8 landed (commit
  `124e9c5e` on `a1-pcie-primitives`), A1's
  `tb_egpu_recover_read_dpc_state` was corrected to read
  `PCI_EXP_DPC_STATUS` (`+0x08`) instead of `PCI_EXP_DPC_CTL`
  (`+0x06`) — see `docs/patch-improvements/A1-pcie-primitives.md`
  §I8 lines 475-543. The struct field `dpc_status` is now
  populated with the **actually-interesting** DPC Status bits
  (TRIGGER, TRIGGER_RSN, INTERRUPT, RP_BUSY) rather than the
  DPC Control register's enable bits. **The label was always
  correct ("DPC_Status"); after I8 the underlying bits are now
  correct too.**
- **Proposed state:** verify that A2's intent documents the
  sysfs surface STRUCTURALLY (not VALUE-SEMANTICALLY) — if
  structural, no doc update is needed in A2; the I8
  semantic change propagates transparently to A2's
  consumers. If A2's intent or sysfs prose enumerated the
  bit-level meaning of `DPC_Status` (TRIGGER bit, etc.),
  the doc would need a refinement to capture the post-I8
  semantics.
- **Value:** confirms the A2-A1 contract is consumer-transparent
  for the I8 cascade. Audit traceability: an A3-A5 reader
  asking "what does `DPC_Status` mean in A2's sysfs after
  I8?" can answer "the DPC Status register bits, as defined
  by `<linux/pci_regs.h>` for `PCI_EXP_DPC_STATUS`" without
  needing to chase A2's own intent for the bit definition.
- **Cost:** zero — verification only.
- **Verification mode:** A (intent-prose reading) + B
  (`grep -nE 'dpc_status|DPC_Status|TRIGGER|RP_BUSY'
  docs/patch-intents/A2-bus-loss-watchdog.md`).
- **Intent impact:** none — A2's intent describes the
  sysfs surface structurally only. Requirement 4 lines
  200-211 enumerate "five `DEVICE_ATTR_RO` entries" by
  NAME (`tb_egpu_qwd_last_aer_summary` etc.) and
  general-purpose ("compact AER + DPC snapshot at last
  detect") without enumerating which DPC register bits
  are emitted. The Telemetry-contract § (lines 327-349)
  is about the per-detection log line, not the sysfs
  surface. The Provenance § (lines 419-424) lists the
  five attribute NAMES only.
- **Triage decision:** **reject** (verification passes —
  no v3 change needed)
- **Resolution:** **rejected** — verification confirms
  zero A2-side change needed. Evidence:
  - `grep -nE 'dpc_status|DPC_Status|TRIGGER|RP_BUSY'
    docs/patch-intents/A2-bus-loss-watchdog.md` returns
    zero matches for the bit-level keywords. The intent
    describes the surface name + general data class only.
  - The C source's format string `"...DPC_Status=0x%04x..."`
    (intent does not constrain the format string)
    correctly labels the field; after I8 the underlying
    bits are now what the label says.
  - The cumulative-stack consumer (`tb_egpu_qwd_last_aer_summary`
    sysfs reader, which is the only A2-side consumer of
    `s->dpc_status`) does not value-compare the bits —
    it formats them as a raw `0x%04x` for operator
    inspection. Operator semantics IMPROVE post-I8
    (now sees TRIGGER/INTERRUPT bits instead of
    EN_FATAL/INT_EN bits); operator format is unchanged.
  - The audit-reviewer for A1 (per A1 catalog §Done gate
    line 624) already verified A2's sysfs consumer scan
    returned zero value-comparing consumers — independent
    confirmation that the I8 cascade is A2-transparent.

### A2-bus-loss-watchdog-I4 — Robustness re-verification: atomic counter wrap behaviour

- **Lens:** robustness
- **Current state:** Two counters: `qwd->cycles` and
  `qwd->detections`, both `atomic_t` (kernel's wrapping
  32-bit signed integer per `Documentation/atomic_t.txt`).
  `cycles` increments every poll cycle. At the v1 default
  interval of 200ms (5 Hz), `INT_MAX` (~2.1B) is reached
  in ~13.7 years of continuous operation.
- **Proposed state:** confirm wrap is well-defined kernel
  behaviour (no undefined behaviour); document the wrap as
  acceptable given the 13-year window.
- **Value:** the kernel's `atomic_t` is explicitly defined
  to wrap (per `Documentation/atomic_t.txt`: "The atomic_t
  type is signed wrap-around"); the sysfs format `"%d\n"`
  on `atomic_read()` will emit a negative value after wrap,
  which is operator-readable as "the counter has been
  running for >13 years" rather than as a defect. The
  watchdog daemon (per the addon manifest) treats the
  counter as opaque-monotonic; reset is per-module-reload.
- **Cost:** zero — verification only.
- **Verification mode:** A (kernel doc reference) + B
  (kernel `Documentation/atomic_t.txt` on the host system).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — wrap is well-defined per
  the kernel's `atomic_t` contract. The 13-year window
  exceeds the lifetime of any plausible NUC 15 Pro+
  hardware deployment; the wrap is not a real defect class.
  See I2 for the related "documentation lie" question;
  upheld as deferred there for separate reasons.

### A2-bus-loss-watchdog-I5 — Robustness re-verification: kthread teardown ordering

- **Lens:** robustness
- **Current state:** v1 `tb_egpu_qwd_stop` (source lines
  in `nv-tb-egpu-qwd.c`):
  ```c
  void tb_egpu_qwd_stop(nv_linux_state_t *nvl)
  {
      // 1. NULL-tolerant on nvl
      if (!nvl) return;

      // 2. Remove sysfs FIRST (blocks until in-flight show callbacks return)
      if (nvl->pci_dev)
          sysfs_remove_group(&nvl->pci_dev->dev.kobj, &tb_egpu_qwd_attr_group);

      // 3. NULL-tolerant on qwd (kill-switch path)
      qwd = nvl->qwd;
      if (!qwd) return;

      // 4. kthread_stop blocks until thread observes kthread_should_stop
      if (qwd->thread) {
          kthread_stop(qwd->thread);
          qwd->thread = NULL;
      }

      // 5. free + NULL-out
      kfree(qwd);
      nvl->qwd = NULL;
  }
  ```
- **Proposed state:** confirm:
  - sysfs removal BEFORE kthread teardown (so a concurrent
    `show` callback cannot reach a freed `qwd`).
  - `kthread_stop` blocking (so `kfree(qwd)` does not race
    the kthread).
  - NULL-tolerant on `nvl == NULL` and `qwd == NULL`
    (idempotent against kill-switch + allocation-failure
    paths).
  - worst-case latency bounded by `msleep_interruptible`'s
    interruptibility (max 60s clamp).
- **Value:** confirms the unload path is race-free against
  concurrent sysfs readers and concurrent kthread
  execution. A defect here would manifest as a
  use-after-free on module unload during an active
  incident.
- **Cost:** zero — verification only.
- **Verification mode:** A (code-reading vs. kernel sysfs
  + kthread API contracts).
- **Intent impact:** none.
- **Triage decision:** **reject** (verification passes)
- **Resolution:** **rejected** — all four ordering
  conditions are satisfied. The aorus ancestor
  (`patches/0014` lines 281-302) had no sysfs surface
  (added in `patches/0015`); A2's v1 correctly
  consolidates the sysfs teardown into the same
  `_stop` function and puts the remove BEFORE the
  kthread_stop. v2 review (lines 263-271 of
  `docs/patch-reviews/A2-bus-loss-watchdog.md`)
  independently audited this. No v3 change.

### A2-bus-loss-watchdog-I6 — Duty boundary re-verification: A2 carries no recovery, no err_handlers, no WPR2 polling, no pci_reset_*

- **Lens:** duty (cross-patch dedup)
- **Current state:** v1 source. Grep-verified surfaces:
  - No `pci_reset_*` calls.
  - No `pci_error_handlers` table registration.
  - No `tb_egpu_recover_read_wpr2` call (A3's territory).
  - No direct A1 primitive call (only A1 struct embed).
  - No close-path instrumentation (A4's territory).
  - No `CONFIG_NV_TB_EGPU` build-time gate (A5's
    territory; A2 exposes runtime kill-switch instead).
  - Reads only `PMC_BOOT_0` at BAR0 offset 0 via direct
    volatile MMIO.
  - Calls only C5's `os_pci_is_disconnected` and
    `os_pci_set_disconnected`.
- **Proposed state:** confirm the duty boundary intent
  declares; any leak would force A3/A4/C4/C5's
  responsibility into A2.
- **Value:** the duty boundary is the contract A2's intent
  declares (Scope boundary § lines 277-326); verifying it
  keeps the addon-layer carve honest.
- **Cost:** zero (already correct in v1).
- **Verification mode:** B (`grep -nE 'pci_reset_|
  pci_error_handlers|tb_egpu_recover_|recover_read_|
  CONFIG_NV_TB_EGPU' kernel-open/nvidia/nv-tb-egpu-qwd.{c,h}`
  returns zero matches).
- **Intent impact:** none.
- **Triage decision:** **reject**
- **Resolution:** **rejected** — verification passes.
  Evidence: grep against A2's v1 source returns zero
  matches on the forbidden-surface patterns. A2 wraps
  kernel `kthread_*`/`msleep_*`/`atomic_*`/`sysfs_*`/
  `device_*` helpers directly (correct — those are the
  kernel's API surface, not C4/C5's wrappers). A2
  consumes A1's `struct tb_egpu_qwd_aer_snapshot` by
  embedding it (A1's consumer-owned-lifetime contract
  per A1 review's strength). A2 consumes C5's
  `os_pci_*` API at exactly two call sites
  (early-skip + disconnect propagation). Disjoint
  surfaces; correct addon-layer composition.

### A2-bus-loss-watchdog-I7 — Naming consistency

- **Lens:** naming
- **Current state:** All five sysfs attributes use the
  consistent `tb_egpu_qwd_*` prefix. The kthread name
  is `"tb-egpu-qwd-<bus><slot>"` (hyphenated for
  kernel-ps readability, dot-separated from the file
  prefix). Module parameters use `NVreg_TbEgpuQwd*`
  (matches A5's master toggle naming). Internal
  constants use `TB_EGPU_QWD_*` (matches A1's
  `TB_EGPU_RECOVER_*` and the project's all-caps
  convention).
- **Proposed state:** confirm naming is internally
  consistent and matches the project convention.
- **Value:** zero defects identified. Naming consistency
  is load-bearing for cross-patch grep + ABI tooling
  recognition.
- **Cost:** zero.
- **Verification mode:** A (code-reading) +
  `tools/lint-identifiers.sh` (project-wide check).
- **Intent impact:** none.
- **Triage decision:** **reject**
- **Resolution:** **rejected** — naming is consistent.
  No drift identified. The `last_aer.valid` field name
  is structurally correct (a boolean meaning "ever
  populated since module load"); alternatives
  ("populated", "captured") were not adopted upstream
  in A1's struct definition and changing A2's naming
  without coordinating with A1's struct would create
  drift. Naming question is closed by I3 above
  (A1 owns the struct).

### A2-bus-loss-watchdog-I8 — Performance / polling cadence

- **Lens:** performance
- **Current state:** v1 default `NVreg_TbEgpuQwdIntervalMs
  = 200` (5 Hz). Per-cycle cost: one `READ_ONCE` of a
  32-bit MMIO load (~100 ns on x86_64 root-port; longer
  on TB-tunneled) + one `atomic_inc` (~5 ns) + zero
  `os_pci_*` calls in the healthy path (the
  `os_pci_is_disconnected` early-skip is the only
  `os_pci_*` call per cycle).
- **Proposed state:** confirm the cadence balances
  detection latency vs Heisenbug perturbation. At 5 Hz
  the worst-case detection latency for a bus loss is
  ~200ms; the active-MMIO probe rate is well below the
  hardware completion timeout of ~50ms (so the kthread
  cannot starve the bus); H1's perturbation hypothesis
  (per the reliability ledger) is the gating concern.
- **Value:** the cadence is the right design choice per
  `docs/lever-Q-design.md` lines 99-127. Changing it
  without re-running the H1 A/B experiment would lose
  the experiment-affordance.
- **Cost:** zero (already correct in v1).
- **Verification mode:** A (design-doc reference).
- **Intent impact:** none.
- **Triage decision:** **reject**
- **Resolution:** **rejected** — cadence is correct.
  The runtime tunability (`NVreg_TbEgpuQwdIntervalMs`,
  re-read every cycle) is the operator's escape hatch
  for site-specific tuning if a deployment finds the
  default unsuitable.

### A2-bus-loss-watchdog-I9 — Quality re-verification: log levels, comment density

- **Lens:** quality
- **Current state:** 7 log call sites in A2 v1:
  - Lifecycle: 2 INFO (kthread start + stop).
  - Init failure: 1 INFO (kill-switch active), 2 ERRORS
    (`kzalloc` + `kthread_run` failures), 1 INFO
    (sysfs failure).
  - Detection: 1 ERRORS (the mandatory-tier
    once-per-episode detection log).
  Per the Heisenbug acknowledgement, the poll loop
  has ZERO log calls in the steady-state (healthy
  read or already-disconnected skip).
- **Proposed state:** confirm log levels match the
  telemetry contract.
- **Value:** zero log floods. The mandatory-tier ERRORS
  detection log is the only operator-visible signal per
  episode, and it carries the full diagnostic payload
  (PMC_BOOT_0 value, cycle count, action taken).
- **Cost:** zero.
- **Verification mode:** A (intent's Telemetry contract
  table at intent lines 327-349 vs. v1 source).
- **Intent impact:** none.
- **Triage decision:** **reject**
- **Resolution:** **rejected** — log levels match the
  intent's Telemetry-contract table exactly. Comments
  are dense and load-bearing (the file-level comment
  block lines 64-110 of the carve preserves the
  Heisenbug + sovereignty + scope-boundary rationale
  for any future reader).

## Re-examination of sub-cycle 2 deferrals

- **v2-D1** — A2 should own the call to
  `tb_egpu_dump_aer_trigger_event` → v3 disposition:
  **upheld (deferred to A3 Task 11)**. Aorus archaeology
  (`patches/0014-Lever-Q-watchdog-kthread.patch` lines
  64-235 — the original Q-watchdog ancestor that did NOT
  call the dump function at all; the dump was a separate
  S1/S2/S3 telemetry lever added later in
  `patches/0023-mode-b-telemetry-S1-S2-S3.patch`) surfaces
  no new evidence to flip the deferral. A3's review owns
  the call-site ownership decision on the merits.
  Surfaced as I1; deferred.
- **v2-D2** — detection counter has no wrap guard /
  semantics drift → v3 disposition: **upheld (deferred)**.
  Aorus archaeology
  (`patches/0014-Lever-Q-watchdog-kthread.patch` lines
  202-225 — original ancestor increments per cycle, not
  per episode) confirms the "increment per cycle"
  semantic is **the original design**; the sysfs
  attribute name "detections" is the documentation lie,
  not the counter behaviour. Behavioural change is
  consumer-coordinated; aorus archaeology reinforces v2's
  defer. Surfaced as I2; deferred. **Default-reject
  discipline applied** per the plan's bloat-budget
  guidance: no production value, non-zero risk to the
  watchdog daemon.
- **v2-D3** — task binding mischaracterised A2's polling
  mechanism (described A2 as polling WPR2 + AER + DPC
  rather than PMC_BOOT_0) → v3 disposition: **upheld
  (rejected)**. Aorus archaeology
  (`patches/0014-Lever-Q-watchdog-kthread.patch` lines
  192-201 — the exact `regs32[PMC_BOOT_0_OFFSET]` line)
  confirms the v1 mechanism. Binding drift is a Task 14
  artefact, not an A2 code issue. Surfaced in v2 as
  D3; not re-surfaced in v3.
- **v2-D4** — no must-fix sentinel → v3 disposition:
  **upheld (zero-delta sentinel holds for A2)**. The v3
  triangulation pass adds the kernel sysfs/kthread API
  oracle and the H1 Heisenbug-ledger oracle on top of
  v2's aorus-ancestor oracle. Neither surfaces a v3
  must-fix. The post-A1-I8 contract verification (I3)
  confirms the A2-A1 cascade is consumer-transparent.
  Nine candidates considered (I1-I9): 0 land, 2 defer
  (I1, I2 — both upheld from v2), 7 reject (I3-I9 —
  verification passes). Zero-delta sentinel holds:
  `v1-tip-sha == v2-tip-sha == cd1fe0888e7b2d135b0bb27214e32d31c9b382c3`.

## Improvements landed

(no improvements landed — v2 already meets v3 quality bar; zero-delta
sentinel holds at `cd1fe0888e7b2d135b0bb27214e32d31c9b382c3`)

## Intent updates landed

(no intent updates landed — A2's intent describes the sysfs surface
structurally and is not affected by A1's I8 semantic change to
`s->dpc_status`. See I3 for the verification.)

## Done gate

- [x] Every candidate improvement has explicit `Resolution:`
  (no `pending`). _(9 candidates: 0 landed, 2 deferred (I1
  carries D1 to A3 Task 11; I2 carries D2 to Task 14 or
  post-soak), 7 rejected (I3, I4, I5, I6, I7, I8, I9 —
  all verification passes).)_
- [x] All "land" improvements applied as fork-branch commits
  citing their `<id>-I<N>` IDs. _(N/A — zero land-tier
  improvements.)_
- [x] Substantive intent updates landed as precursor commits.
  _(N/A — zero intent updates.)_
- [x] `tools/intent-lint.sh` passes (verified on
  `docs/patch-intents/A2-bus-loss-watchdog.md` —
  no intent change in this task).
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending —
  this catalog is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A2-bus-loss-watchdog.md`
- Review file: `docs/patch-reviews/A2-bus-loss-watchdog.md`
- Manifest row: `patches/manifest` line for `A2-bus-loss-watchdog`
  (layer `addon`, source `fork:a2-bus-loss-watchdog`)
- Vanilla baseline:
  - `kernel-open/nvidia/nv-tb-egpu-qwd.c` — NEW FILE
    (no vanilla counterpart; carved from legacy P3)
  - `kernel-open/nvidia/nv-tb-egpu-qwd.h` — NEW FILE
    (no vanilla counterpart)
  - `kernel-open/common/inc/nv-linux.h` — vanilla
    `struct nv_linux_state_s`; A2 appends one field
    `struct tb_egpu_qwd *qwd;` (forward-declared pointer)
  - `kernel-open/nvidia/nv-pci.c:nv_pci_probe` — vanilla
    calls `rm_enable_dynamic_power_management`; A2 adds
    `(void)tb_egpu_qwd_init(nvl);` immediately after
  - `kernel-open/nvidia/nv-pci.c:nv_pci_remove_helper` —
    vanilla runs structured teardown; A2 prepends
    `tb_egpu_qwd_stop(nvl);` as the first teardown action
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla
    enumerates the standard module sources; A2 adds one
    line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-qwd.c`
    after A1's `nv-tb-egpu-pcie.c` line
- Fork branch: `a2-bus-loss-watchdog` on
  `apnex/open-gpu-kernel-modules` (sits on top of
  `a1-pcie-primitives`; current tip
  `cd1fe0888e7b2d135b0bb27214e32d31c9b382c3` — same as
  the A1-cascade-rebase tip; v3 zero-delta means tip is
  unchanged from v2)
- aorus-5090 ancestor patches (verified per M1+M2):
  - `patches/0014-Lever-Q-watchdog-kthread.patch`
    (canonical Q-watchdog kthread + module params + clamps
    + once-per-episode latch — 352 lines)
  - `patches/0015-Lever-Q-watchdog-sysfs-counters.patch`
    (initial 2-attribute sysfs surface; A2 expanded to 5
    attributes via `attribute_group` — 81 lines)
- aorus-5090 docs cited (M1+M2 verification):
  - `docs/lever-Q-design.md` lines 99-127 (hardware
    constraint — single MMIO read uninterruptible),
    lines 169-340 (full Q-passive + Q-active + Q-watchdog
    taxonomy), lines 335-345 (Q-watchdog deferred-to-v1
    upgrade rationale)
  - `docs/reliability-hypothesis-ledger.md` lines 29-39
    (H1 — Heisenbug A/B hypothesis; load-bearing for
    runtime kill-switch surface)
  - **Dropped per M1:** `docs/lever-R-design.md`
    (covers FLR-orchestration, not Q-watchdog
    kthread lifecycle); `docs/recovery.md` (operator
    runbook, zero hits on `watchdog|kthread|qwd`)
- Upstream issue: n/a (addon-layer; not upstream-bound;
  per Rule 5 `upstream-candidacy: n/a` for `layer: addon`)
- Community signal: `docs/patch-improvements/_community-signal.md`
  lines 68-72 (#1132 — krcWatchdog comparison, code-path
  adjacency) and lines 74-78 (#1111 — silent hard hang
  signature match, code-path adjacency with high
  confidence). Both are upstream-PR-rationale strengthening;
  neither demonstrably exercises A2's PMC_BOOT_0 polling
  path; neither surfaces a v3 code defect.
- Related catalogs:
  - `docs/patch-improvements/A1-pcie-primitives.md` (A2
    embeds A1's `struct tb_egpu_qwd_aer_snapshot`; A2 is
    the per-device storage owner. I3 verifies the
    A2-A1 contract post-I8 is consumer-transparent)
  - `docs/patch-improvements/C5-crash-safety.md` (A2
    calls C5's `os_pci_is_disconnected` early-skip and
    `os_pci_set_disconnected` propagation; disjoint
    namespaces)
  - `docs/patch-improvements/C4-err-handlers-scaffold.md`
    (C4 registers `pci_error_handlers`; A2 deliberately
    does NOT register err_handlers — that's C4's
    territory; A3 wires the body into C4's stub)
