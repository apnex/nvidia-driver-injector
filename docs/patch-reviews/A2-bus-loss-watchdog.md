---
id: A2-bus-loss-watchdog
review-date: 2026-05-23
reviewer: Claude Opus 4.7
v1-tip-sha: 6d5e5e7190f8030f76da63d643469645d6f9f4a2
v2-tip-sha: 6d5e5e7190f8030f76da63d643469645d6f9f4a2
status: accepted
related-patches: [A1-pcie-primitives]
---

# A2-bus-loss-watchdog — v2 review

## Rationale

A2 is the detection half of the addon stack's recovery loop. The
project's reliability ledger records that Q-active (the ioctl-path
MMIO-read wrapper) suffices for "Mode A" failures where the failure
itself is triggered by a userspace MMIO read; on a hit Q-active sees
`0xFFFFFFFF` and propagates the disconnect through
`os_pci_set_disconnected`. But "Mode B" — the DMA-upload-path silent
freeze characterised on 2026-05-05 (`feedback_lever_q_insufficient_for_dma`,
`project_mode_b_root_cause_open`) — wedges in a path where no userspace
MMIO read ever fires, so Q-active stays silent and the disconnect is
never propagated. The Q-watchdog kthread closes that gap: an active
heartbeat that polls `PMC_BOOT_0` at a fixed interval and propagates
the disconnect on the dead-bus signature regardless of which subsystem
stalled. The watchdog is purely a detection mechanism — A2 latches
state and propagates disconnect via [[C5-crash-safety]]'s `os_pci_set_disconnected`;
the recovery state machine ([[A3-recovery]]) reads the latched state
and decides whether to escalate to `pci_reset_bus`.

