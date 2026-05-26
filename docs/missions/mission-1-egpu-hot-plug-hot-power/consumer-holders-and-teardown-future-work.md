# Consumer holders and teardown — observed gaps + future work

**Status:** v1 2026-05-26 — captured during aorus.16 deployment work
**Purpose:** Document the recurring pattern of GPU consumers (NVIDIA k8s-device-plugin, persistence mode, vLLM, others) preventing both graceful AND forced teardown of the nvidia.ko driver. Articulate the gap in our injector tooling and the future-work items needed to close it.
**Trigger:** Caught during aorus.16 deployment when the in-place `entrypoint.sh uninstall` was blocked by `/dev/nvidia-uvm` holders, and the NVIDIA device-plugin DaemonSet auto-respawned within 6 seconds of pod deletion (cordon bypassed). Same pattern observed in E07 Run 2 wedge mechanics.

## The pattern

Both graceful and forced teardown paths can be defeated by active GPU consumers:

| Teardown path | What fails when consumers hold the driver |
|---|---|
| **Graceful** (`entrypoint.sh uninstall`) | Refuses to `rmmod` at the fuser/refcnt gate. By design — `rmmod` of a busy module would EBUSY. |
| **Forced** (cable yank, surprise removal) | Xid 79 → Xid 154 cascade fires through active code paths. Hits assertions C5 doesn't cover. Wedges host. (E07 Run 2 forensic record.) |

These are two sides of the same coin: **any reliable teardown procedure must first quiesce all consumers**. We've hit this repeatedly:

1. **E07 Run 2 (2026-05-26 18:08:45)** — cable yank while device-plugin + persistence holding driver → Xid 154 cascade → silent wedge → forced reboot
2. **aorus.15 → .16 deployment (2026-05-26 22:13)** — in-place `uninstall` blocked by device-plugin holders; cordon defeated by DaemonSet auto-respawn; fell back to second reboot
3. **E11 Run 1 (2026-05-26)** — software-initiated remove SUCCEEDED because `pci_remove` is a graceful kernel-driven path that handles the disconnect-during-active-session without firing Xid 154. This is the existence proof that holder-tolerant teardown is possible at the kernel layer.

## Specific holders observed on this host

| Holder | Refcount contribution | Quiesce mechanism |
|---|---|---|
| NVIDIA k8s-device-plugin (NVML probes ~30s cadence) | `nvidia_uvm` +1-2 per probe | Stop the DaemonSet's pod scheduling on the target node |
| Persistence mode (`nvidia-smi -pm 1`) | `nvidia` +1 | `nvidia-smi -pm 0` |
| vLLM CUDA workload | `nvidia` + `nvidia_uvm` + others | `kubectl scale deployment vllm --replicas=0` (or equivalent) |
| PC-3 heartbeat | reads `/sys/module/nvidia/version` — no fd held | Implicit when injector pod is gone |
| Future: other GPU users (Ollama, fabric manager, X server) | varies | Per-application |

Current refcount during normal operation: `nvidia=6, nvidia_uvm=4`. These represent the steady-state baseline that any teardown procedure must drive to zero (or 1, the bare module reference) before `rmmod` can proceed.

## The gap in current injector tooling

`entrypoint.sh uninstall` and `entrypoint.sh purge` (per `docs/teardown-workflow.md`) handle the rmmod sequence correctly but **assume the operator has already quiesced consumers**. The docs say "If the refusal in step 3 fires (active consumers), stop those first" — but provide only a discovery command (`jq` filter for `runtimeClassName=="nvidia"` pods), not a quiesce procedure.

Specifically MISSING:

1. **No `quiesce` subcommand** to drain consumers as a pre-rmmod step
2. **No k8s-aware orchestration** that handles the device-plugin's DaemonSet behavior (auto-respawn defeats simple `kubectl delete pod`, cordon bypass observed)
3. **No automatic detection** of WHICH consumers are holding what — operator must investigate manually
4. **No `unquiesce` / `resume`** to restore the cluster after maintenance
5. **No coordination with the cable-yank Recipe A** in `_STARTING-STATE-RECIPE.md` (which also needs the quiesce step, but documents it as a manual 6-step procedure)

