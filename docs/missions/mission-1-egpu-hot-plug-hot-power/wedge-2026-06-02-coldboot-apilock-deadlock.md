# Wedge RCA — 2026-06-02 — cold-bringup GSP-fail → RM API-lock deadlock (reboot-required)

**Class:** kernel rwsem deadlock on the RM API write-lock. Distinct from the
same-day `wedge-2026-06-02-lockdown-reopen-forensics.md` (F44 re-open lockdown).
**Outcome:** host responsive, GPU lost, **no runtime recovery possible → reboot.**

## How we got here
1. Validation left A10-v1 (apnex.26) loaded; GPU `No devices` because the module
   loaded before the apnex.26 GSP firmware symlink existed (see task #294).
   Firmware symlink created.
2. `nvidia-smi -L` (persistence off) did an init→clean-close → WPR2=0.
3. Injector pod restarted for a **cold** re-engage (`nvidia-smi -pm 1` first open).
4. Cold bringup hit an **H16-class PCIe transient on the TB bridge during GSP boot**:
   `pcieport 0000:03:00.0: AER: device recovery failed` + GSP heartbeat timeout
   (`_kgspRpcRecvPoll: GSP RM heartbeat timed out`, `SET_GUEST_SYSTEM_INFO failed 0xf`)
   → `RmInitAdapter failed (0x62:0xf:2131)` → C5 sink set (GPU declared lost).
   **Stochastic, unrelated to F44/A10.**

## The deadlock (sysrq-w / -t, saved in wedge-2026-06-02-coldboot-apilock-deadlock-{dmesg,stacks}.txt)
Three actors, circular wait on the RM API write-lock (rwsem):
- **`nv_open_q` kthread 169991** (the A6 deferred-open worker from the failed init):
  `nvidia_open_deferred → rm_get_adapter_status_external → rmapiLockAcquire`
  **blocked D-state in `rwsem_down_write_slowpath`.**
- **nvidia-smi 254369** (the stray verification open — should have stayed passive):
  `serverAllocResource → rmapiLockAcquire` blocked D-state on the same write-lock.
- **nvidia-smi 251420** (pod engage `-pm 1`, SIGKILL'd, in `do_exit`):
  stuck S-state in `nvidia_close`, cannot complete (waiting on the worker / lock).

`rm_get_adapter_status_external` + the close path taking a **blocking**
`rmapiLockAcquire` is exactly the lock-inversion class **A10 C1 (COND_ACQUIRE)**
targets. The cold-bringup GSP failure routed into the same cycle. **Live evidence
for the in-driver C1 fix.**

## Why every runtime lever failed
- **C5 sink already set**, so the in-driver A1 recover **surrenders at the
  sink-query gate (PERMANENT_FAIL)** — `tb_egpu_recover_force_trigger` /
  `TestForceTrigger` funnel through the same `pre_schedule_gates`, so they do NOT
  bypass it. **Gap: our recover cannot self-recover a declared-lost chip.**
- **SIGKILL** landed (251420 is in `do_exit`) but cannot complete: the close is
  stuck in-kernel on the deadlocked lock. Kthread 169991 cannot be signalled.
- **FLR** (`echo 1 > .../04:00.0/reset`) **executed** (`performing function level
  reset anyway` → `reset done`; benign UBSAN in `pci_restore_iov_state`) but had
  **no effect** — a hardware reset cannot break a kernel rwsem deadlock. A raw
  sysfs reset also does **not dispatch the driver err_handlers**, so the driver is
  never told the device reset (that dispatch is exactly what the gated A1 recover
  would have done).
- No userspace mechanism can force-release a held rwsem held across an unkillable
  kthread.
- **TB-tunnel teardown (Recipe B) — tried, did NOT break it.** `echo 0 >
  /sys/bus/thunderbolt/devices/0-1/authorized` cleanly tore down the tunnel
  (`tb_tunnel_deactivate`, `pciehp Slot(12): Link Down`, `Card not present`,
  `04:00.0 vendor=ffff` — device electrically gone). **The rwsem deadlock
  survived device-gone** (the stuck threads wait on the LOCK, not MMIO), proving
  it is a global RM-API-rwsem lock-ordering deadlock independent of device state.
  Worse: the device's own pciehp removal then **stuck behind the same deadlock**
  (`04:00.0` sysfs never removed, no `nvidia.remove`).
- **TB reauthorize — tried, did NOT recover.** `echo 1 > .../authorized`
  re-activated the TB PCIe paths (`PCIe Up/Down path activation complete`) but the
  device could NOT re-enumerate (`04:00.0` still `ffff`) because the old `pci_dev`
  removal is still deadlocked (slot can't be vacated). **A physical cable replug
  is equivalent to this software unauth/reauth cycle** (the link was already
  electrically down) and will not move a software rwsem deadlock.
- **Therefore reboot IS required for THIS state** — but only after every device
  and TB lever was exhausted and shown ineffective. The host itself is NOT wedged;
  it is one global driver lock that is stuck. The real fix is to PREVENT the
  deadlock forming: **A10 C1 (COND_ACQUIRE) on the deferred-open
  (`rm_get_adapter_status_external`) + close paths.** Once this lock-inversion
  forms it is reboot-only; no recovery primitive (FLR / TB unauth / reauth /
  cable) can break a held kernel rwsem with an unkillable kthread in the cycle.

## Recovery-design implications (feed into #291/#292/#293)
1. **C1 COND_ACQUIRE is load-bearing on MORE paths than the A6/A7 timeout** —
   `rm_get_adapter_status_external` (deferred-open worker) and the close path also
   take blocking `rmapiLockAcquire`. The blocking acquire here is the deadlock.
2. **The C5 sink-gate makes the chip un-recoverable by our own recover.** Need a
   sink-set escape: either a force path that bypasses the sink gate AND dispatches
   err_handlers, or a reset primitive that re-arms the driver. Today the only exit
   from a sink-set + lock-deadlocked state is reboot.
3. **Cold bringup needs a bounded retry** — the H16 PCIe transient at GSP boot is
   stochastic; a single failed cold init shouldn't strand the chip lost. A6/A7
   bound the OPEN/CLOSE workers, but the deferred-open worker that deadlocked here
   was past the bounded-wait into the blocking lock acquire.

## Reboot + restore
Injector DS was drained for the recovery attempt
(`nodeSelector oa-drain=recovery-2026-06-02`). **After reboot, un-drain** so the
fresh pod cold-boots the fresh GPU:
```
kubectl -n kube-system patch ds nvidia-driver-injector --type json \
  -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
```
Then verify: pod `engage ✓` with a real device, `nvidia-smi` persistence on,
fan/power off floor. Saved durably alongside: `a10-v2-surgical-design-workflow-2026-06-02.json`.
