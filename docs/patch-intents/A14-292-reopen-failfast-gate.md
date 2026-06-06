---
id: A14-292-reopen-failfast-gate
layer: addon
source-branch: a14-292-reopen-failfast-gate
upstream-candidacy: n/a
telemetry-tier: mandatory
status: designed
related-patches: [C7-292-inflight-deadbus-poll-coverage, A13-292-inflight-aer-earlyfree, A3-recovery]
---

# A14-292-reopen-failfast-gate — Fix-Bar1 Sticky-Bit Re-open Fail-Fast Gate (Defense-in-Depth for #292)

## Purpose

The driver SHALL refuse — returning `-EIO` (the `NV_STATUS` equivalent on the
dynpower path) **before any GSP bring-up**, entering **zero** GSP poll-sites and
queuing **no** bootstrap worker — a persistence-OFF re-open of a #979-EQ-diverged,
fix-bar1-recovered, WPR2-torn-down external GPU. This converts the #292 in-flight
re-open wedge (a multi-second silent host hard-lock; the foreground parks in
`wait_for_completion_timeout` holding `nvl->ldata_lock` across `flush_work` while
the worker storms a dead bus) into an instant, logged, recoverable refusal for the
known production substrate. The gate SHALL ship **WITH** [[C7-292-inflight-deadbus-poll-coverage]]
(the load-bearing read-only dead-bus poll-reader), **never instead of it**: because
divergence is **driver-invisible in the live case** (PMC_BOOT_0=0x1b2000a1, WPR2 up,
LnkSta Gen3 x4 all read healthy; Phy16Sta.EquComplete is endpoint-only under TB
register virtualization), the predicate is **PROBABILISTIC** — it is structurally
blind to a novel divergence with no prior fix-bar1 run — and MUST NOT be treated as
the completeness guarantee for #292. The persistent capability granted: a
deterministic, retire-able A-series first line of defense that fails fast for the
substrate the host has already recovered once.

## Mechanism + placement (the build spec, apnex.32)

- **State (per-device, lock-free).** `nv-linux.h` `nv_linux_state_t` (~1462, beside
  `bootstrap_in_flight`): add `atomic_t diverged_recovered;` + `atomic_t
  reopen_gsp_torndown;`. kzalloc-zero-init at `nv_pci_probe`; destroyed with `nvl`
  at `nv_pci_remove`. This lifecycle **is** the structural false-positive guard — a
  fresh enumeration (fix-bar1 slot power-cycle) re-creates `nvl` with both bits clear.
- **Divergence predicate (three lock-free conjuncts):**
  `nv->is_external_gpu && atomic_read(&nvl->diverged_recovered) && atomic_read(&nvl->reopen_gsp_torndown)`.
- **Gate placement (BOTH funnels).** `nv.c` at the TOP of `nv_bootstrap_bounded`
  (~1904, **before** the feature gates and **before** `atomic_set(&nvl->bootstrap_in_flight, 1)`)
  AND `nv_dynpower_bounded` (before its own `queue_work`, ~2117): predicate TRUE →
  log + `return -EIO`. Placing it ahead of the `bootstrap_in_flight` set leaves the
  flag 0 on a refused open, so [[A13-292-inflight-aer-earlyfree]]'s AER early-free
  branch stays correct.
- **Asserting `diverged_recovered` (out-of-band).** `nv-tb-egpu-recover.c` sysfs:
  write-only `DEVICE_ATTR(tb_egpu_diverged_recovered, 0200, NULL, store)` →
  `kstrtoul` + `atomic_set`. Driven by `tools/fix-bar1.sh --bind` after persistence
  engage. Optional read-only `DEVICE_ATTR(tb_egpu_reopen_blocked, 0444, show)`
  returning `diverged_recovered && reopen_gsp_torndown` so orchestration can
  distinguish an A14 `-EIO` from any other `-EIO`.
- **Arming `reopen_gsp_torndown`.** `nv-tb-egpu-close.c` last-close block (~155): when
  `is_last_close && atomic_read(&nvl->diverged_recovered)`, do one **passive** WPR2
  read (the chip is still alive at last-close — capture-confirmed n=2: netcon2 L878,
  netcon3 L682 both `WPR2=0x00000000`); if cleared, `atomic_set(&nvl->reopen_gsp_torndown, 1)`.
  Reaching the post-`nv_shutdown_adapter` persistence-OFF site (nv.c:2668) is itself
  the GSP-teardown signal; the WPR2 read corroborates the conjunct.

