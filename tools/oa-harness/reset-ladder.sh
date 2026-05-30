#!/usr/bin/env bash
# tools/oa-harness/reset-ladder.sh — OA reset-efficacy ladder (H-OA12).
#
# !!! DANGER — NOT SURVIVABLE AS WRITTEN. DO NOT RUN. !!!
# R0.5 hard-wedged the host 2026-05-31. The "A6 net" premise is FALSE: A6 does
# NOT guard the FIRST open of a bind (is_external_gpu is set lazily during the
# first open's RmInitAdapter), and this script's unbind->reset->rebind makes
# cycle-2 a first open -> A6 bypassed -> uncontained wedge, for EVERY variant.
# Forensics: experiments/OA-reset-ladder-wedge-forensics-2026-05-31.md.
# Before re-running: gate cycle-2 on the tb_egpu_is_external sysfs attr (A8 v2.2,
# abort if 0) OR fix the A6 first-open hole OR treat as destructive reboot-loop.
#
# Design: experiments/OA-reset-efficacy-ladder.md.
# Between cycle-1 (clean) and cycle-2, apply a reset of selectable depth and see
# whether cycle-2 boots CLEAN (cured) or fires A6 (not cured). A6 stays at 200ms
# (safety net) — every non-curing variant survives.
#
#   --reset none   R0   no reset (Lane-2 baseline)
#   --reset rebind R0.5 unbind -> rebind, NO hw reset (does re-probe alone cure?)
#   --reset flr    R1   Function-Level Reset of the GPU function
#   --reset sbr    R2   secondary bus reset on the bridge (== A3's pci_reset_bus)
#   --reset slot   R3   pciehp slot power-cycle (cold-plug-equivalent)
#
# IMPORTANT EMPIRICAL COUPLING: flr/sbr reset ReBAR CTRL -> BAR1 likely breaks to
# 256MB, and the bridge window only re-sizes on slot re-enumeration. The harness
# records the BAR1 state after each reset and escalates to a slot-cycle restore
# if needed (recording that it was needed — itself a finding: the cure is coupled
# to the BAR1/bridge-window problem, not just GSP state).
#
# Usage: sudo tools/oa-harness/reset-ladder.sh --reset sbr [--hz 4999] [--gap 2]
set -uo pipefail
_OA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$_OA_DIR/lib.sh"
# shellcheck source=/dev/null
source "$_OA_DIR/precondition.sh"

RESET=none; HZ=4999; GAP=2
while [[ $# -gt 0 ]]; do case "$1" in
    --reset) RESET="$2"; shift 2;; --hz) HZ="$2"; shift 2;; --gap) GAP="$2"; shift 2;;
    *) oa_die "unknown arg $1";; esac; done
[[ $EUID -eq 0 ]] || oa_die "must run as root"
case "$RESET" in none|rebind|flr|sbr|slot) ;; *) oa_die "bad --reset $RESET";; esac

oa_discover
# host-specific reset topology (obpc / RTX5090): derived + known constants.
OA_BRIDGE="$(basename "$(readlink -f /sys/bus/pci/devices/$OA_GPU/.. 2>/dev/null)")"   # 0000:03:00.0
OA_BRIDGE_SHORT="${OA_BRIDGE#0000:}"
OA_SLOT=12                 # pciehp slot (fix-bar1 discovery)
OA_REBAR_CTRL=0x13c        # ReBAR cap 0x134 + 8
OA_REBAR_VAL=0x00000f21    # BAR_IDX=1 NBAR=1 BAR_SIZE=15 (32 GiB)

oa_init_run "resetladder-${RESET}-hz${HZ}"
oa_mark "RESETLADDER reset=$RESET hz=$HZ gap=${GAP}s bridge=$OA_BRIDGE slot=$OA_SLOT"

oa_dev_present() { [[ -e "/sys/bus/pci/devices/$OA_GPU" ]]; }
oa_slot_recover() {   # last-resort: slot power-cycle + ReBAR restore (no rebind)
    oa_mark "slot-cycle recover (BAR1 restore)"
    echo 0 > "/sys/bus/pci/slots/$OA_SLOT/power" 2>/dev/null; sleep 3
    echo 1 > "/sys/bus/pci/slots/$OA_SLOT/power" 2>/dev/null; sleep 5
    oa_dev_present || { oa_mark "DEVICE GONE after slot-cycle — REBOOT NEEDED"; return 1; }
    setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
    setpci -s "$OA_GPU_SHORT" "${OA_REBAR_CTRL}.l=${OA_REBAR_VAL}" 2>/dev/null
    return 0
}

# ---- substrate ----
oa_precondition          # ends: nvidia bound (no-persist), D0-pinned, A6 present
oa_bar1_ok || oa_die "precond BAR1 not 32G"

# ---- cycle-1 (clean open+close; WPR2 -> 0) ----
oa_mark "cycle-1 (nvidia-smi -L)"
timeout 20 nvidia-smi -L > "$OA_RUNDIR/cycle1.txt" 2>&1; c1=$?
oa_mark "cycle-1 done rc=$c1"