The historical context (belongs in this Rationale per M3 from the C1
checkpoint, not in the intent's Purpose) is layered. The Q-active /
Q-watchdog / Q-passive taxonomy originally lived in
`docs/lever-catalog.md` in the frozen aorus-egpu repo; the
catalog was retired 2026-05-22 (`feedback_lever_catalog_discipline`)
and the per-mechanism reasoning now lives across the injector's
`docs/patches.md` plus this review. The Heisenbug acknowledgement
(`feedback_observability_perturbs_bug`) is load-bearing for A2: a 5 Hz
active MMIO probe is more perturbing than passive bpftrace, so the
runtime kill switch (`NVreg_TbEgpuQwdEnable`) and per-device cycle
/ detection counters exist precisely so an operator can A/B
characterise whether the watchdog itself materially changes the bug
rate. The 2026-05-05 freeze fired without heavy observability
attached, suggesting the bug is not purely Heisenbug-driven — A2's
expectation is to provide real signal rather than perturb the bug
away. The 2026-05-08 Lever M-recover landing
(`project_lever_m_recover_landed_2026_05_08`) and the 2026-05-08
real-world fire (`project_m_recover_first_real_fire_2026_05_08`) are
A3-territory not A2, but they were the consumers that proved A2's
detection latch was producing actionable state.

The persistent capability A2 grants the driver is: "a per-device
heartbeat kthread spawned at probe SHALL detect dead-bus on the
DMA-upload path within ~200 ms, latch the episode into per-device
sysfs-visible state, emit exactly one mandatory log line per episode,
and propagate the disconnect through C5's `os_pci_set_disconnected`
so all subsequent RM-side MMIO reads short-circuit." That capability
is the contract this review file and the matching intent govern.

## v1 audit

The v1 fork branch tip (`6d5e5e7190f8030f76da63d643469645d6f9f4a2`
— "tb-egpu: bus-loss watchdog (A2)") sits on top of the cumulative
`a1-pcie-primitives` base and adds one commit's worth of changes:
499 insertions across 5 files (two new files plus three additive
hunks into vanilla files). No deletions; no modifications to any
vanilla NVIDIA logic — every vanilla edit is purely additive (new
field, new include, new call sites).

**Hunk-by-hunk audit (against the immediately-prior `a1` tip):**

1. **`kernel-open/nvidia/nv-tb-egpu-qwd.c`** — NEW FILE (401 lines).
   MIT-licensed (SPDX `nvidia-driver-injector contributors` — the
   project-local attribution). File-level comment explicitly:
   (a) describes the Q-active vs Q-watchdog vs Q-passive taxonomy;
   (b) calls out the 2026-05-05 Mode B silent freeze as the
   justifying incident; (c) declares the scope boundary (no
   auto-FLR, no `kobject_uevent`, no DPM-aware backoff because the
   driver runs with `NVreg_DynamicPowerManagement=0` plus udev
   `power/control=on` + `d3cold_allowed=0`); (d) declares the L1
   sovereignty justification (kthread needs `nv_state_t::regs->map`
   access plus lifecycle binding to `nvidia.ko` probe/remove plus
   call into the project-added `os_pci_set_disconnected` API);
   (e) declares the Heisenbug acknowledgement and the runtime
   kill-switch / counter rationale; (f) declares the
   cross-cluster dependency on A1's
   `tb_egpu_dump_aer_trigger_event` being patched in by A3 at
   the detect site.

   The file contains:
   - Two module parameters: `NVreg_TbEgpuQwdEnable` (uint,
     default 1, mode 0644) and `NVreg_TbEgpuQwdIntervalMs` (uint,
     default 200, mode 0644). Both fully documented via
     `MODULE_PARM_DESC`.
   - Two clamp constants: `TB_EGPU_QWD_MIN_INTERVAL_MS = 10U`,
     `TB_EGPU_QWD_MAX_INTERVAL_MS = 60000U`.
   - One offset constant: `TB_EGPU_QWD_PMC_BOOT_0_OFFSET = 0u`
     with a comment justifying why PMC_BOOT_0 is BAR0 offset 0
     across NVIDIA architectures.
   - One dead-bus constant: `TB_EGPU_QWD_DEAD_BUS_VALUE = 0xFFFFFFFFu`
     with a comment citing the legacy `nv-tb-egpu.h`
     `TB_EGPU_DEAD_BUS_U32` and explaining why it is redefined
     here (kernel-open does not include the RM tree's header
     search path).
   - The kthread function `tb_egpu_qwd_thread`:
     - Reads interval each cycle (so runtime tuning takes
       effect); clamps to `[10, 60000]` ms.
     - Sleeps via `msleep_interruptible(interval_ms)`.
     - Honours `kthread_should_stop` immediately after sleep.
     - Honours the runtime kill switch
       (`NVreg_TbEgpuQwdEnable`) by skipping the read but not
       exiting.
     - Defensive null-checks on `nv`, `nv->regs`, `nv->regs->map`
       (early-probe / late-remove race window).
     - Calls `os_pci_is_disconnected(nv->handle)` first; skips
       the read if already disconnected (avoids re-firing the
       latch within the same episode).
     - Reads `PMC_BOOT_0` via
       `READ_ONCE(((volatile NvU32 *)nv->regs->map)[0])` — single
       non-tearing, non-reordered 32-bit MMIO load.
     - Increments `qwd->cycles` atomically every poll.
     - On `boot_0 == 0xFFFFFFFFu`: increments `qwd->detections`,
       emits one `NV_DBG_ERRORS` log line on first detection of
       the episode (latched by `detected_logged`), latches
       `last_detection_jiffies` and `last_pmc_boot_0`, then calls
       `os_pci_set_disconnected(nv->handle)` on every dead-bus
       cycle (not just the latched first).
     - On healthy read: clears the once-per-episode latch so a
       future episode logs again.
     - Logs one info line at start ("kthread started") and one
       at stop ("kthread stopped (cycles=%d detections=%d)").
   - Five sysfs attribute show functions, each
     `to_pci_dev(dev)` → `pci_get_drvdata(pdev)` →
     `nv_linux_state_t *nvl` lookup, with NULL-safe placeholders.
     `tb_egpu_qwd_last_aer_summary_show` checks
     `s->valid == 0` and emits the "no detection event yet"
     placeholder; on `valid == 1` emits the full snapshot
     block.
   - `DEVICE_ATTR(name, 0444, show, NULL)` for each of the
     five (read-only).
   - `tb_egpu_qwd_init` and `tb_egpu_qwd_stop` lifecycle
     entrypoints called from `nv-pci.c`.

2. **`kernel-open/nvidia/nv-tb-egpu-qwd.h`** — NEW FILE (68 lines).
   MIT-licensed (same SPDX header). Includes `nv-tb-egpu-pcie.h`
   (A1's header) to get `struct tb_egpu_qwd_aer_snapshot` and the
   `tb_egpu_dump_aer_trigger_event` declaration transitively. The
   header comment explicitly states "A2 must not re-define the
   struct." The header declares:
   - `struct tb_egpu_qwd` — five fields: `thread` (kthread
     handle), `cycles` and `detections` (atomic counters),
     `last_detection_jiffies` and `last_pmc_boot_0`
     (post-detection state), and `last_aer` (the embedded
     `struct tb_egpu_qwd_aer_snapshot` from A1).
   - Two function prototypes: `tb_egpu_qwd_init`,
     `tb_egpu_qwd_stop`.
   - Forward decls of `struct task_struct` and
     `struct nv_linux_state_s` (to avoid heavy includes).

3. **`kernel-open/common/inc/nv-linux.h`** — additive: one field
   added to `struct nv_linux_state_s` immediately after the
   `init_on_probe` field — `struct tb_egpu_qwd *qwd;`
   (forward-declared opaque pointer; the comment explicitly
   states this is to avoid pulling `nv-tb-egpu-qwd.h` into common
   headers).

4. **`kernel-open/nvidia/nv-pci.c`** — additive: three hunks.
   - One `#include "nv-tb-egpu-qwd.h"` at the top after the
     existing `#include "nv-reg.h"` with a `/* tb_egpu Q-watchdog
     (addon A2) */` justifying comment.
   - One `(void)tb_egpu_qwd_init(nvl);` call in `nv_pci_probe`
     after `rm_enable_dynamic_power_management(sp, nv);` with a
     six-line comment justifying placement (RM bring-up complete,
     DPM forced off so MMIO is safe in D0, failure is non-fatal).
     The `(void)` cast discards the return code deliberately.
   - One `tb_egpu_qwd_stop(nvl);` call in
     `nv_pci_remove_helper` after `nv = NV_STATE_PTR(nvl);` and
     before any other state teardown, with a six-line comment
     justifying placement (kthread must exit before `nv->regs->map`
     and `nv->handle` are torn down).

5. **`kernel-open/nvidia/nvidia-sources.Kbuild`** — additive: one
   line `NVIDIA_SOURCES += nvidia/nv-tb-egpu-qwd.c` inserted
   after the existing `nv-tb-egpu-pcie.c` line (A1's line). No
   `CONFIG_*` gate.

**Strengths.**

- **A1 ABI consumption is correct in every audited respect.**
  A2 embeds `struct tb_egpu_qwd_aer_snapshot last_aer` in
  `struct tb_egpu_qwd` — exact match for A1's "consumer-owned
  lifetime" contract documented in the A1 review's "AER struct
  lifetime is owned by the consumer" strength. A2's header
  includes A1's header (`nv-tb-egpu-pcie.h`) to get the type
  transitively; A2 does NOT re-define the struct (the header
  comment makes this explicit, and `grep -nE "tb_egpu_qwd_aer_snapshot"`
  in A2's source confirms only one mention — as a type usage,
  not a definition). The struct field name is `last_aer`, which
  matches the body-prose example in A1's review
  (`tb_egpu_dump_aer_trigger_event(pdev, "watchdog", &qwd->last_aer)`).
- **A2 does NOT introduce a global lock around any A1 call
  site.** A1's pure-observability contract states "the helpers
  MUST be safe to call from a kthread (the A2 watchdog), from
  the `pci_error_handlers` callback dispatch (A3), and from RM
  close-path callbacks (A4) without coordination beyond each
  consumer's own locking discipline." A2 holds no global lock;
  the kthread's only synchronisation is the `atomic_t`
  increment on `cycles`/`detections` (no lock needed) and the
  `kthread_should_stop` checkpoint (kthread API). The sysfs
  readers read `qwd->last_*` fields without a lock — A2's source
  acknowledges this is a torn-read window for the AER snapshot,
  declared "acceptable for diagnostic telemetry" in A1's header
  comment. The propagation call `os_pci_set_disconnected` is
  C5's responsibility to make thread-safe.
- **PMC_BOOT_0 read shape is correct.** `READ_ONCE` on a
  `volatile NvU32 *` is the canonical Linux idiom for a
  single-load MMIO read without compiler tearing or
  reordering. The cast `(volatile NvU32 *)nv->regs->map`
  treats the BAR0 base as the right type; offset `[0]` is the
  documented PMC_BOOT_0 location across NVIDIA architectures
  (the file comment cites this; no version dependency).
- **Lifecycle binding is correct.** `tb_egpu_qwd_init` is
  called after `rm_enable_dynamic_power_management` in the
  probe path — RM is fully bound, BAR mappings are live, the
  device is in D0. `tb_egpu_qwd_stop` is the FIRST teardown
  call in `nv_pci_remove_helper` after `nv = NV_STATE_PTR(nvl)`
  — kthread exits before any state it reads (`nv->regs->map`,
  `nv->handle`) is torn down. `kthread_stop` is blocking and
  bounded by `msleep_interruptible(interval_ms)` (max 60 s)
  since the sleep is interruptible by the kthread-stop signal
  and the loop checks `kthread_should_stop` immediately after
  sleep returns.
- **Episode latch is correct.** `detected_logged` is a kthread
  local that resets on every healthy read — so a future
  episode logs again. Cleanly handles the case where the
  disconnect propagates but later clears (e.g. a recovery in
  A3 succeeds and the device re-binds): the latch resets on
  the first healthy read after recovery, so the next
  dead-bus event logs at the same fidelity.
- **Per-cycle logging is zero.** Per the commit message's
  observability audit, the poll loop has zero log calls; 7
  log calls total, all one-time lifecycle events or
  detection-episode-latched. This is exactly what the
  Heisenbug acknowledgement requires — no log floods that
  would themselves perturb the bug.
- **Failure modes are non-fatal.** Both `kzalloc` failure
  and `kthread_run` failure are caught and logged at
  `NV_DBG_ERRORS` but allow probe to continue with
  `nvl->qwd = NULL`. The init returns an error code, but
  `nv_pci_probe` wraps the call with `(void)` to discard it.
  Sysfs group create failure is logged at `NV_DBG_INFO` and
  does not affect the kthread.
- **Module parameter surface is well-documented.**
  `MODULE_PARM_DESC` for both `NVreg_TbEgpuQwdEnable` and
  `NVreg_TbEgpuQwdIntervalMs` describes the default, the
  clamp, and the runtime-toggleable behaviour. The interval
  clamp `[10, 60000]` is enforced at the kthread (every
  cycle re-reads the module parameter and re-clamps) rather
  than at parameter write time, so an operator who writes
  a value outside the clamp gets the clamped behaviour
  rather than a `-EINVAL`.
- **Sysfs surface placement under PCI device kobject is
  correct.** Five `DEVICE_ATTR_RO` attributes registered via
  `sysfs_create_group` on `nvl->pci_dev->dev.kobj` — the
  per-device PCI sysfs path (`/sys/bus/pci/devices/<BDF>/`).
  Operators reach them via the BDF without needing module
  parameters. Removal is in `tb_egpu_qwd_stop` BEFORE
  `kthread_stop` so a concurrent sysfs read during teardown
  cannot reach a freed `nvl->qwd` — the attribute group
  removal blocks until all in-flight `show` callbacks return.

**Weaknesses.**

- **A2 v1 defers the call to `tb_egpu_dump_aer_trigger_event`
  to A3.** A2's source comment at the detection latch site
  explicitly says "addon A3 patches in the call to
  `tb_egpu_dump_aer_trigger_event()` at this site to populate
  it." Until A3 lands on top of A2, `qwd->last_aer.valid`
  stays `0` and the sysfs reader emits the "(no detection
  event yet — qwd has run %d cycles)\n" placeholder even
  AFTER a real dead-bus detection (because the snapshot
  storage exists but is never written). This is a coupling
  between sibling addons (A3 patches into A2's translation
  unit) which is exactly the kind of cross-cluster coupling
  the addon-recarve was designed to eliminate. A cleaner
  shape would be for A2 itself to call A1's
  `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "watchdog",
  &qwd->last_aer)` immediately after latching the
  per-episode state, so A2 is the full owner of its
  detection latch path. Surfaced as
  `A2-bus-loss-watchdog-D1` below with severity `should-fix`.
  Resolution: deferred to [[A3-recovery]]'s review, where
  A3 can elect to either (a) patch the call into A2's
  detection latch (matching v1's current shape but
  re-litigating the sibling-addon coupling), or
  (b) hoist the call into A2 so A3 only consumes the
  populated `last_aer` without writing into A2's
  translation unit. Either way the A3 review owns the
  resolution because A3 owns the recovery state machine
  that the call site feeds into.
- **The kthread does not exit on `os_pci_set_disconnected`.**
  Once the GPU is declared disconnected, subsequent
  iterations enter the `os_pci_is_disconnected(nv->handle)`
  early-skip branch — but they still increment `qwd->cycles`?
  No, the cycle counter is incremented only after the
  early-skip check passes (after the `os_pci_is_disconnected`
  guard but before the MMIO read), so the disconnect-skip
  path increments nothing. That is correct — the cycle
  counter reflects the number of completed MMIO reads, not
  the number of poll iterations. (Auditing this is
  load-bearing: a future reader might misread the counter
  semantics. Surfaced as a documentation-only delta below
  with severity `out-of-scope`.)
- **No upper bound on detection counter spam.** The
  detection counter is `atomic_t` (int-sized) and is
  incremented on every dead-bus cycle, not just the
  latched first detection of an episode. If the disconnect
  ever clears (e.g. A3 recovers the device, the latch
  resets, the GPU drops off the bus AGAIN, the latch
  re-fires) the counter can grow without bound across an
  arbitrary number of episodes over a long-running soak.
  Wraps at `INT_MAX` (~2.1 billion) — at 5 Hz polling that's
  ~13 years of continuous detection. Not a real concern in
  practice, but the wrap behaviour is technically
  undefined (`atomic_inc` on a maxed-out atomic). Surfaced
  as `A2-bus-loss-watchdog-D2` below with severity
  `nice-to-have`.
- **`os_pci_set_disconnected` is called on every dead-bus
  cycle.** Per the code shape, after the first latched
  detection the kthread still calls
  `os_pci_set_disconnected(nv->handle)` on every subsequent
  dead-bus cycle within the same episode (because the
  call is outside the `if (!detected_logged)` latch).
  This is intentional per the comment "Keep looping:
  counters keep ticking; if the disconnect ever clears
  we'll re-fire and re-log" — but the re-fire-and-re-log
  path actually depends on the `detected_logged`
  variable resetting on a healthy read, not on
  `os_pci_set_disconnected` being idempotent. The
  repeated `os_pci_set_disconnected` calls per episode
  are wasted work (the disconnect flag is already set).
  C5's `os_pci_set_disconnected` is idempotent per the
  C5 review (it just sets a flag), so the repeated calls
  are harmless. But the actual early-skip path
  (`os_pci_is_disconnected(nv->handle)`) means the
  subsequent dead-bus cycles within an episode never
  actually reach the
  `os_pci_set_disconnected` call — they skip earlier.
  So the audit above ("called on every dead-bus cycle"
  is wrong — the early-skip suppresses both the MMIO
  read and the set-disconnected). The code shape is
  internally consistent. Surfaced as a verification-only
  observation; no delta.

**Surprises relative to vanilla.**

- The patch is pure-additive against vanilla NVIDIA source.
  The three vanilla files touched (`nv-linux.h`, `nv-pci.c`,
  `nvidia-sources.Kbuild`) each gain new lines without
  modifying any existing lines. No vanilla logic semantic
  drift.
- Vanilla `kernel-open/common/inc/nv-linux.h` defines
  `struct nv_linux_state_s` with ~70 fields; A2 appends
  `struct tb_egpu_qwd *qwd;` as the last field. Forward
  declaration in `nv-linux.h` avoids pulling A2's header
  into the common include tree.
- Vanilla `kernel-open/nvidia/nv-pci.c` already calls
  `rm_enable_dynamic_power_management` near the end of
  `nv_pci_probe`; A2 slots its init call immediately after
  that, before the `nv_kmem_cache_free_stack(sp)` cleanup.
  The remove path's
  `nv_pci_remove_helper` already has structured teardown;
  A2 slots its stop call as the first teardown action
  after the `nv = NV_STATE_PTR(nvl)` assignment.
- Vanilla `nvidia-sources.Kbuild` enumerates ~60 source
  files; A2 inserts one line after A1's
  `nv-tb-egpu-pcie.c` line. The placement preserves the
  loose subsystem grouping (A1 + A2 adjacent under the
  `tb-egpu` addon group).

## Design choices

The main alternatives considered during the v2 review:

- **Active MMIO heartbeat vs. passive failure-mode observer.**
  Q-watchdog could in principle be implemented as a passive
  observer that hooks into RM's existing error paths instead of
  firing its own MMIO reads. Rejected because the failure mode
  this patch addresses (DMA-path Mode B) is precisely the case
  where RM's error paths stay silent — no userspace MMIO read
  fires, no RM ioctl runs, no error callback triggers. The
  active heartbeat is the cheapest mechanism that detects bus
  loss regardless of which subsystem stalled. Kept v1's active
  probe.

- **Per-device kthread vs. single global kthread iterating
  all devices.** A2 spawns one kthread per probed eGPU. A
  single global kthread iterating all devices would save
  kernel resources but would couple per-device lifecycle to
  global state. Rejected for clarity — the per-device
  kthread's lifetime is bound to the `pci_dev` it monitors,
  the kthread name (`tb-egpu-qwd-<bus><slot>`) is
  self-identifying in `ps`, and teardown ordering is per-device
  (matches `pci_remove`'s per-device semantics). Kept v1's
  per-device kthread.

- **PMC_BOOT_0 polling vs. WPR2 polling.** The task bindings
  for this review described A2 as "polling WPR2 + AER + DPC
  via A1's primitives" — that was an inaccuracy in the
  bindings. A2's actual mechanism (PMC_BOOT_0 polling at
  BAR0 offset 0) is the legacy P3 design and is correct: WPR2
  is a GSP-state register that signals "GSP is alive and
  running" while PMC_BOOT_0 is the chip-identifier register
  whose dead-bus signature is `0xFFFFFFFF` (the PCIe
  completion-timeout fill value). A1's
  `tb_egpu_recover_read_wpr2` primitive exists for
  [[A3-recovery]]'s WPR2-stuck detection (a different
  failure signature where GSP itself wedges with WPR2
  non-zero — see
  `project_wpr2_mechanism_2026_05_06`). The two signatures
  are complementary: A2 detects bus loss (PCIe-layer); A3
  detects GSP wedge (firmware-layer). Kept v1's PMC_BOOT_0
  polling. Surfaced as `A2-bus-loss-watchdog-D3` below with
  severity `out-of-scope` (binding-document inaccuracy; A2's
  v1 mechanism is correct).

- **Detection-time AER dump call site: A2 vs. A3.** The
  obvious shape is for A2 itself to call
  `tb_egpu_dump_aer_trigger_event(pdev, "watchdog",
  &qwd->last_aer)` at the detection latch site, since A2 owns
  the storage. v1 defers the call to A3, which patches into
  A2's translation unit. The cleaner shape (A2 owns its call)
  would eliminate the sibling-addon coupling that the
  addon-recarve was designed to remove. Surfaced as
  `A2-bus-loss-watchdog-D1` below with severity `should-fix`,
  resolution `deferred to A3's review` since A3 owns the
  recovery state machine and will decide whether the call
  goes in A2 (cleaner) or in A3's recovery dispatch (matching
  v1).

