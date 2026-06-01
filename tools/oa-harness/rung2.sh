#!/usr/bin/env bash
# rung2.sh — R2 adversarial bound: the R0 flush-under-fire test.
#            (deterministic-recovery validation; HARD-BLOCKED on R0, KFENCE-watched)
#
# For each of N iterations:
#   1. PRECOND  — establish the F40-open substrate host-side (pod drained):
#                 host rmmod -> TB deauth/reauth (broken-BAR1) -> fix-bar1 (bare,
#                 NO --bind => NO persistence, load-bearing) -> modprobe nvidia
#                 (no persistence) -> assert A6 + pin D0.
#   2. FIRE     — cycle-1 `nvidia-smi -L` (the destructive LAST-CLOSE that makes
#                 the chip divergent) -> gap <5s -> cycle-2 `exec 3</dev/nvidia0`
#                 (the A6 bounded-open fire). On a divergent chip A6's worker hits
#                 the GSP-lockdown poll, TIMES OUT at NVreg_TbEgpuOpenTimeoutMs,
#                 and R0's flush_work (nv.c:1943, the open timeout branch) MUST
#                 join the worker before nvidia_open frees nvlfp — the F42 UAF site.
#   3. ASSERT   — containment: matched `scheduled`+(`completed`|`timed out`) pair
#                 (every scheduled joined), cycle-2 bounded `-EIO` (rc=1) not a hang
#                 (rc=124), host ALIVE, NO `KFENCE: use-after-free`, BAR1 not corrupt.
#                 The flush-under-fire datapoint is the `timed out` case.
#   4. RECOVER  — fix-bar1 --bind + UVM bringup back to a full clean 32 GiB cycle.
#
# VERDICT: the bound holds iff every iteration is contained (no unmatched
# `scheduled`, no KFENCE UAF, no hang, no host wedge) AND re-recovers. A single
# unmatched-scheduled / KFENCE UAF / hang = determinism FAIL -> back to R0.
#
# ⚠️ REBOOT-LIKELY + WEDGE-CLASS: cycle-2 can hard-lock despite A6 (the AER-vs-
# deadlock race), and a flush_work that never returns is an uninterruptible soft
# wedge `timeout` cannot kill. oa_mark fsyncs every wedge-capable step; on a wedge
# REBOOT, then read $OA_RUNDIR/markers.log + RESTORE-CMD.txt (the DS is drained).
# USER MUST BE AT THE CONSOLE.
#
# Usage: sudo tools/oa-harness/rung2.sh [N]
#   N=1 first (single-fire smoke); then N>=10 for the bound (native F40 divergence
#   is only ~1/12–1/3 favorable, so many iters are needed to accumulate real fires).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

N="${1:-1}"
FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DIAG_COMPOSE="$OA_REPO_ROOT/diag/docker-compose.yml"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
R2_CLASS=""          # set by fire_and_assert: fire|clean

# CUDA workload (nvbandwidth H2D via the diag container) — proves the recovered
# chip is CUDA-FUNCTIONAL, not just BAR1-restored. Floor >1.0 GB/s (band 2.7-2.9).
workload_h2d() {
    local i="$1" out gbps
    out="$OA_RUNDIR/i${i}-nvbandwidth.log"
    timeout 120 docker compose -f "$DIAG_COMPOSE" run --rm diag \
        nvbandwidth -t host_to_device_memcpy_ce > "$out" 2>&1
    gbps="$(grep -oiE 'SUM[^0-9]*[0-9]+\.[0-9]+' "$out" | grep -oE '[0-9]+\.[0-9]+' | tail -1)"
    [[ -z "$gbps" ]] && gbps="$(grep -oE '[0-9]+\.[0-9]+' "$out" | tail -1)"
    echo "$gbps"
}

oa_discover
oa_init_run "r2-adversarial-bound"
oa_assert_r0                         # HARD: R0 flush->join + KFENCE live + bounded lane
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable at $FIXBAR1"
[[ $EUID -eq 0 ]] || oa_die "must run as root"

