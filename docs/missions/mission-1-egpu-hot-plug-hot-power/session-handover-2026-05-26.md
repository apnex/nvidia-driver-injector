# MISSION-1 session handover — 2026-05-26

**Purpose:** Complete state snapshot for a fresh session to resume MISSION-1 work without context loss.

## TL;DR — what to know walking in

1. **The next concrete action is a source audit**, not code work. See `decision-architecture-class-localization.md` Step 1.
2. **C5 v3 is `partial-v3-needs-v4-architectural`** — landed, but cable-yank rewedged the host. Patches stay in place; they're partial coverage of a broader failure class.
3. **The v4 architectural commitment (Option 1 Core vs Option 2 Addon) is pending the audit** — don't start v4 code until the audit answers the binary question.
4. **Phase 2.1/2.2 experiments remain blocked** on safe broken-BAR1 production, which requires the wedge fix to land. Phase 2.3 (cmdline) is partly done (E18, E19); rest of Section 3 (E20, E21, E22, E24) can proceed independently if desired.
5. **No active reboots needed**. Host is healthy on aorus.16 with cold-plug BAR1=32GiB. Pods 1/1.

## Current host + cluster state

```
Driver:                    595.71.05-aorus.16 (C5 v1+v3 patches loaded; v3 is partial coverage)
BAR1:                      32 GiB (cold-plug)
Bridge 03:00.0 prefetch:   33089M
nvbandwidth:               2.83 / 3.29 / 2.71 GB/s (parity confirmed against original aorus.14 baseline)
Cmdline:                   pci=realloc=on,hpmmioprefsize=32G,resource_alignment=35@0000:03:00.0
TB tunnel:                 authorized (auto by boltd at cold boot)
nvidia-driver-injector:    zrdh6, 1/1 ready
nvidia-device-plugin:      4vrdx, 1/1 ready
vLLM:                      drained (no pods in vllm namespace)
```

## Session events — chronological

| Time (UTC) | Event |
|---|---|
| morning | Inherited from prior session: aorus.14 driver running, BAR1 reporting bug (`bar1_size_gib:0` in PC-3 state file) |
| ~07:00 | Fixed bar1_size_gib bug (mawk strtonum gotcha → bash arithmetic), bumped A5 to aorus.15, container rebuild + deploy. New memory `feedback_mawk_no_strtonum_in_containers` |
| ~07:45 | Discovered v15 image vs driver-version split; force-reboot resolved to load .15 module fresh |
| ~08:00 | Mission-1 forensic docs reorganized: relocated 28 docs + tools from k8s-vllm to nvidia-driver-injector repo (`docs/missions/mission-1-egpu-hot-plug-hot-power/`) |
| ~08:30 | E07 Run 2: cable yank under aorus.15 caused silent host wedge ~3 min post-yank. Forensic audit + memory `feedback_surprise_removal_wedge_class_2026_05_26` |
| ~09:00 | nvidia-driver-surprise-removal-audit doc + userspace-reset-recover-survey doc landed |
| ~10:00 | Continued Phase 2.3 cmdline experiments: E18 (`pci=realloc=on`) Phase A PASS; E19 (`hpmmioprefsize=32G`) NO-OP at cold-plug |
| ~10:30 | User pushback on E19 overreach ("eliminates cmdline mitigation lane"); pci-cmdline-audit landed; memory `feedback_single_datapoint_inferential_overreach_2026_05_26` |
| ~11:00 | c3-c5-integration-audit identified 8-site sweep + 2 new macro variants for C5 v3 |
| ~11:30 | c5-intent-amendments-draft + C5 v3 docs (intent + review + improvements) landed |
| ~12:00 | C5 v3 fork-branch source work: c5 amended (1a7f39ab), a1-a5 cascade-rebased, a5 bumped to aorus.16, force-pushed |
| ~12:15 | aorus.16 container built + imported to k3s containerd; first reboot for deploy didn't roll pod (OnDelete + spec lag); 2nd reboot landed clean |
| ~12:30 | aorus.16 deploy verified: driver=aorus.16, node label=aorus.16, nvbandwidth parity OK |
| ~12:33 | **E07 Run 3 cable yank under aorus.16: REWEDGED.** v3 macros fired correctly for 2 sites but 3 OTHER sites fired uncovered. 2 reboots to recover |
| ~12:40 | Deep investigation: confirmed boltctl autopilot (no manual auth ran); confirmed 3 new assertion sites; classified as different patterns/classes |
| ~12:50 | Architectural redirection design doc landed; C5 status flipped to `partial-v3-needs-v4-architectural` |
| ~13:00 | User reframed: pick clean extreme (Option 1 Core vs Option 2 Addon); decision-architecture-class-localization doc + this handover doc |