## Requirements

### Requirement: Refuse the diverged-recovered re-open before GSP bringup in BOTH funnels

When the three-conjunct lock-free predicate is TRUE, the driver SHALL return `-EIO`
(or the `NV_STATUS` equivalent on the dynpower path) at the TOP of **both**
`nv_bootstrap_bounded` and `nv_dynpower_bounded`, **before** the feature gates and
**before** `atomic_set(&nvl->bootstrap_in_flight, 1)` / `queue_work`. On refusal the
driver MUST queue no worker, enter no GSP poll, and run no `flush_work`. When the
predicate is FALSE the path MUST be byte-identical to the deployed behaviour (a pure
no-op on a healthy bus).

#### Scenario: persistence-OFF re-open of a fix-bar1-recovered diverged chip — open funnel
- **GIVEN** an external GPU whose `diverged_recovered` was asserted by `fix-bar1 --bind` and whose `reopen_gsp_torndown` was armed at a WPR2-cleared last-close
- **WHEN** a subsequent open enters `nv_bootstrap_bounded`
- **THEN** the gate MUST `return -EIO` before `atomic_set(&nvl->bootstrap_in_flight, 1)`
- **AND** no GSP poll-site (#1-#13) MUST be entered and no bootstrap worker MUST be queued (no `flush_work`, no `ldata_lock` hold across a stuck worker, no host wedge).

#### Scenario: dynpower (RTD3/GC6) resume of the same chip — second funnel
- **GIVEN** the same diverged-recovered, WPR2-torndown external GPU is idled to GC6/RTD3 and then touched
- **WHEN** the resume enters `nv_dynpower_bounded`
- **THEN** the gate MUST refuse before that funnel's `queue_work`, returning the `NV_STATUS` equivalent
- **AND** the dynpower re-bringup MUST NOT reach any GSP poll (closes the second-funnel exposure that GAP-1 left open for marker-only fixes).

#### Scenario: clean cold-plug — gate inert
- **GIVEN** a freshly cold-plugged external GPU (`diverged_recovered = 0` from kzalloc; fix-bar1 never ran)
- **WHEN** the open enters `nv_bootstrap_bounded`
- **THEN** the predicate MUST be FALSE and the path MUST be byte-identical to the deployed driver (BAR1 32 GiB bringup succeeds, no new log line).

### Requirement: The divergence bits are sticky on nvl and self-clear on re-enumeration

The `diverged_recovered` and `reopen_gsp_torndown` bits SHALL be per-device atomics
living on `nvl`, kzalloc-zero-init at `nv_pci_probe` and destroyed with `nvl` at
`nv_pci_remove`. `diverged_recovered` MUST be set only out-of-band by the userspace
fix-bar1 sysfs write; `reopen_gsp_torndown` MUST be armed only in the last-close path
when `is_last_close && diverged_recovered` AND a passive WPR2 read confirms WPR2=0. A
fresh enumeration (fix-bar1 slot power-cycle) MUST yield a fresh `nvl` with both bits
cleared — the structural false-positive guard.

#### Scenario: fix-bar1 --bind asserts the divergence bit
- **GIVEN** a chip the orchestration recovered via `fix-bar1 --bind`
- **WHEN** the script writes `1` to `/sys/bus/pci/devices/$GPU/tb_egpu_diverged_recovered` after persistence engage
- **THEN** `atomic_set(&nvl->diverged_recovered, 1)` MUST take effect on that `nvl`.

#### Scenario: last-close with cleared WPR2 arms the teardown bit
- **GIVEN** a `diverged_recovered` external GPU reaching its persistence-OFF last-close after `nv_shutdown_adapter`
- **WHEN** the last-close passive WPR2 read returns `0x00000000`
- **THEN** `atomic_set(&nvl->reopen_gsp_torndown, 1)` MUST arm the conjunct (so the next re-open is refused).

#### Scenario: cold-recover via fix-bar1 clears both bits
- **GIVEN** an A14 `-EIO` was returned to userspace
- **WHEN** `fix-bar1 --bind` slot-cycles the device → `nv_pci_remove` frees the old `nvl` and `nv_pci_probe` kzallocs a fresh one
- **THEN** both bits MUST read 0 and a clean re-bringup MUST proceed (the documented `-EIO = cold-recover` contract).

### Requirement: The sysfs assertion surface MUST work with NVreg_TbEgpuRecoverEnable=0

The `tb_egpu_diverged_recovered` (0200) and optional `tb_egpu_reopen_blocked` (0444)
attributes SHALL be registered in an **always-on** attr group created in
`nv_pci_probe` and removed in `nv_pci_remove` **before** `nvl` is freed — and MUST
NOT be placed in the `Enable`-gated `tb_egpu_recover_attr_group` (recover.c:803-810,
created only when `NVreg_TbEgpuRecoverEnable != 0`; the live production default is 0).
The bits live on `nvl` and the gate SHALL operate independently of the recover module.

#### Scenario: Recover-disabled host still exposes and honors the gate
- **GIVEN** a host booted with `NVreg_TbEgpuRecoverEnable=0`
- **WHEN** `fix-bar1` writes the sysfs node and a diverged-recovered re-open is attempted
- **THEN** the sysfs nodes MUST be present and writable AND the gate MUST still return `-EIO` (its operation MUST NOT depend on the recover module being enabled).

### Requirement: The gate is PROBABILISTIC and never the #292 completeness guarantee

The gate SHALL ship alongside [[C7-292-inflight-deadbus-poll-coverage]] and MUST NOT
be elevated to the sole fix for #292. Its false-negative on a novel divergence (a
first-time-diverged chip with no prior fix-bar1 run → bits clear → worker queued)
MUST be documented in-code so no future reviewer treats the gate as complete. C7
(the read-only dead-bus poll-reader at the two engine chokepoints + three hand-rolled
loops) MUST remain the load-bearing layer that contains any divergence the gate misses.