# host-side module unload (pod drained; host owns the module). Same as rung1.
host_unload() {
    local tag="$1" m
    timeout 30 nvidia-smi -pm 0 >/dev/null 2>&1 || true
    sync
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        [[ -d /sys/module/$m ]] && timeout 30 rmmod "$m" >>"$OA_RUNDIR/${tag}-unload.log" 2>&1
    done
    [[ ! -d /sys/module/nvidia ]]
}

# establish the F40-open precondition (no-persistence bound chip, A6 armed, D0).
establish_precond() {
    local i="$1"
    oa_mark "i$i: PRECOND — host rmmod"
    host_unload "i${i}-precond" || { oa_mark "i$i: PRECOND FAIL — module still loaded"; return 1; }
    oa_mark "i$i: PRECOND — TB deauth/reauth"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    oa_mark "i$i: PRECOND — post-replug BAR1=$(oa_bar1_mib)MiB (expect ~256)"
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: PRECOND — fix-bar1 (bare, NO persistence — load-bearing)"
    timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-precond-fixbar1.log" 2>&1
    oa_bar1_ok || { oa_mark "i$i: PRECOND FAIL — BAR1 not 32GiB ($(oa_bar1_mib)MiB)"; return 1; }
    oa_mark "i$i: PRECOND — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
    sleep 2
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || { oa_mark "i$i: PRECOND FAIL — nvidia did not bind ($drv)"; return 1; }
    oa_assert_a6                     # A6 present + bounded-lane (logs version+timeout)
    oa_pin_d0                        # wedge lands at A6's RmInitAdapter site, not pre-open
    oa_mark "i$i: PRECOND ready — no-persistence chip, A6 armed, D0-pinned"
    return 0
}