## Commits landed today (in order)

| SHA | Repo | Subject |
|---|---|---|
| `0115160` (from yesterday) | injector | Previous session's tip |
| `59dd068` | injector | fix(entrypoint+A5): bash-native bar1 sizing + bump driver to aorus.15 |
| `4f11385` | injector | chore(k8s): bump injector image tag to 595.71.05-aorus.15 |
| `c752906` | injector | (k8s-vllm-side cleanup commits omitted; see k8s-vllm git log) |
| `80f5878` | injector | docs(E07): add forensic bundle reference + must-gather provenance |
| `b8a6238` | k8s-vllm | docs+tools: relocate MISSION-1 investigation to apnex/nvidia-driver-injector |
| `2909b97` | injector | docs+tools: centralise MISSION-1 investigation in this repo |
| `57e4939` | injector | docs(E11): Run 1 forensic record — Recipe B SAFE confirmed |
| `8862673` | injector | docs(E11): close link-degradation follow-up — no degradation |
| `981fc54` | injector | docs(E18): Run 1 forensic record — Phase A PASS, Phase B BLOCKED |
| `134ba47` | injector | docs(E19+E27): hpmmioprefsize=32G is no-op; patch must re-attempt, not hint |
| `f6b3c8c` | injector | docs(E27+E18): capture I/O-vs-prefetchable realloc asymmetry as patch design directive |
| `fa99a71` | injector | docs(E19+E27): retract over-claim — single no-op datapoint doesn't eliminate cmdline lane |
| `df80372` | injector | docs(audit): PCI cmdline knob audit — runtime hot-plug allocation path |
| `9b7ccb1` | injector | docs(audit): C3+C5 integration audit for P-DISC-1/2 |
| `ed6f2e0` | injector | docs(amendments-draft): C5 intent amendments draft for review |
| `842d4a1` | injector | docs(C5): v3 amendments — cross-layer propagation + macro family + 8-site application |
| `1a4cf5a` | injector | patches: C5 v3 + A5 aorus.16 — regen from new fork-branch tips |
| `e9861f3` | injector | (amend of 1a4cf5a, force-pushed) — added comment-line k8s/daemonset.yaml polish |
| `48223c7` | injector | chore(k8s): finish aorus.15 → aorus.16 substitution in comment line |
| `bbc4142` | injector | docs(mission-1): consumer holders block both teardown paths — future-work tracker |
| `7666cf3` | injector | docs(mission-1): E07 Run 3 wedge forensics + C5 v3 partial retraction + v4 architectural design |
| (current) | injector | docs(mission-1): decision-architecture-class-localization + session-handover |

Also fork branches force-pushed (carve-out applied):
`c5-crash-safety` → `1a7f39ab`, `a1-pcie-primitives` → `4f5e39e6`, `a2-bus-loss-watchdog` → `38f54569`, `a3-recovery` → `e396e0c8`, `a4-close-path-telemetry` → `4e4befea`, `a5-version-and-toggles` → `39169b01`

## Experiment results today

| Experiment | Result | Forensic |
|---|---|---|
| E07 Run 2 (aorus.14, cable yank) | WEDGE | `/var/log/mission-1-archaeology/E07-Run2-wedge/...WITH-WEDGE.tar.gz` |
| E11 Run 1 (software remove) | Recipe B SAFE; BAR1 preserved | `/var/log/mission-1-archaeology/E11-Run1-software-remove/` |
| E18 Run 1 (`pci=realloc=on`) | Phase A PASS, Phase B BLOCKED, I/O windows widened | `/var/log/mission-1-archaeology/E18-Run1/` |
| E19 Run 1 (`hpmmioprefsize=32G`) | NO-OP at cold-plug; "eliminates cmdline lane" retracted | `/var/log/mission-1-archaeology/E19-Run1/` |
| E07 Run 3 (aorus.16, cable yank) | REWEDGE — v3 partial coverage proven incomplete | `/var/log/mission-1-archaeology/E07-Run3-aorus16/` |