#### Scenario: novel divergence with no fix-bar1 history — gate inert, C7 catches it
- **GIVEN** a chip diverging for the first time (no `fix-bar1 --bind` ever ran → `diverged_recovered = 0`)
- **WHEN** the re-open enters the bringup funnel and proceeds into a GSP poll on the now-dead bus
- **THEN** the A14 gate MUST be inert (predicate FALSE) AND C7's `osIsGpuBusLost` poll-readers MUST self-terminate the worker so the host survives regardless.

## Scope boundary

- Does NOT detect divergence — divergence is driver-invisible live; the gate relies
  entirely on the userspace `fix-bar1` sticky assertion plus the passive last-close
  WPR2 corroboration. It is a memoiser of "this exact chip wedged its re-open once,"
  not a divergence sensor.
- Does NOT fix the in-flight bringup wedge — that is [[C7-292-inflight-deadbus-poll-coverage]]
  (read-only poll-reader). A14 only prevents *entering* the polls for the known substrate.
- Does NOT cover a novel / first-time divergence with no fix-bar1 history — false-negative
  by construction (GAP-8). C7 is the safety net; A14 is the fast path.
- Does NOT refuse the WPR2 fast-fail substrate (R2): a fast-fail re-open has a **live**
  bus and [[A10-f40b-lockfree-sink]]'s grace arm skips the dead-bus marker (chip NOT
  sunk) — `reopen_gsp_torndown` is armed only on a confirmed WPR2-cleared GSP-teardown,
  so the gate stays inert and the fast-fail remains contained, not refused.
- Does NOT touch persistence-ON open/close/re-open — WPR2 is not cleared there, so
  `reopen_gsp_torndown` never arms and the gate is inert.
- Out-of-scope for upstreaming — A-series, project-local, retire-able once a
  driver-visible divergence proxy or an upstream surprise-removal fix lands.

## Telemetry contract

| Event | Level | Format |
|---|---|---|
| gate fires (re-open refused) | `NV_DBG_ERRORS` | `"NVRM: tb_egpu [A14]: refusing re-open of diverged-recovered eGPU (WPR2-torndown) before GSP bringup -> -EIO (#292); cold-recover via fix-bar1\n"` |
| `reopen_gsp_torndown` armed at last-close | `NV_DBG_SETUP` | `"NVRM: tb_egpu [A14]: diverged-recovered eGPU last-close, WPR2=0x%08x cleared -> arming reopen-failfast\n"` |
| `tb_egpu_reopen_blocked` sysfs read | n/a (sysfs) | `0444` show returns `diverged_recovered && reopen_gsp_torndown` (1/0) so orchestration distinguishes an A14 `-EIO` from any other `-EIO` |