- **Runtime kill switch vs. build-time `CONFIG_NV_TB_EGPU`
  gate.** v1 exposes runtime `NVreg_TbEgpuQwdEnable` (kill
  switch) and `NVreg_TbEgpuQwdIntervalMs` (interval) module
  parameters. A5's master `CONFIG_NV_TB_EGPU` build-time
  gate could in principle subsume the kill switch
  (build-without-watchdog = same as `Enable=0`). Rejected
  because the Heisenbug A/B characterisation requires
  runtime toggleability without a module reload — when the
  hypothesis is "the heartbeat itself perturbs the bug",
  the experiment is "live-toggle and observe within the
  same session." The two surfaces are complementary:
  `CONFIG_NV_TB_EGPU` gates the build artefact;
  `NVreg_TbEgpuQwdEnable` gates the runtime behaviour
  within a built artefact. Kept v1's runtime kill switch.

- **`READ_ONCE` on volatile MMIO vs. `ioread32`.** v1 uses
  `READ_ONCE(((volatile NvU32 *)nv->regs->map)[0])`. The
  alternative `ioread32(nv->regs->map)` would be more
  portable (handles strict-alignment architectures and
  weak-memory ordering primitives correctly). Considered
  bumping to `ioread32`. Rejected because `nv->regs->map`
  is already typed as `void *` (a CPU-virt pointer
  obtained from a prior `ioremap`), so the `READ_ONCE` on
  `volatile NvU32 *` cast IS the correct pattern in
  context — the volatile cast establishes
  MMIO semantics on x86_64 (the only architecture this
  driver supports per the project's manifest). On non-x86
  architectures, `ioread32` would be safer; A2 is x86-only
  per the broader project scope, so `READ_ONCE` on
  `volatile` is acceptable. Kept v1's shape.

- **`os_pci_set_disconnected` on every detection cycle
  vs. only on first.** v1 calls
  `os_pci_set_disconnected(nv->handle)` outside the
  once-per-episode latch — so it would fire on every
  dead-bus cycle within an episode if not for the
  earlier-skip `os_pci_is_disconnected` guard at the
  top of the loop. Considered moving the call inside
  the latch. Rejected because the comment "Keep
  looping: counters keep ticking; if the disconnect
  ever clears we'll re-fire and re-log" depends on the
  re-fire path being explicit — even though the
  early-skip path makes the per-cycle call redundant,
  keeping the call explicit at the detection site
  makes the propagation contract obvious at the call
  site rather than at the early-skip guard. Kept v1's
  shape.

## v1 → v2 deltas

### A2-bus-loss-watchdog-D1 — A2 should own the call to `tb_egpu_dump_aer_trigger_event`

- **Location:** `kernel-open/nvidia/nv-tb-egpu-qwd.c:tb_egpu_qwd_thread` — the dead-bus detection latch (inside `if (!detected_logged)` at the site that latches `last_detection_jiffies` and `last_pmc_boot_0`).
- **Change:** Could add the line `tb_egpu_dump_aer_trigger_event(nvl->pci_dev, "watchdog", &qwd->last_aer);` inside the detection latch immediately after `qwd->last_pmc_boot_0 = boot_0;`. v1 defers the call to A3 patching in.
- **Severity:** should-fix
- **Evidence:** The A1 review's Requirement section (specifically the "Repeated calls to a primitive from any context are independent" scenario) and the consumer-owned-lifetime contract both anticipate A2 as the caller: "the A2 watchdog kthread calls `tb_egpu_dump_aer_trigger_event(pdev, "watchdog", &qwd->last_aer)`". The task bindings for this review explicitly state "A2 passes `out = &qwd->aer` (not NULL) when calling `tb_egpu_dump_aer_trigger_event` because A2 is the only consumer that persists the snapshot." v1's deferral to A3 (A3 patches into A2's translation unit) is exactly the sibling-addon coupling the addon-recarve was designed to eliminate (per the 2026-05-22 addon-recarve design spec §"Carve approach"). A2 owns the storage (`qwd->last_aer`); A2 owns the trigger event (the dead-bus detection); A2 should own the call. Hoisting the call into A2 means A3's only interaction with A2's translation unit is reading `nvl->qwd->last_aer` for its recovery decision — no in-line edit, no shared translation unit.
- **Resolution:** deferred to [[A3-recovery]]'s review (Task 11). A3 owns the recovery state machine that consumes the snapshot. A3's review can elect either (a) patch the call into A2's detection latch (matching v1's current shape, re-litigating the sibling coupling), or (b) hoist the call into A2 here at A2's review and have A3 only read `nvl->qwd->last_aer`. The decision belongs to A3's review because A3 has full visibility into how the recovery dispatch path consumes the snapshot; resolving here without A3's perspective risks a v2-of-v2 follow-on. The contract recorded for sub-cycle 2 downstream consumers is: until A3 lands, `qwd->last_aer.valid == 0` after detection (the sysfs reader emits the "no detection event yet" placeholder); A3's review will resolve which translation unit owns the dump call.

### A2-bus-loss-watchdog-D2 — Detection counter has no wrap guard

- **Location:** `kernel-open/nvidia/nv-tb-egpu-qwd.c:tb_egpu_qwd_thread` — the `atomic_inc(&qwd->detections);` call on every dead-bus cycle.
- **Change:** Could clamp the counter at `INT_MAX` or move it inside the `if (!detected_logged)` latch so it only increments once per episode (matching the log-line cadence).
- **Severity:** nice-to-have
- **Evidence:** `atomic_inc` on a maxed-out `atomic_t` is technically undefined behaviour (signed overflow). In practice at 5 Hz polling the counter wraps after ~13 years of continuous detection, which is well past any realistic soak window. The "every dead-bus cycle" semantics is also arguably wrong — the counter is documented in the sysfs surface as "dead-bus episodes detected" but actually counts dead-bus CYCLES within an episode (the cycle counter `qwd->cycles` is the one that counts iterations). Moving the increment inside the latch would align the counter with its documented semantics. The tradeoff is a behavioural change to a stable diagnostic surface; v1's semantics has been baked into the watchdog daemon and incident analysis since the legacy P3 patch. Defer the cleanup until a downstream consumer (e.g. A4's close-path telemetry or a future revision of the watchdog daemon) actually depends on the corrected semantics.
- **Resolution:** deferred to a follow-on cleanup or to Task 14's cross-patch consistency audit. The counter wrap is harmless in practice; the semantics correction is a behavioural change that should be coordinated with the watchdog daemon's expectations.