## Documents added/updated today (mission-1 directory)

```
docs/missions/mission-1-egpu-hot-plug-hot-power/
├── README.md                                          (existing)
├── mission.md                                         (existing)
├── matrix.md                                          (existing)
├── pci-cmdline-audit.md                               NEW today
├── nvidia-driver-surprise-removal-audit.md            NEW today
├── userspace-reset-recover-survey.md                  NEW today
├── c3-c5-integration-audit.md                         NEW today
├── c5-intent-amendments-draft.md                      NEW today
├── consumer-holders-and-teardown-future-work.md       NEW today
├── architectural-funnel-redirection-design.md         NEW today (now superseded by decision doc)
├── decision-architecture-class-localization.md        NEW (this commit) — the canonical Option 1 vs 2 doc
├── session-handover-2026-05-26.md                     NEW (this commit) — this doc
└── experiments/
    ├── E07-cable-replug-drain-first.md                +Run 3 section
    ├── E11-per-function-remove.md                     +Run 1
    ├── E18-cmdline-realloc-on.md                      +Run 1
    └── E19-cmdline-hpmmioprefsize.md                  +Run 1
```

## Key memories added today

(All in `/root/.claude/projects/-root/memory/`, indexed in `MEMORY.md`)

- `feedback_mawk_no_strtonum_in_containers` — shell portability for container scripts
- `feedback_jq_compact_output_gotcha` (existing) — jq compact JSON for grep consumers
- `feedback_surprise_removal_wedge_class_2026_05_26` — E07 Run 2 wedge mechanism
- `feedback_io_vs_prefetchable_realloc_asymmetry_2026_05_26` — E27 design implication
- `feedback_single_datapoint_inferential_overreach_2026_05_26` — first overreach
- `feedback_gpu_consumer_holders_block_teardown_2026_05_26` — quiesce tooling future work
- `feedback_premature_success_overreach_pattern_2026_05_26` — three overreaches, discipline
- `feedback_funnel_vs_per_site_patching_2026_05_26` — architectural-vs-site decision criteria

## Outstanding work (clearly enumerated)

### Immediate next action — the source audit

Per `decision-architecture-class-localization.md` Step 1:

1. For each observed assertion site (osinit.c:2462, kern_fsp_gh100.c:649, gpu_user_shared_data.c:248, plus the 8 v3 covered sites), trace caller chains upstream
2. Determine for each: is the path TB-specific or general PCIe?
3. Cross-check with NVIDIA's open-driver issue tracker for similar reports on non-eGPU systems
4. Write up findings in `cascade-scope-audit.md`

Estimated effort: 4-8 hours focused source reading.

### Optional but valuable next action — cross-hardware empirical test

If a second host with a non-TB-attached RTX 5090 (direct PCIe x16) is available:

1. Deploy the same `apnex/nvidia-driver-injector:595.71.05-aorus.16` image
2. Capture baseline (get-pci-stats + must-gather)
3. Trigger PCIe surprise removal (software remove, bpftrace-induced pci_remove, etc.)
4. Observe whether the cascade fires
5. Compare to E07 Run 3 forensic record

This resolves the binary Option 1 vs Option 2 question with hardware evidence rather than source-only inference.

### After audit/test — pick option and plan v4 implementation

Once Option 1 or Option 2 is decided, write the v4 implementation plan and begin Phase 1 (TB-bus hook investigation for Option 2, or pci_remove callback work for Option 1).

### Independent track (can proceed in parallel) — Phase 2.3 cmdline experiments

E20 (`hpmmiosize=256M`), E21 (`hpmemsize=33G`), E22 (`pcie_aspm=off`), E24 (resource_alignment variants) can proceed. Each ~10 min reboot. Each will likely no-op like E19 did (per the pci-cmdline-audit prediction), but empirical confirmation is the discipline.

