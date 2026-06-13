#!/usr/bin/env bash
# rung6-a10-validate.sh — validate the A10 (F44) fix against the reproducible
#                         lockdown-substrate re-open wedge.
#
# Per iteration: precond (healthy no-persist chip, A10 loaded) -> cycle-1
# (nvidia-smi -L: a CLEAN LAST-CLOSE drives WPR2->0 = the lockdown substrate) ->
# read WPR2 from the close telemetry -> fire ONE re-open (exec open /dev/nvidia0,
# timeout 35s so an incomplete-fix soft-block reads as a long dt, NOT a false
# hang) -> classify. Loop until a LOCKDOWN-SUBSTRATE fire is CONTAINED (= A10
# validated) or a wedge (= A10 failed -> kdump captured the vmcore) or N exhausted.
#
# SUCCESS  = a fire with "open timed out after" (A6 timeout => A10's branch ran)
#            that returns bounded -EIO in <~1s with the host ALIVE and KFENCE clean.
#            Pre-A10 this exact fire HARD-WEDGED the host (2 reboots 2026-06-02).
# REGRESS  = a WPR2-fast-fail fire ("completed within budget") still fast-fails
#            (the R2-R4 path is untouched).
# FAIL     = host wedge (no marker after the fire) -> reboot -> read markers +
#            the kdump vmcore in /var/crash.
#
# PREREQ (the operator/driver must set BEFORE running): hardlockup_panic=1,
# softlockup_panic=1, kdump active, sysrq armed. A10 module installed to
# /lib/modules/<kver>/extra (version 595.71.05-apnex.26). Injector DS drained.
# ⚠️ REBOOT-RISK if A10 is wrong. USER AT CONSOLE.
#
# Usage: sudo tools/oa-harness/rung6-a10-validate.sh [N]   (default N=6)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

N="${1:-6}"
FIXBAR1="$OA_REPO_ROOT/tools/fix-bar1.sh"
KF_PARAM=/sys/module/kfence/parameters/sample_interval
KF_SAVED=""
A10_VER="595.71.05-apnex.26"
REOPEN_TIMEOUT=35   # > worst-case RM gpuTimeout (~30s compute) so a soft-block != false-hang

oa_discover
oa_init_run "r6-a10-validate"
oa_assert_r0
[[ -x "$FIXBAR1" ]] || oa_die "fix-bar1.sh not executable"
[[ $EUID -eq 0 ]] || oa_die "must run as root"

IS_EXT() { cat "/sys/bus/pci/devices/$OA_GPU/tb_egpu_is_external" 2>/dev/null || echo '?'; }

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
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    oa_mark "i$i: PRECOND — fix-bar1 (bare, NO persistence)"
    timeout 180 "$FIXBAR1" > "$OA_RUNDIR/i${i}-precond-fixbar1.log" 2>&1
    oa_bar1_ok || { oa_mark "i$i: PRECOND FAIL — BAR1 not 32GiB ($(oa_bar1_mib)MiB)"; return 1; }
    oa_mark "i$i: PRECOND — modprobe nvidia (NO persistence)"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    modprobe --ignore-install nvidia >>"$OA_RUNDIR/i${i}-precond.log" 2>&1
    sleep 2
    local ver; ver="$(cat /sys/module/nvidia/version 2>/dev/null)"
    [[ "$ver" == "$A10_VER" ]] || { oa_mark "i$i: PRECOND FAIL — loaded module is '$ver' NOT $A10_VER (A10 not installed!)"; return 1; }
    local drv; drv="$(basename "$(readlink "/sys/bus/pci/devices/$OA_GPU/driver" 2>/dev/null || echo none)")"
    [[ "$drv" == nvidia ]] || { oa_mark "i$i: PRECOND FAIL — nvidia did not bind ($drv)"; return 1; }
    oa_assert_a6; oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { oa_mark "i$i: PRECOND FAIL — is_external=$(IS_EXT)"; return 1; }
    oa_mark "i$i: PRECOND ready — A10 ($ver), no-persist, A6 armed, D0-pinned, is_external=1"
    return 0
}