## Future work items

### Q1 — `quiesce.sh` / `unquiesce.sh` tools in `tools/`

Two new shell scripts, sibling to `must-gather.sh`:

**`tools/quiesce.sh`**:
1. Enumerate current GPU consumers (kubectl-driven for k8s consumers; ps/lsof for host-side)
2. Drain vLLM workload (`kubectl scale vllm/* --replicas=0`)
3. Drain device-plugin DaemonSet via nodeSelector patch (NOT cordon — empirically defeats auto-respawn)
4. Disengage persistence (`nvidia-smi -pm 0`)
5. Optionally: kill nvidia-persistenced if running standalone
6. Verify `lsof /dev/nvidia*` empty + refcounts at baseline (1 for module-loaded reference)
7. Return only when quiesce verified; exit non-zero if can't reach quiesce state

**`tools/unquiesce.sh`**:
1. Revert device-plugin nodeSelector patch
2. Re-engage persistence (`nvidia-smi -pm 1`)
3. Scale vLLM back (if previously running)
4. Verify pods come back ready

Both scripts idempotent; both produce structured logs for incident response.

### Q2 — `entrypoint.sh quiesce` subcommand (alternative)

Same logic as Q1's `quiesce.sh` but as an in-container subcommand. Pros: consistent with `uninstall` / `purge` shape. Cons: needs cluster API access from the container (which it already has via SA token).

### Q3 — `entrypoint.sh uninstall --quiesce` flag (composition)

Compose Q1/Q2 into uninstall as an optional pre-step: `uninstall --quiesce` = quiesce + uninstall + (optionally) unquiesce on a successful re-load later.

### Q4 — Update `_STARTING-STATE-RECIPE.md` Recipe A

Replace the manual 6-step Section D quiesce procedure with `tools/quiesce.sh` invocation. Same for the cable-yank protocol's pre-condition section. This unifies cable-yank-testing safety with software-uninstall safety: both call the same primitive.

### Q5 — Document the auto-respawn observations

The cordon-vs-DaemonSet-tolerations interaction, and the timing observations (6-second respawn window), belong in the architecture docs so future maintainers understand WHY `tools/quiesce.sh` uses nodeSelector patching rather than cordon.

## Relationship to MISSION-1 corrective patches

The quiesce-tooling work is **complementary, not redundant**, with the C5 v3 driver patches:

- **C5 v3 (driver-side)** — graceful tear-down when surprise-removal happens despite holders. Prevents wedge cascade.
- **Quiesce tooling (cluster-side)** — quiesces holders so surprise-removal happens WITHOUT active driver session. Prevents the cascade from firing in the first place.

Both together = belt-and-suspenders. Either alone is incomplete:
- C5 v3 alone — wedge prevented but RPC errors may still surface; testing still needs careful coordination
- Quiesce alone — no protection against unexpected disconnect (where you can't pre-quiesce, like genuine cable yank by a human)

The quiesce tools are explicitly cluster-side operational hardening, NOT a substitute for the C5 driver fix.

## Estimated priority

Medium. The C5 v3 work is the higher-priority MISSION-1 deliverable; once it lands and we verify wedge-free cable-yank behavior, the quiesce tooling becomes a separate cluster-ops improvement track. Not a blocker for Phase 2.1/2.2 experiments which (after C5 v3) can use cable-yank directly without needing quiesce.

## Cross-references

- `nvidia-driver-surprise-removal-audit.md` — the driver-side audit that identified the C5 v3 patch scope
- `c3-c5-integration-audit.md` — the patch placement decision
- `userspace-reset-recover-survey.md` — survey of available reset/recover primitives (precursor to quiesce design)
- `experiments/_STARTING-STATE-RECIPE.md` Recipe A — current manual quiesce procedure (to be replaced by Q1/Q4)
- `experiments/E07-cable-replug-drain-first.md` — wedge forensic record (the failure pattern these tools prevent)
- `experiments/E11-per-function-remove.md` — kernel-side graceful path (the existence proof for safe holder-tolerant teardown)
- `docs/teardown-workflow.md` — current uninstall/purge documentation