### A2-bus-loss-watchdog-D3 — Task binding mischaracterised A2's polling mechanism

- **Location:** Task 10 bindings in `docs/superpowers/plans/2026-05-23-patch-v2-reviews.md` (description text: "A2 consumes A1's `tb_egpu_recover_*` primitives — verbatim names" and "A2's WPR2 polling code should consume `_VAL_MASK`").
- **Change:** The bindings could be updated to clarify that A2 polls `PMC_BOOT_0` (not WPR2 + AER + DPC) and does NOT consume A1's recovery primitives directly — A2's only A1 dependency is the embedded `struct tb_egpu_qwd_aer_snapshot` type and the (deferred to A3) `tb_egpu_dump_aer_trigger_event` call. The WPR2 / AER / DPC primitive consumers are [[A3-recovery]] (recovery dispatch) and [[A4-close-path-telemetry]] (close-path events).
- **Severity:** out-of-scope
- **Evidence:** v1 source (`nv-tb-egpu-qwd.c:tb_egpu_qwd_thread`) reads `PMC_BOOT_0` via direct volatile MMIO at BAR0 offset 0; the dead-bus value is `0xFFFFFFFFu` (PCIe completion timeout fill value) rather than the WPR2-stuck signature (`raw & TB_EGPU_RECOVER_WPR2_VAL_MASK != 0` after rmInit FAIL). The two are complementary failure signatures: A2 is the PCIe-layer dead-bus detector; A3 is the firmware-layer GSP-wedge detector. The bindings document drift (Task 14's cross-patch consistency audit can correct it) does not affect A2's v1 behaviour.
- **Resolution:** rejected — no v1 change. The task bindings drift is a documentation issue for Task 14 to surface as a finding on the plan document; A2's v1 mechanism is correct.

### A2-bus-loss-watchdog-D4 — No must-fix deltas

- **Location:** n/a
- **Change:** v1's behaviour, telemetry, and surface match the v2 intent's normative shape. The intent's five Requirements are satisfied: the per-device kthread spawn is wired correctly; the heartbeat poll loop has the right shape (clamp + sleep + kill switch + defensive null check + already-disconnected skip + READ_ONCE volatile MMIO + atomic counters); the detection latch emits one mandatory log line per episode; the five sysfs attributes are registered correctly with placeholder semantics; the clean unload sequence is correct (sysfs remove → kthread stop → kfree → null). A1's ABI consumption is verified verbatim (embedded snapshot struct; no struct redefinition; no global lock; deferred dump call documented). No fork-branch follow-up commits are required.
- **Severity:** out-of-scope
- **Evidence:** The intent's Provenance section captures the file inventory, the A1 ABI consumption notes, the module parameter surface, and the sysfs surface verbatim from the v1 source. Every scenario in the five Requirements maps to a v1 code path. The Scope boundary's eight non-goals are each satisfiable by inspection of the v1 file: no recovery state machine (→ A3); no `pci_error_handlers` (→ C4); no direct A1 primitive calls (only struct embedding); no WPR2 polling (→ A3); no close-path instrumentation (→ A4); no `CONFIG_NV_TB_EGPU` gate; no userspace `kobject_uevent`. The deferred A1 dump call (D1) is a should-fix cross-patch coupling concern, not a v1 behavioural defect — the deferral is documented, the storage is allocated, and A3's review will resolve which translation unit owns the call.
- **Resolution:** rejected — no v2 follow-up needed.

Per M2 (zero-delta sentinel from the C1 checkpoint), the frontmatter
`v1-tip-sha == v2-tip-sha == 6d5e5e7190f8030f76da63d643469645d6f9f4a2`
is the machine-checkable signal that v1 already met v2 intent. The
four deltas (D1 should-fix deferred to A3, D2 nice-to-have deferred,
D3 out-of-scope, D4 explicit no-must-fix) are recorded for
provenance and to give the next downstream task reviewers (A3 / A4)
the contract they should code against:

- A2's per-device storage `nvl->qwd->last_aer` is the
  `struct tb_egpu_qwd_aer_snapshot` instance that
  [[A1-pcie-primitives]]'s `tb_egpu_dump_aer_trigger_event` populates;
  the call site for that primitive is owned by [[A3-recovery]] in v1
  (subject to D1's resolution).
- A2's heartbeat polls PMC_BOOT_0 only; it does NOT consume A1's
  WPR2 / AER / DPC / topology primitives. Those are
  [[A3-recovery]]'s and [[A4-close-path-telemetry]]'s territory.
- A2's runtime kill switch (`NVreg_TbEgpuQwdEnable`) and interval
  tuning (`NVreg_TbEgpuQwdIntervalMs`) are independent of A5's
  build-time `CONFIG_NV_TB_EGPU` master toggle. Both surfaces
  coexist; runtime toggle is required for Heisenbug A/B
  characterisation.

## Done gate

- [x] `docs/patch-intents/A2-bus-loss-watchdog.md` exists, lints clean, `status: reviewed`.
- [x] All must-fix deltas applied as fork-branch commits citing their delta IDs. _(N/A — zero must-fix deltas; D1 should-fix deferred to A3, D2 nice-to-have deferred, D3 out-of-scope, D4 explicitly closes "no must-fix".)_
- [x] `patches/addon/A2-bus-loss-watchdog.patch` refreshed by `regen`. _(N/A — no fork-branch change; existing file already reflects `6d5e5e71`.)_
- [x] `tools/validate-patchset.sh` passes (compile gate).
- [x] `bash tests/run.sh` green.
- [ ] Audit-reviewer subagent approved. _(Pending — this review file is the audit-reviewer's input.)_

## Cross-references

- Intent file: `docs/patch-intents/A2-bus-loss-watchdog.md`
- Manifest row: `patches/manifest` line for `A2-bus-loss-watchdog`
  (layer `addon`, source `fork:a2-bus-loss-watchdog`)
- Vanilla baseline:
  - `kernel-open/common/inc/nv-linux.h` — vanilla 595.71.05
    `struct nv_linux_state_s`; A2 appends one field
    `struct tb_egpu_qwd *qwd;` (forward-declared pointer).
  - `kernel-open/nvidia/nv-pci.c:nv_pci_probe` — vanilla calls
    `rm_enable_dynamic_power_management`; A2 adds
    `(void)tb_egpu_qwd_init(nvl);` immediately after.
  - `kernel-open/nvidia/nv-pci.c:nv_pci_remove_helper` — vanilla
    runs structured teardown; A2 prepends
    `tb_egpu_qwd_stop(nvl);` as the first teardown action.
  - `kernel-open/nvidia/nvidia-sources.Kbuild` — vanilla
    enumerates the standard module sources; A2 adds one line
    `NVIDIA_SOURCES += nvidia/nv-tb-egpu-qwd.c` after the
    A1-added `nv-tb-egpu-pcie.c` line.
  - `kernel-open/nvidia/nv-tb-egpu-qwd.c` — NEW FILE
    (no vanilla counterpart; carved from legacy P3).
  - `kernel-open/nvidia/nv-tb-egpu-qwd.h` — NEW FILE
    (no vanilla counterpart).
- Fork branch: `a2-bus-loss-watchdog` on
  `apnex/open-gpu-kernel-modules`
- Upstream issue: n/a (addon-layer; not upstream-bound; per Rule
  5 `upstream-candidacy: n/a` for `layer: addon`). The
  Q-watchdog mechanism is project-permanent infrastructure
  closing the DMA-path Mode B detection gap; upstream NVIDIA
  has no equivalent watchdog mechanism and the closed-driver
  surface does not appear to need one (closed-driver paths
  catch the bus loss via different mechanisms unrelated to
  PMC_BOOT_0 polling).
- Related reviews: [[A1-pcie-primitives]] (foundation that A2
  embeds the snapshot struct from; A2's frontmatter
  `related-patches:` includes it because the intent file
  exists on disk and Rule 6 resolves). [[A3-recovery]] (the
  consumer of A2's latched state — A3 reads
  `nvl->qwd->last_aer` for recovery decisions; A3's review
  will resolve D1's call-site ownership question).
  [[A4-close-path-telemetry]] (complementary observability
  surface; close-path events that fire during the same
  episode as a Q-watchdog detection are correlated via
  `dmesg` timestamps and the per-event `event=` tag in A1's
  dump). [[C5-crash-safety]] (the consumer of A2's
  disconnect propagation — `os_pci_set_disconnected` is
  defined by C5; A2 is the call-site that triggers it from
  the watchdog context). The frontmatter
  `related-patches: [A1-pcie-primitives]` lists only A1
  because A3 / A4 / C5 are referenced via body prose
  `[[...]]` wikilinks; per the C1 checkpoint convention,
  related-patches frontmatter is conservative (Rule 6
  resolution), and Task 14's cross-patch audit will backfill
  symmetrically.
- Carve provenance:
  `docs/superpowers/specs/2026-05-22-addon-recarve-design.md`
  — §"Carve approach" describes A2's split from legacy
  cluster P3 (`patches/legacy/0003-tb-egpu-qwatchdog.patch`)
  as reconciliation against the newly-carved A1 foundation
  rather than a redesign. A2's behaviour is unchanged from
  P3; only the struct declaration moved (from A2's header
  to A1's header).