recover_clean() {
    local i="$1"
    oa_mark "i$i: RECOVER — host rmmod + TB reenum + fix-bar1 --bind"
    host_unload "i${i}-recover" || oa_mark "i$i: RECOVER WARN — unload non-clean"
    echo 0 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 2
    echo 1 > "/sys/bus/thunderbolt/devices/$OA_TB/authorized" 2>/dev/null; sync; sleep 4
    oa_discover
    setpci -s "$OA_GPU_SHORT" COMMAND=0000 2>/dev/null
    timeout 180 "$FIXBAR1" --bind > "$OA_RUNDIR/i${i}-recover-fixbar1.log" 2>&1
    modprobe --ignore-install nvidia_uvm >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    nvidia-modprobe -u -c 0          >>"$OA_RUNDIR/i${i}-recover.log" 2>&1
    oa_bar1_recovered || { oa_mark "i$i: RECOVER INCOMPLETE — BAR1=$(oa_bar1_mib)"; return 1; }
    oa_mark "i$i: RECOVER OK — BAR1 32768"
    return 0
}

# cycle-1 (clean close -> WPR2=0) + the re-open fire + A10 classification.
# Sets R6_RESULT = a10-contained | fast-fail | ambiguous ; returns 2 on BREACH/wedge-class.
R6_RESULT=""
fire_reopen() {
    local i="$1"
    oa_mark "i$i: cycle-1 (nvidia-smi -L — clean close drives WPR2->0)"
    timeout 25 nvidia-smi -L > "$OA_RUNDIR/i${i}-cycle1.txt" 2>&1
    sleep 1
    # read WPR2 from the most-recent post-shutdown close telemetry
    local wpr2; wpr2="$(dmesg | grep 'site=post-shutdown' | tail -1 | grep -oE 'WPR2=0x[0-9a-f]+' | tail -1)"
    oa_mark "i$i: post-cycle1 ${wpr2:-WPR2=?} (0x0 = lockdown substrate = the A10 test; up = fast-fail twin)"
    oa_assert_a6; oa_pin_d0
    [[ "$(IS_EXT)" == 1 ]] || { R6_RESULT="inconclusive(is_external)"; oa_mark "i$i: SKIP — $R6_RESULT"; return 0; }
    oa_bar1_ok || { R6_RESULT="inconclusive(bar1)"; oa_mark "i$i: SKIP — $R6_RESULT"; return 0; }
    sleep 2   # <5s, stay D0
    oa_mark "i$i: RE-OPEN FIRE (exec open /dev/nvidia0, timeout ${REOPEN_TIMEOUT}s) <<< pre-A10 WEDGE point"
    local t0 t1 rc; t0=$(date +%s.%N)
    timeout "$REOPEN_TIMEOUT" bash -c 'exec 3</dev/nvidia0'; rc=$?
    t1=$(date +%s.%N)
    local dt; dt=$(awk "BEGIN{printf \"%.0f\",($t1-$t0)*1000}")
    oa_mark "i$i: RE-OPEN RETURNED rc=$rc dt=${dt}ms — HOST SURVIVED"
    oa_mark "i$i: post-fire BAR1=$(oa_bar1_mib)MiB"
    dmesg | awk -v m="i${i}: RE-OPEN FIRE" 'index($0,m){f=1} f' > "$OA_RUNDIR/i${i}-reopen-dmesg.txt"; sync
    local sched compl timed kf
    sched=$(grep -ac 'open scheduled to bounded worker' "$OA_RUNDIR/i${i}-reopen-dmesg.txt")
    compl=$(grep -ac 'open completed within budget'     "$OA_RUNDIR/i${i}-reopen-dmesg.txt")
    timed=$(grep -ac 'open timed out after'             "$OA_RUNDIR/i${i}-reopen-dmesg.txt")
    kf=$(grep -acE 'KFENCE: (use-after-free|memory corruption|out-of-bounds)' "$OA_RUNDIR/i${i}-reopen-dmesg.txt")
    oa_mark "i$i: dmesg sched=$sched compl=$compl timed=$timed kfence=$kf  rc=$rc dt=${dt}ms wpr2=${wpr2#WPR2=}"
    oa_passive_snapshot "i${i}-post-fire"
    if (( kf > 0 )); then R6_RESULT="BREACH(KFENCE-UAF)"; oa_mark "i$i: *** $R6_RESULT ***"; return 2; fi
    if (( rc == 124 )); then R6_RESULT="FAIL(soft-block-timeout ${dt}ms — A10 did NOT fast-fail the worker)"; oa_mark "i$i: *** $R6_RESULT ***"; return 2; fi
    if (( timed >= 1 )); then
        # A6 TIMED OUT => A10's timeout-branch ran. This is THE lockdown-substrate fire.
        if (( dt < 1500 )); then
            R6_RESULT="a10-contained"
            oa_mark "i$i: *** A10 VALIDATED *** lockdown-substrate re-open CONTAINED: bounded -EIO(rc=$rc) dt=${dt}ms, worker self-terminated, host alive, KFENCE clean (pre-A10 this WEDGED)"
        else
            R6_RESULT="a10-slow(${dt}ms)"
            oa_mark "i$i: WARN — timed-out + contained but dt=${dt}ms >1.5s (worker self-terminated SLOWLY; A10 marker reached but not microsecond-fast)"
        fi
    elif (( compl >= 1 )); then
        R6_RESULT="fast-fail"
        oa_mark "i$i: fast-fail substrate (WPR2-up): open completed within budget, A10 branch not exercised (regression-OK datapoint)"
    else
        R6_RESULT="ambiguous(rc=$rc)"
        oa_mark "i$i: ambiguous — no scheduled/timed/completed marker (rc=$rc)"
    fi
    return 0
}