# cycle-1 (destructive close) + cycle-2 (A6 fire) + containment asserts.
# Sets R2_CLASS=fire|clean. Returns 0 contained, 2 = containment BREACH (FAIL).
fire_and_assert() {
    local i="$1"
    R2_CLASS=""
    oa_mark "i$i: cycle-1 (nvidia-smi -L — destructive LAST-CLOSE, drives divergence)"
    timeout 20 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1; local c1=$?
    oa_mark "i$i: cycle-1 rc=$c1"
    sleep 2                          # keep <5s so the chip stays D0
    local fires_b; fires_b="$(cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires" 2>/dev/null || echo -1)"
    # cycle-2: THE FIRE. oa_mark's kmsg line is the dmesg window anchor.
    oa_mark "i$i: cycle-2 FIRE (exec open /dev/nvidia0) <<< wedge point"
    local t0 t1 c2
    t0=$(date +%s.%N)
    timeout 10 bash -c 'exec 3</dev/nvidia0'; c2=$?    # 0=open ok, 1=-EIO(contained), 124=hang
    t1=$(date +%s.%N)
    oa_mark "i$i: cycle-2 RETURNED rc=$c2 dt=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")ms — host SURVIVED"
    # --- BAR1-first passive, then dmesg window from our anchor (cycle-2 only) ---
    oa_mark "i$i: post-fire BAR1=$(oa_bar1_mib)MiB"
    local fires_a; fires_a="$(cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires" 2>/dev/null || echo -1)"
    dmesg | awk -v m="i${i}: cycle-2 FIRE" 'index($0,m){f=1} f' > "$OA_RUNDIR/i${i}-cycle2-dmesg.txt"; sync
    local sched compl timed kf
    sched=$(grep -ac 'open scheduled to bounded worker' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    compl=$(grep -ac 'open completed within budget'     "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    timed=$(grep -ac 'open timed out after'             "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    kf=$(grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    oa_mark "i$i: dmesg scheduled=$sched completed=$compl timed_out=$timed kfence_uaf=$kf  f40b_fires:${fires_b}->${fires_a}"
    oa_passive_snapshot "i${i}-post-fire"
    # --- classify / assert ---
    if (( kf > 0 )); then oa_mark "i$i: *** FAIL — KFENCE UAF/corruption report ***"; return 2; fi
    if (( c2 == 124 )); then oa_mark "i$i: *** FAIL — cycle-2 HANG (>10s; flush_work did not return = worker not self-terminating, R0 stop-rule) ***"; return 2; fi
    if (( sched > compl + timed )); then oa_mark "i$i: *** FAIL — unmatched 'scheduled' ($sched > $((compl+timed))) = worker NOT joined ***"; return 2; fi
    if (( timed > 0 )); then
        (( c2 == 0 )) && oa_mark "i$i: WARN — timed_out yet cycle-2 rc=0 (open returned success despite timeout?)"
        oa_mark "i$i: FIRE — bad-chip timeout CONTAINED: -EIO(rc=$c2), worker JOINED (matched), KFENCE clean ✓"
        R2_CLASS="fire"
    else
        oa_mark "i$i: clean-open — chip came back healthy this iter (no timeout branch), rc=$c2"
        R2_CLASS="clean"
    fi
    return 0
}

# re-recover to a full clean 32 GiB cycle (fix-bar1 --bind + UVM), like R1.
recover_clean() {
    local i="$1"
    oa_mark "i$i: RECOVER — host rmmod"
    host_unload "i${i}-recover" || oa_mark "i$i: RECOVER WARN — unload non-clean"
    oa_mark "i$i: RECOVER — TB deauth/reauth"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: RECOVER — fix-bar1 --bind + UVM bringup"
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/i${i}-recover-fixbar1.log" 2>&1
    modprobe --ignore-install nvidia_uvm >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    nvidia-modprobe -u -c 0          >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    if ! oa_bar1_recovered; then oa_mark "i$i: RECOVER INCOMPLETE — BAR1=$(oa_bar1_mib) (verdict=$(oa_bar1_leg_diagnose))"; return 1; fi
    # CUDA workload — prove the post-fire recovery is CUDA-FUNCTIONAL (not just BAR1).
    oa_mark "i$i: RECOVER — BAR1 32768; CUDA workload (nvbandwidth H2D)"
    local h2d; h2d="$(workload_h2d "$i")"
    oa_mark "i$i: RECOVER H2D=${h2d:-<none>} GB/s (band 2.7-2.9; floor >1.0)"
    if [[ -z "$h2d" ]] || ! awk "BEGIN{exit !($h2d>1.0)}"; then
        oa_mark "i$i: RECOVER FAIL — CUDA workload regression/hang (H2D=${h2d:-none})"; return 1
    fi
    oa_mark "i$i: RECOVER OK — BAR1 32768, CUDA-functional (H2D=${h2d})"
    return 0
}

# ---- run ----
oa_mark "R2 start: N=$N (smoke=1, bound>=10)"
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_log "KFENCE sample_interval -> 1ms (was ${KF_SAVED})"; }
oa_drain_injector || oa_die "could not drain injector — aborting R2 (it would race the fire)"
cleanup() { [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null; oa_restore_injector; }
trap cleanup EXIT

FIRES=0; CLEANS=0; FAILS=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== R2 iter $i/$N START ====="
    if ! establish_precond "$i"; then FAILS=$((FAILS+1)); HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    fire_and_assert "$i"; frc=$?
    if (( frc == 2 )); then FAILS=$((FAILS+1)); HALT="containment-breach"; oa_passive_snapshot "i${i}-BREACH"; break; fi
    [[ "$R2_CLASS" == fire ]] && FIRES=$((FIRES+1)) || CLEANS=$((CLEANS+1))
    if ! recover_clean "$i"; then FAILS=$((FAILS+1)); HALT="recover"; break; fi
    oa_mark "===== R2 iter $i/$N DONE (class=$R2_CLASS) ====="
done

oa_mark "===== R2 COMPLETE: fires=$FIRES cleans=$CLEANS fails=$FAILS of $N${HALT:+ (halt:$HALT)} ====="
if (( FAILS == 0 )); then
    oa_log "verdict: CONTAINED (n=$N, fires=$FIRES, cleans=$CLEANS; every scheduled joined, KFENCE clean, no wedge)"
    (( FIRES == 0 )) && oa_warn "NOTE: 0 actual timeout-fires this run — divergence didn't trigger; need more iters to exercise the flush-under-fire branch"
else
    oa_log "verdict: NOT clean — FAIL ($HALT) — see $OA_RUNDIR"
fi
oa_log "forensics: $OA_RUNDIR"