### Future-work tracker (lower priority)

- `tools/quiesce.sh` + `tools/unquiesce.sh` — per `consumer-holders-and-teardown-future-work.md`
- E27 PCI core patch design (BAR1 corrective) — blocked on broken-BAR1 producer, which blocks on v4
- Q-watchdog (A2) and recovery state machine (A3) updates if v4 architectural work surfaces gaps

## How to resume in a fresh session

1. Start by reading these two docs:
   - `docs/missions/mission-1-egpu-hot-plug-hot-power/decision-architecture-class-localization.md`
   - `docs/missions/mission-1-egpu-hot-plug-hot-power/session-handover-2026-05-26.md` (this doc)

2. Verify current host state:
   ```bash
   cat /sys/module/nvidia/version              # expect: 595.71.05-aorus.16
   kubectl get pods -n kube-system | grep nvidia # expect: both 1/1
   awk 'NR==2 {print (strtonum($2)-strtonum($1)+1)/1024/1024/1024" GiB"}' \
       /sys/bus/pci/devices/0000:04:00.0/resource # expect: 32 GiB (will work in gawk-equipped shells)
   ```
   (If on mawk like the container, use bash arithmetic — see memory `feedback_mawk_no_strtonum_in_containers`)

3. If the audit is the next step (default):
   - Begin with `osHandleGpuLost` callers and trace upstream
   - Then `osinit.c:2462`'s function
   - Then `kern_fsp_gh100.c:649`
   - Output to `cascade-scope-audit.md`

4. If the empirical test is the next step (user provides alternative hardware):
   - Reproduce the aorus.16 environment on the new system
   - Use the same get-pci-stats.sh + must-gather.sh tooling
   - Follow E07 Run 3 protocol for the trigger

## What NOT to do without explicit user direction

- Don't start v4 code work (Option 1 OR Option 2) until the audit lands
- Don't run cable-yank tests on the current host without quiesce protocol (Recipe A) — wedge risk remains
- Don't declare success on any iteration without verification-before-completion discipline (per `feedback_premature_success_overreach_pattern_2026_05_26`)
- Don't sweep-and-expand C5 v3 with broader regex — the iteration is converging too slowly; architectural pivot is the right move

## Open questions for next session

1. **Which option does the audit recommend?** Empirical question — answer comes from the audit.
2. **Is alternative hardware (non-TB 5090) accessible for cross-hardware testing?** User to confirm.
3. **Patch geometry within the chosen option:** if Option 1, extend C5 vs new C6; if Option 2, extend E1 vs new E2/A6.
4. **Upstream-PR timeline:** is the upstream filing in scope for next session, or stays in `feedback_no_premature_upstream_filing` parking?
5. **Phase 2.3 continuation:** run E20/E21/E22/E24 in parallel, or hold until v4 lands?

## Pointers to all today's docs (single index)

In `/root/nvidia-driver-injector/`:
- `docs/missions/mission-1-egpu-hot-plug-hot-power/` — mission directory
- `docs/patch-intents/C5-crash-safety.md` — C5 intent (v3 amendments)
- `docs/patch-reviews/C5-crash-safety.md` — C5 review (v3 deltas + v3→v4 retraction)
- `docs/patch-improvements/C5-crash-safety.md` — C5 improvement lineage (v3 row)
- `tools/get-pci-stats.sh` — per-experiment state capture
- `tools/must-gather.sh` — forensic bundle (now with -b -1 / -b -2 capture)

In `/var/log/mission-1-archaeology/`:
- All preserved forensic bundles + baseline/snapshot files
- Each experiment has its own subdirectory under this root

In `/root/.claude/projects/-root/memory/`:
- `MEMORY.md` — index of all memories (cross-session persistent)
- Individual memory files referenced from MEMORY.md

GitHub:
- `apnex/nvidia-driver-injector` — main repo
- `apnex/open-gpu-kernel-modules` — fork with stacked branches (c5-crash-safety → a1 → ... → a5)
- `apnex/k8s-vllm` — deployment / manifest repo