# ---- run ----
oa_mark "R6 (A10 validation) start: N=$N reopen_timeout=${REOPEN_TIMEOUT}s; expect a10-contained on the lockdown substrate"
[[ -w "$KF_PARAM" ]] && { KF_SAVED="$(cat "$KF_PARAM")"; echo 1 > "$KF_PARAM" 2>/dev/null && oa_log "KFENCE -> 1ms"; }
oa_log "capture prereqs: hardlockup_panic=$(cat /proc/sys/kernel/hardlockup_panic 2>/dev/null) softlockup_panic=$(cat /proc/sys/kernel/softlockup_panic 2>/dev/null) kexec_loaded=$(cat /sys/kernel/kexec_loaded 2>/dev/null) sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null)"
oa_drain_injector || oa_die "could not drain injector — aborting"
cleanup() { [[ -n "$KF_SAVED" && -w "$KF_PARAM" ]] && echo "$KF_SAVED" > "$KF_PARAM" 2>/dev/null; oa_restore_injector; }
trap cleanup EXIT

CONTAINED=0; FASTFAIL=0; OTHER=0; HALT=""
for i in $(seq 1 "$N"); do
    oa_mark "===== R6 iter $i/$N START ====="
    if ! establish_precond "$i"; then HALT="precond"; oa_passive_snapshot "i${i}-precond-fail"; break; fi
    fire_reopen "$i"; frc=$?
    if (( frc == 2 )); then HALT="$R6_RESULT"; break; fi
    case "$R6_RESULT" in
        a10-contained) CONTAINED=$((CONTAINED+1));;
        fast-fail)     FASTFAIL=$((FASTFAIL+1));;
        *)             OTHER=$((OTHER+1));;
    esac
    recover_clean "$i" || { HALT="recover"; break; }
    oa_mark "===== R6 iter $i/$N DONE ($R6_RESULT) ====="
    # stop early once A10 is proven on the lockdown substrate
    (( CONTAINED >= 1 )) && { oa_mark "A10 proven on the lockdown substrate (n=$CONTAINED) — stopping early"; break; }
done

oa_mark "===== R6 COMPLETE: a10-contained=$CONTAINED fast-fail=$FASTFAIL other=$OTHER${HALT:+ (halt:$HALT)} ====="
if (( CONTAINED >= 1 )); then
    oa_log "verdict: A10 VALIDATED — the lockdown-substrate re-open is now CONTAINED (bounded -EIO, host alive) where pre-A10 it hard-wedged."
elif [[ -n "$HALT" && "$HALT" != precond && "$HALT" != recover ]]; then
    oa_log "verdict: A10 FAILED ($HALT) — see $OA_RUNDIR markers + /var/crash kdump vmcore."
else
    oa_log "verdict: INCONCLUSIVE — never hit the WPR2=0 lockdown substrate in $N iters (fast-fail=$FASTFAIL). Re-run with larger N."
fi
oa_log "forensics: $OA_RUNDIR"