Tier `mandatory`: the refusal is otherwise an indistinguishable `-EIO` — without the
log line and the `tb_egpu_reopen_blocked` node, an A14 gate-fire is invisible to
both the operator and the orchestration.

## Validation

- **Compile, not `git apply --check`** (the P5 lesson): real `make modules` of the
  composed C+E+A+C7 tree against the live `7.0.9-fc44` kernel.
- **(b) Primary repro, n≥3** — exact apnex.31 Stage-5 sequence (`fix-bar1 --bind` the
  32 GiB-diverged chip → engage then DISABLE persistence → re-open `nvidia-smi -L`):
  with the bit asserted, the open MUST `-EIO` instantly with **zero** AER/`_kgspRpcRecvPoll`/
  "Bad TimeLo" lines and the host alive. Plus the GAP-1 runtime-PM repro (idle →
  GC6/RTD3 → touch → resume) to confirm the dynpower-funnel gate fires.
- **(c) Recover-disabled control** — repeat with `NVreg_TbEgpuRecoverEnable=0`:
  confirm (i) C7 still frees a worker on an un-gated path, (ii) the A14 sysfs nodes
  are present + writable (always-on attr group), (iii) `fix-bar1` still asserts
  `diverged_recovered`.
- **(d) No-regression, each n≥3** — clean cold-plug (gate inert, byte-identical
  bringup); fix-bar1-first-open (`reopen_gsp_torndown` not yet armed → not refused);
  persistence-ON open/close/re-open (WPR2 not cleared → inert); R2 WPR2 fast-fail
  still contained, not refused.
- **Userspace contract** — after an A14 `-EIO`, `fix-bar1 --bind` (slot-cycle) →
  fresh `nvl` → bits clear → re-bringup succeeds. The `tools/fix-bar1.sh` header
  "Known hazards" documents this `-EIO = cold-recover` loop.
- A14 ships validated as defense-in-depth; the load-bearing #292 survival proof is
  C7's dual-loglevel, every-poll-short-circuited test, not the gate.

## Provenance

- **Source cluster:** A-series addon (project-local), part of the #292 redesign
  triad C7 + A13' + A14 (post-A13 live-FAIL, apnex.31, 2026-06-06).
- **Vanilla baseline:** `kernel-open/nvidia/nv.c` (`nv_bootstrap_bounded` ~1904,
  `nv_dynpower_bounded` ~2094-2117); `kernel-open/common/inc/nv-linux.h`
  (`nv_linux_state_t` ~1462); `kernel-open/nvidia/nv-tb-egpu-close.c` last-close (~155);
  `kernel-open/nvidia/nv-tb-egpu-recover.c` sysfs (~735/774; the `Enable`-gated
  `tb_egpu_recover_attr_group` at recover.c:803-810 is **deliberately not** used);
  injector-repo `tools/fix-bar1.sh` (`--bind` block).
- **Fork branch:** `a14-292-reopen-failfast-gate` on `apnex/open-gpu-kernel-modules`
  (carved as `patches/addon/A14-292-reopen-failfast-gate.patch`). Build target `apnex.32`.
- **Ordering / composition:** Gate sits **before** `atomic_set(&nvl->bootstrap_in_flight, 1)`
  so a refused open leaves [[A13-292-inflight-aer-earlyfree]]'s flag at 0 and its AER
  branch correct. Load-bearing partner is [[C7-292-inflight-deadbus-poll-coverage]]
  (read-only dead-bus poll-reader); marker source / dynpower-funnel arm / lock-model
  comment are A13'. Recovery-on-`-EIO` is the [[A3-recovery]] / `fix-bar1` lane.
  Independent of [[C5-crash-safety]] / [[C6-cond-acquire-rwlock-fix]] (the F44
  `COND_ACQUIRE` fix is NOT weakened anywhere on this path).
- **Design-of-record:** `docs/missions/mission-1-egpu-hot-plug-hot-power/design-2026-06-06-292-redesign-C7-A13prime-A14.md`
  (§2.1 composition, §2.2 rejects C' as the sole fix, §3 A14 patch plan, §4 no-regression,
  GAP-8); live-FAIL finding `docs/missions/mission-1-egpu-hot-plug-hot-power/finding-2026-06-06-A13-live-FAIL-rpcpoll-wedge.md`.
- **Upstream issue:** https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979 —
  n/a for upstreaming (addon; retire-able workaround, not a driver-core fix).
</content>
</invoke>
