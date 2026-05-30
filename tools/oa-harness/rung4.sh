#!/usr/bin/env bash
# tools/oa-harness/rung4.sh — Lane 2 Rung 4: PMU kstack of the A6-CONTAINED open fire.
#
# THE CRUX DISCRIMINATOR. On a D0-pinned chip with A6 present, reproduce the
# cycle-2 open and PMU-sample the leaked worker to locate the wedge wait-frame:
#   H-OA1   _kgspRpcRecvPoll <- kgspWaitForRmInitDone <- kgspBootstrap_GH100  (GSP init RPC)
#   H-OA10  gpuHandleSanityCheckRegReadError_GH100 / early gpuState*          (first-MMIO sanity check)
#   H-OA2   pci_pm_runtime_resume / PM core, or PMU-NULL                       (pre-nv_open_device site)
#
# Expected (D0-pinned + A6): cycle-2 returns -EIO in ~200 ms, host SURVIVES.
# But it is WEDGE-CLASS: the AER-vs-deadlock race can hard-lock anyway -> reboot.
# If that happens, markers.log + snapshots are fsync'd and survive; resume by
# reading $OA_RUNDIR after the reboot.
#
# Usage (after precondition is freshly established, OR pass --precond to run it):
#   sudo tools/oa-harness/rung4.sh --hz 4999 --gap 2 [--precond]
set -uo pipefail
_OA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_OA_DIR/lib.sh"
# shellcheck source=/dev/null
source "$_OA_DIR/precondition.sh"

HZ=4999; GAP=2; DO_PRECOND=0
while [[ $# -gt 0 ]]; do case "$1" in
    --hz) HZ="$2"; shift 2;; --gap) GAP="$2"; shift 2;;
    --precond) DO_PRECOND=1; shift;; *) oa_die "unknown arg $1";; esac; done

[[ $EUID -eq 0 ]] || oa_die "must run as root"
command -v bpftrace >/dev/null || oa_die "bpftrace required"

oa_discover
oa_init_run "rung4-pmu-hz${HZ}-gap${GAP}"
oa_mark "RUNG4 begin hz=$HZ gap=${GAP}s"

[[ "$DO_PRECOND" == 1 ]] && oa_precondition

# Re-assert the Rung 3.5 gate right before firing (defends the contained-lane
# safety invariant: A6 present + chip pinned D0).
oa_assert_a6
oa_pin_d0
oa_bar1_ok || oa_die "BAR1 not 32 GiB pre-fire ($(oa_bar1_mib) MiB) — abort"

# cycle-1: full open->init->LAST-CLOSE (drives WPR2 -> 0). nvidia-smi here is the
# documented trigger on a freshly-bound HEALTHY chip (not observability on a
# suspect chip), so it is allowed.
oa_mark "RUNG4 cycle-1 (nvidia-smi -L)"
c1out="$(timeout 20 nvidia-smi -L 2>&1)"; c1rc=$?
printf '%s\n' "$c1out" > "$OA_RUNDIR/cycle1.txt"; sync
oa_mark "RUNG4 cycle-1 done rc=$c1rc"
[[ $c1rc -eq 0 ]] || oa_warn "cycle-1 rc=$c1rc (expected 0; chip may already be unhappy)"

sleep "$GAP"   # keep < 5s so the chip stays D0 (wedge lands at A6's RmInitAdapter site)

# Arm the PMU sampler (profile:hz, breakpoint-free; the closed RM has 0 endbr64
# so kprobe EINVALs under IBT). Lighter than the 47-probe set that flipped the
# AER race, but probe overhead is still a VARIABLE (vary --hz across runs).
oa_mark "RUNG4 sampler start (profile:hz:$HZ, 8s)"
bpftrace -e "profile:hz:${HZ} { @[kstack] = count(); } interval:s:8 { exit(); }" \
    > "$OA_RUNDIR/pmu-hz${HZ}.log" 2>"$OA_RUNDIR/pmu-hz${HZ}.err" &
SAMP=$!
sleep 1   # let bpftrace attach

# cycle-2: THE FIRE. Open /dev/nvidia0 -> nv_open_device_for_nvlfp -> A6 bounded
# wait. Expect -EIO ~200ms (contained). timeout is a soft-hang fallback only;
# it CANNOT save a hard kernel wedge (uninterruptible). This is the wedge point.
oa_mark "RUNG4 cycle-2 FIRE (exec open /dev/nvidia0) <<< wedge point"
t0=$(date +%s.%N)
timeout 10 bash -c 'exec 3</dev/nvidia0; exec 3>&-'; c2rc=$?
t1=$(date +%s.%N)
oa_mark "RUNG4 cycle-2 RETURNED rc=$c2rc dt=$(awk "BEGIN{printf \"%.1f\",($t1-$t0)*1000}")ms — host SURVIVED"

# ---- we only get here if the host survived (contained) ----
wait "$SAMP" 2>/dev/null
oa_mark "RUNG4 sampler stopped"

# FIRST post-fire check is BAR1-via-sysfs (chip-safety rule).
if oa_bar1_ok; then oa_log "post-fire BAR1=$(oa_bar1_mib) MiB OK"
else oa_warn "post-fire BAR1=$(oa_bar1_mib) MiB BROKEN — passive only, reboot before any MMIO"; fi
oa_passive_snapshot "rung4-post-cycle2"
dmesg 2>/dev/null | tail -120 > "$OA_RUNDIR/dmesg-tail.txt"; sync

# ---- quick frame attribution from the PMU capture ----
pmu="$OA_RUNDIR/pmu-hz${HZ}.log"
{
    echo "=== Rung 4 frame attribution (hz=$HZ gap=${GAP}s) ==="
    echo "cycle-2: rc=$c2rc  (0=open succeeded[!], non-0=EIO/contained as expected)"
    echo
    echo "-- H-OA1 (GSP init RPC poll) hits --"
    grep -acE '_kgspRpcRecvPoll|kgspWaitForRmInitDone|kgspBootstrap|_issueRpcAndWait' "$pmu" 2>/dev/null
    grep -aE '_kgspRpcRecvPoll|kgspWaitForRmInitDone|kgspBootstrap|_issueRpcAndWait' "$pmu" 2>/dev/null | head
    echo "-- H-OA10 (early sanity-check MMIO) hits --"
    grep -acE 'gpuHandleSanityCheck|gpuReadReg|gpuGetSimulation|0x110094' "$pmu" 2>/dev/null
    grep -aE 'gpuHandleSanityCheck|gpuReadReg' "$pmu" 2>/dev/null | head
    echo "-- H-OA2 (PM-resume / PM core) hits --"
    grep -acE 'pci_pm_runtime_resume|pci_power_up|__rpm_callback|pm_runtime' "$pmu" 2>/dev/null
    echo "-- nv_open path present? --"
    grep -acE 'nv_open_device|nvidia_open|nv_f40b|os_acquire' "$pmu" 2>/dev/null
    echo
    echo "-- top 12 kernel stacks by sample count --"
    awk '/^@\[/{flag=1} flag' "$pmu" 2>/dev/null | tail -60
} > "$OA_RUNDIR/ATTRIBUTION.txt" 2>&1
sync

oa_mark "RUNG4 complete — see ATTRIBUTION.txt"
echo
oa_log "================= RESULT ================="
cat "$OA_RUNDIR/ATTRIBUTION.txt"
oa_log "rundir: $OA_RUNDIR"
oa_log "NOTE: chip is now in C5-sink/lost state. Re-run precondition before any further fire."
