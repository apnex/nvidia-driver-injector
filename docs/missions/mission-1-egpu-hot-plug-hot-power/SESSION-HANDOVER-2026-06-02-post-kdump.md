# Session handover — 2026-06-02 — post-kdump (READ FIRST after the reboot)

A kdump panic was triggered intentionally (`echo c > /proc/sysrq-trigger`) to
**capture a vmcore of a live RM-API rwsem deadlock AND recover the host** (the
deadlock was immune to FLR + TB unauth/reauth; reboot was genuinely required).
This was the productive reboot — the vmcore is the dataset for the fix design.

## Immediately after reboot — restore service
1. `RESTORE-AFTER-REBOOT-2026-06-02.txt` — un-drain the injector DS
   (`kubectl -n kube-system patch ds nvidia-driver-injector --type json -p
   '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'`), then verify
   the pod cold-boots clean and thermal engages. The injector DS was drained
   (`nodeSelector oa-drain=recovery-2026-06-02`) during the recovery attempt.
2. Expect a clean cold bringup (the failure was a STOCHASTIC H16 PCIe transient,
   not deterministic). If it fails again, that's a separate cold-bringup-reliability
   thread, not this deadlock.

## The deadlock (what the vmcore must confirm)
Full RCA: `wedge-2026-06-02-coldboot-apilock-deadlock.md`. Cycle mapped to one
unknown — the rwsem OWNER + its wait. Actors (stacks in `-stacks.txt`):
- `irq/121-pciehp` 151 — D, `nv_kthread_q_flush` (removal flush of nv_open_q)
- `nv_open_q` 169991 — D, `rmapiLockAcquire(WRITE)` via `rm_get_adapter_status_external` (deferred open)
- `nvidia-smi` 254369 — D, `rmapiLockAcquire(WRITE)` via `serverAllocResource`
- `nvidia-smi` 251420 — S, `nvidia_close` (do_exit) — HYPOTHESIZED lock owner, flush-waiting the worker

## Post-reboot analysis steps (vmcore)
1. `vmcore` is in `/var/crash/<ts>/`. Install tooling:
   `dnf debuginfo-install -y kernel-core-7.0.9-204.fc44.x86_64 && dnf install -y crash`
2. `crash /usr/lib/debug/lib/modules/7.0.9-204.fc44.x86_64/vmlinux /var/crash/<ts>/vmcore`
   - Load the preserved module symbols: `mod -s nvidia <path>/vmcore-symbols-2026-06-02/nvidia.ko`
   - `bt` the 4 actors; read the rwsem `owner`; walk the wait list → CONFIRM the cycle.
3. Then finalize **F45** in `/root/fake-5090/failure-modes/` (sibling of F44; see Q2
   in the RCA) and design the **hardened fix** (broader than A10 C1: covers the
   deferred-open acquire + close lock-ordering + the removal-path flush).

## Other in-flight work (do not lose)
- **A10-v2 surgical (task #293)** — SEPARATE from F45. The design workflow result is
  saved at `a10-v2-surgical-design-workflow-2026-06-02.json`. Adversarial review
  FALSIFIED the original race proof (relaxed GSP locking ON by default → worker does
  NOT hold the API lock across the lockdown poll). Revised v2 = gate BOTH C2 and C5
  on a worker-in-poll flag + a 150ms grace re-wait; A7 stays unconditional; C1 is the
  safety floor. NOT yet implemented. Confidence medium — re-derive the wedge mechanism
  given relaxed locking before cutting code.
- Firmware-symlink gotcha (task #294) — apnex.NN needs `/lib/firmware/nvidia/595.71.05-apnex.NN`.
- apnex.26 = A10-v1 (FLAWED: unconditional C2 permanently dead-buses on fast-fail).
  The clean deployed driver is apnex.25; expect the DS to rebuild it post-reboot.
