#!/usr/bin/env bash
# rung3.sh — R3 re-recovery race: rmmod vs in-flight A6 open-worker (F42 double-UAF).
#            (deterministic-recovery validation; HARD-BLOCKED on R0+R1+R2, KFENCE-watched)
#
# The F42 double-UAF: a leaked A6 open-worker (holds NO module ref) outlives the
# open syscall; if rmmod's free_module then frees nvidia.ko .text / nvl while the
# worker still runs -> UAF in workqueue context. R0's flush_work (nv.c:1943) joins
# the worker BEFORE the open returns -EIO, so at rmmod time there should be no
# in-flight worker. R3 proves that empirically + bounds it.
#
# Per iteration (N>=10):
#   1. PRECOND  — no-persistence F40 substrate (host-side, pod drained).
#   2. FIRE     — cycle-1 destructive close -> cycle-2 open (-> bounded -EIO).
#   3. RACE     — IMMEDIATELY (zero delay) rmmod nvidia_uvm + nvidia, each under a
#                 hard `timeout` exit-sentinel. ASSERT: both return BOUNDED (a hang
#                 => worker still running => FAIL), /sys/module/nvidia gone, and NO
#                 `KFENCE: use-after-free` from the unload. This is the tightest
#                 rmmod-vs-worker race R0 must survive.
#   4. RECOVER  — TB deauth/reauth -> fix-bar1 --bind + UVM -> full clean 32 GiB.
#
# VERDICT: the race is safe iff every iteration's rmmod completes bounded, module
# unloads, KFENCE clean, host alive, and re-recovers. A hang / KFENCE UAF / wedge
# = FAIL -> R0 self-termination insufficient -> R0 stop-rule (route to E27).
#
# ⚠️ REBOOT-LIKELY + WEDGE-CLASS (same as R2). oa_mark fsyncs every wedge-capable
# step; on a wedge REBOOT then read $OA_RUNDIR/markers.log + RESTORE-CMD.txt (DS
# drained). USER MUST BE AT THE CONSOLE.
#
# Usage: sudo tools/oa-harness/rung3.sh [N]   (N=1 smoke; then N>=10 for the bound)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

N="${1:-1}"
FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
DIAG_COMPOSE="$OA_REPO_ROOT/diag/docker-compose.yml"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
RMMOD_TIMEOUT=15     # exit-sentinel: rmmod must return within this or the worker is still running

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
oa_init_run "r3-rerecovery-race"
oa_assert_r0
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable at $FIXBAR1"
[[ $EUID -eq 0 ]] || oa_die "must run as root"

host_unload() {
    local tag="$1" m
    timeout 30 nvidia-smi -pm 0 >/dev/null 2>&1 || true
    sync
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        [[ -d /sys/module/$m ]] && timeout 30 rmmod "$m" >>"$OA_RUNDIR/${tag}-unload.log" 2>&1
    done
    [[ ! -d /sys/module/nvidia ]]
}

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
    oa_mark "i$i: PRECOND — fix-bar1 (bare, NO persistence)"
    timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-precond-fixbar1.log" 2>&1
    oa_bar1_ok || { oa_mark "i$i: PRECOND FAIL — BAR1 not 32GiB ($(oa_bar1_mib)MiB)"; return 1; }
    oa_mark "i$i: PRECOND — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
    sleep 2
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || { oa_mark "i$i: PRECOND FAIL — nvidia did not bind ($drv)"; return 1; }
    oa_assert_a6
    oa_pin_d0
    oa_mark "i$i: PRECOND ready — no-persistence chip, A6 armed, D0-pinned"
    return 0
}

# cycle-1 destructive close + cycle-2 fire. Sets FIRE_TIMED=1 if the open hit the
# timeout branch (the divergent fire); echoes nothing. Leaves the chip lost +
# module still loaded for the rmmod race.
do_fire() {
    local i="$1"; FIRE_TIMED=0; FIRE_C2RC=0
    oa_mark "i$i: cycle-1 (nvidia-smi -L — destructive close)"
    timeout 20 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1
    sleep 2
    oa_mark "i$i: cycle-2 FIRE (open /dev/nvidia0) <<< wedge point"
    timeout 10 bash -c 'exec 3</dev/nvidia0'; FIRE_C2RC=$?
    oa_mark "i$i: cycle-2 RETURNED rc=$FIRE_C2RC — host SURVIVED"
    dmesg | awk -v m="i${i}: cycle-2 FIRE" 'index($0,m){f=1} f' > "$OA_RUNDIR/i${i}-cycle2-dmesg.txt"; sync
    local timed; timed=$(grep -ac 'open timed out after' "$OA_RUNDIR/i${i}-cycle2-dmesg.txt")
    (( timed > 0 )) && FIRE_TIMED=1
    oa_mark "i$i: fire timed_out=$timed (FIRE_TIMED=$FIRE_TIMED)"
}