# ---- the RESET variant (between cycle-1 and cycle-2) ----
oa_passive_snapshot "pre-reset"
if [[ "$RESET" != none ]]; then
    oa_mark "unbind nvidia from $OA_GPU"
    echo "$OA_GPU" > /sys/bus/pci/drivers/nvidia/unbind 2>/dev/null || oa_warn "unbind failed"
    sleep 1
    case "$RESET" in
        rebind) : ;;   # no hw reset
        flr)
            oa_mark "FLR on $OA_GPU"
            echo flr > "/sys/bus/pci/devices/$OA_GPU/reset_method" 2>/dev/null
            setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
            echo 1 > "/sys/bus/pci/devices/$OA_GPU/reset" 2>/dev/null || oa_warn "FLR write failed"
            sleep 2 ;;
        sbr)
            oa_mark "secondary bus reset via bridge $OA_BRIDGE (== A3 pci_reset_bus)"
            setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
            echo 1 > "/sys/bus/pci/devices/$OA_BRIDGE/reset" 2>/dev/null || oa_warn "bridge reset write failed"
            sleep 2 ;;
        slot)
            oa_mark "pciehp slot-cycle (cold-plug-equiv)"
            echo 0 > "/sys/bus/pci/slots/$OA_SLOT/power" 2>/dev/null; sleep 3
            echo 1 > "/sys/bus/pci/slots/$OA_SLOT/power" 2>/dev/null; sleep 5 ;;
    esac

    if ! oa_dev_present; then
        oa_mark "DEVICE GONE after $RESET — attempting slot recover"
        oa_slot_recover || { oa_mark "ABORT: device lost, reboot needed"; oa_passive_snapshot "abort"; exit 3; }
    fi

    # BAR1 state after reset (the coupling finding)
    b1="$(oa_bar1_mib)"
    oa_mark "post-reset BAR1=${b1} MiB"
    if [[ "$b1" -lt "$OA_BAR1_MIN_MIB" ]]; then
        oa_mark "BAR1 broke ($b1 MiB) — light ReBAR rewrite"
        setpci -s "$OA_GPU_SHORT" COMMAND=0:3 2>/dev/null
        setpci -s "$OA_GPU_SHORT" "${OA_REBAR_CTRL}.l=${OA_REBAR_VAL}" 2>/dev/null
        sleep 1
        if [[ "$(oa_bar1_mib)" -lt "$OA_BAR1_MIN_MIB" ]]; then
            oa_mark "light rewrite INSUFFICIENT — escalating to slot-cycle (CABLE: ${RESET} needed re-enum for BAR1)"
            oa_slot_recover || { oa_passive_snapshot "abort"; exit 3; }
            NEEDED_SLOT=1
        fi
    fi

    oa_mark "rebind nvidia"
    echo '' > "/sys/bus/pci/devices/$OA_GPU/driver_override" 2>/dev/null
    echo "$OA_GPU" > /sys/bus/pci/drivers/nvidia/bind 2>/dev/null || oa_warn "rebind failed"
    sleep 2
fi

# ---- re-assert Rung 3.5 gate + BAR1 before fire ----
oa_assert_a6 || true
oa_pin_d0
b1f="$(oa_bar1_mib)"
oa_mark "pre-cycle2 BAR1=${b1f} MiB driver=$(basename "$(readlink /sys/bus/pci/devices/$OA_GPU/driver 2>/dev/null || echo none)")"
oa_passive_snapshot "post-reset-pre-cycle2"
[[ "$b1f" -ge "$OA_BAR1_MIN_MIB" ]] || oa_warn "BAR1 still broken pre-cycle2 — cycle-2 may fail on BAR1 not GSP"

sleep "$GAP"

# ---- cycle-2 fire (PMU sampled) ----
oa_mark "sampler start profile:hz:$HZ"
bpftrace -e "profile:hz:${HZ} { @[kstack]=count(); } interval:s:8 { exit(); }" \
    > "$OA_RUNDIR/pmu.log" 2>"$OA_RUNDIR/pmu.err" & SAMP=$!
sleep 1
oa_mark "cycle-2 FIRE (exec open /dev/nvidia0) <<< cure point"
t0=$(date +%s.%N)
timeout 10 bash -c 'exec 3</dev/nvidia0'; c2=$?
t1=$(date +%s.%N)
oa_mark "cycle-2 RETURNED rc=$c2 dt=$(awk "BEGIN{printf \"%.1f\",($t1-$t0)*1000}")ms"
wait "$SAMP" 2>/dev/null

# ---- classify ----
oa_bar1_ok && bok=yes || bok=no
f40=$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo '?')
st=$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_state 2>/dev/null || echo '?')
dmesg 2>/dev/null | tail -40 > "$OA_RUNDIR/dmesg-tail.txt"
A6FIRED=$(grep -c 'open timed out after' "$OA_RUNDIR/dmesg-tail.txt" 2>/dev/null)
verdict="?"
if [[ "$c2" == 0 && "$st" == healthy ]]; then verdict="CURED (cycle-2 clean, state=healthy)"
elif [[ "${A6FIRED:-0}" -ge 1 || "$st" == lost-temporary ]]; then verdict="NOT CURED (A6 fired / lost)"
elif [[ "$b1f" -lt "$OA_BAR1_MIN_MIB" ]]; then verdict="INCONCLUSIVE (BAR1 broken — failed on BAR1 not GSP)"
fi
{
  echo "=== reset-ladder $RESET ==="
  echo "verdict: $verdict"
  echo "cycle-2 rc=$c2  post-fire: bar1_ok=$bok f40b_fires=$f40 state=$st a6_fired=$A6FIRED needed_slot=${NEEDED_SLOT:-0}"
  echo "-- nv stall frame (top) --"
  grep -aA6 '^@\[' "$OA_RUNDIR/pmu.log" 2>/dev/null | grep -aE 'kgsp|RmInit|nv_open|_kgspLockdown|gpuHandleSanity' | sort | uniq -c | sort -rn | head -6
} > "$OA_RUNDIR/VERDICT.txt"
sync
oa_mark "RESETLADDER complete: $verdict"
echo; cat "$OA_RUNDIR/VERDICT.txt"; oa_log "rundir: $OA_RUNDIR"