# THE R3 MEASUREMENT: immediate timed rmmod race vs any in-flight worker.
# Returns 0 = clean+bounded, 2 = FAIL (hang or KFENCE UAF).
rmmod_race() {
    local i="$1"
    local kbefore; kbefore=$(dmesg | grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)')
    oa_mark "i$i: RACE — IMMEDIATE rmmod (exit-sentinel ${RMMOD_TIMEOUT}s) <<< F42 double-UAF point"
    local t0 t1 hung=0 ur=0 nr=0
    t0=$(date +%s.%N)
    if [[ -d /sys/module/nvidia_uvm ]]; then timeout "$RMMOD_TIMEOUT" rmmod nvidia_uvm >>"$OA_RUNDIR/i${i}-race.log" 2>&1; ur=$?; fi
    if [[ -d /sys/module/nvidia ]];     then timeout "$RMMOD_TIMEOUT" rmmod nvidia     >>"$OA_RUNDIR/i${i}-race.log" 2>&1; nr=$?; fi
    t1=$(date +%s.%N)
    local dt; dt=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")
    (( ur == 124 || nr == 124 )) && hung=1
    local still_loaded=0; [[ -d /sys/module/nvidia ]] && still_loaded=1
    local kafter; kafter=$(dmesg | grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)')
    oa_mark "i$i: RACE rmmod uvm_rc=$ur nvidia_rc=$nr dt=${dt}ms hung=$hung still_loaded=$still_loaded kfence_new=$((kafter-kbefore))"
    oa_passive_snapshot "i${i}-post-race"
    if (( hung == 1 )); then oa_mark "i$i: *** FAIL — rmmod HANG (>${RMMOD_TIMEOUT}s) = worker still running (R0 join insufficient) ***"; return 2; fi
    if (( kafter > kbefore )); then oa_mark "i$i: *** FAIL — KFENCE UAF during rmmod (.text/nvl freed under worker) ***"; return 2; fi
    if (( still_loaded == 1 )); then oa_mark "i$i: *** FAIL — nvidia still loaded after rmmod (rc=$nr) ***"; return 2; fi
    oa_mark "i$i: RACE clean — rmmod bounded (${dt}ms), module unloaded, KFENCE clean ✓"
    return 0
}

# module already unloaded by the race; recover = TB cycle + fix-bar1 --bind + UVM.
recover_clean() {
    local i="$1"
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
oa_mark "R3 start: N=$N (smoke=1, bound>=10)  rmmod exit-sentinel=${RMMOD_TIMEOUT}s"
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_log "KFENCE sample_interval -> 1ms (was ${KF_SAVED})"; }
oa_drain_injector || oa_die "could not drain injector — aborting R3"
cleanup() { [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null; oa_restore_injector; }
trap cleanup EXIT

RACED=0; FIRES=0; FAILS=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== R3 iter $i/$N START ====="
    if ! establish_precond "$i"; then FAILS=$((FAILS+1)); HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    do_fire "$i"
    (( FIRE_TIMED == 1 )) && FIRES=$((FIRES+1))
    rmmod_race "$i"; rrc=$?
    if (( rrc == 2 )); then FAILS=$((FAILS+1)); HALT="race-breach"; oa_passive_snapshot "i${i}-BREACH"; break; fi
    RACED=$((RACED+1))
    if ! recover_clean "$i"; then FAILS=$((FAILS+1)); HALT="recover"; break; fi
    oa_mark "===== R3 iter $i/$N DONE (timed_fire=$FIRE_TIMED) ====="
done

oa_mark "===== R3 COMPLETE: raced=$RACED timed_fires=$FIRES fails=$FAILS of $N${HALT:+ (halt:$HALT)} ====="
if (( FAILS == 0 )); then
    oa_log "verdict: RACE-SAFE (n=$N, raced=$RACED, of which timed-fires=$FIRES; every rmmod bounded, module unloaded, KFENCE clean, no hang/wedge)"
    (( FIRES == 0 )) && oa_warn "NOTE: 0 timed-fires — the race ran but never against a genuine post-timeout state; need more iters"
else
    oa_log "verdict: NOT clean — FAIL ($HALT) — see $OA_RUNDIR"
fi
oa_log "forensics: $OA_RUNDIR"
