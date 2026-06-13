#!/usr/bin/env bash
# e2-verify.sh — hardened, operator-gated runbook for the E27 "E2-verify" live test.
#
# Decides whether the in-kernel light-reset (resize -> FLR -> verify-before-bind)
# DETERMINISTICALLY recovers a TB-hot-add broken BAR1 (256 MiB instead of 32 GiB),
# so we can retire the userspace fix-bar1.sh slot-cycle. It drives the
# tbegpu_bar1_rearm module, then binds nvidia and scores the cycle ONLY by
# RmInitAdapter (the module's RESULT=OK is a confirmed false-positive surface).
#
# This script encodes the controls the 2026-06-14 pre-flight review found MISSING
# in the original manual procedure — the two gaps that already cost a host wedge
# (E1) and a firmware/platform RAS reset (E2 cycle-2):
#   * recover=0 PROVEN via a resolved-arg modprobe dry-run + the loaded-module
#     param (not `modprobe -c | grep`, which shows both =1 and =0 lines).
#   * the bind+verdict+fail-safe is ONE atomic, un-loopable step: a single device
#     open; on FAIL it rmmods IMMEDIATELY and never re-opens (the 11-retry hammering
#     on a desynced aperture is what escalated cycle-2 to a platform reset).
#   * reset_method pinned to flr so pci_reset_function cannot silently escalate to a
#     link-down slot/bus reset during the lock-dropped settle.
#   * substrate ASSERTED every cycle (BAR1==256 MiB exactly AND chip ReBAR
#     nibble==8) — a wrong substrate is a misleading data point (the Stage-1 trap).
#   * nvidia-persistenced masked + injector drained so no auto-consumer opens the
#     device in the fail window; on PASS persistence is engaged BEFORE the verifying
#     query (fix-bar1 close-path hazard).
#
# ⚠ WET PCI SURGERY + GPU init. Operator AT THE CONSOLE, capture armed, no cable
# touch. Interrupts + resets the apnex soak. The assistant runs ON this host — a
# hard wedge kills the session; capture (netconsole + sysrq) is the only forensic net.
#
# Usage (run as root; each verb is a deliberate step):
#   sudo ./e2-verify.sh preflight                 # one-time: drain, pin, drop-in, proofs, mask
#   sudo ./e2-verify.sh status                    # print current state, any time
#   sudo ./e2-verify.sh cycle <i> <settle_ms> [verify]   # one full data point (verify default 1)
#       # or step-by-step for max control:
#   sudo ./e2-verify.sh substrate                 # make + assert a fresh 256 MiB substrate
#   sudo ./e2-verify.sh rearm <settle_ms> [verify]# run the module; reports RESULT=
#   sudo ./e2-verify.sh bind                       # ATOMIC: modprobe + one open + verdict + fail-safe
#   sudo ./e2-verify.sh restore                    # recover the chip (fix-bar1 --bind), keep drop-in
#   sudo ./e2-verify.sh teardown                   # remove drop-in, unmask, un-drain, unpin, done
#
# DECISION RULE (pre-registered): one settle-FAIL (0x24:0x72:1307 / kbusVerifyBar2)
# at the adopted settle REFUTES determinism — do NOT retire fix-bar1. A determinism
# claim needs >=10-12 consecutive clean binds on independently re-deauth/reauth'd
# substrates. n>=3 is "promising", never "deterministic".

set -uo pipefail   # NOTE: no -e — we handle errors explicitly so a fail-safe always runs

# ---------- config (override via env) ----------
GPU=${GPU:-0000:04:00.0}
TB_DEV=${TB_DEV:-0-1}
ROOT_PORT=${ROOT_PORT:-0000:00:07.0}
RX=${RX:-192.168.1.241}                 # netconsole receiver (informational)
DS_NS=${DS_NS:-kube-system}
DS_NAME=${DS_NAME:-nvidia-driver-injector}
DROPIN=/etc/modprobe.d/zz-e27-recover-off.conf
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD=tbegpu_bar1_rearm
KO="$HERE/${MOD}.ko"
FIXBAR1="$HERE/../fix-bar1.sh"
RECOVER_PARAM=/sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable

log()   { printf '[e2-verify] %s\n' "$*"; }
warn()  { printf '[e2-verify] WARN: %s\n' "$*" >&2; }
fatal() { printf '[e2-verify] ERROR: %s\n' "$*" >&2; exit 1; }
mark()  { echo "E2-VERIFY $* $(date -u +%FT%TZ)" > /dev/kmsg 2>/dev/null || true; }  # survives via netconsole

[[ $EUID -eq 0 ]] || fatal "run as root"
[[ -f "$KO" ]]    || fatal "module not built: $KO (run: make -C $HERE)"

# ---------- topology / chip reads ----------
rebar_cap_off() {   # echo 0xNN ReBAR cap offset, or empty (capture-first to avoid SIGPIPE under pipefail)
    local out; out=$(lspci -s "${GPU#0000:}" -vv 2>/dev/null || true)
    awk 'match($0,/Capabilities: \[([0-9a-f]+) v[0-9]+\] Physical Resizable BAR/,m){print "0x"m[1]; exit}' <<<"$out"
}
rebar_ctrl_nibble() {   # echo the chip's current ReBAR size encoding (8=256M, 15=32G), or -1
    local cap off val
    cap=$(rebar_cap_off); [[ -n "$cap" ]] || { echo -1; return; }
    off=$(printf '0x%x' $(( cap + 8 )))
    val=$(setpci -s "${GPU#0000:}" "${off}.l" 2>/dev/null) || { echo -1; return; }
    [[ "$val" =~ ^[0-9a-fA-F]+$ ]] || { echo -1; return; }
    echo $(( (0x$val >> 8) & 0x3f ))
}
bar1_mib() {   # strict integer MiB of GPU BAR1 (resource line 2); 0 if unset/off-bus (#304)
    local f="/sys/bus/pci/devices/$GPU/resource" s e
    [[ -r "$f" ]] || { echo 0; return; }
    read -r s e < <(awk 'NR==2{print $1,$2;exit}' "$f") || { echo 0; return; }
    [[ "$s" =~ ^0x[0-9a-fA-F]+$ && "$e" =~ ^0x[0-9a-fA-F]+$ ]] || { echo 0; return; }
    (( s==0 && e==0 )) && { echo 0; return; }
    (( e < s )) && { echo 0; return; }
    echo $(( (e - s + 1) / 1024 / 1024 ))
}
nvidia_loaded() { lsmod | awk '$1=="nvidia"{f=1} END{exit !f}'; }
driver_bound()  { [[ -L "/sys/bus/pci/devices/$GPU/driver" ]]; }

assert_unbound() {   # nvidia fully gone + no driver on the GPU (the deauth precondition)
    nvidia_loaded && fatal "nvidia still loaded — rmmod first (a deauth with the driver bound = surprise-removal wedge)"
    driver_bound  && fatal "GPU $GPU still has a driver bound — unbind first"
    return 0
}

# The on-host session's ONLY forensic/recovery net. Re-asserted AT each wet step
# (not just preflight) — a hard wedge kills the session; without capture it is silent.
assert_capture_armed() {
    [[ "$(cat /sys/kernel/config/netconsole/*/enabled 2>/dev/null | head -1)" == "1" ]] \
        || fatal "netconsole capture NOT armed — the on-host session's only net. Arm it first:
  tools/oa-harness/arm-wedge-capture.sh arm $RX"
    [[ "$(cat /proc/sys/kernel/hardlockup_panic 2>/dev/null)" == "1" ]] \
        || fatal "hardlockup_panic != 1 — run: echo 1 > /proc/sys/kernel/{soft,hard}lockup_panic"
}

assert_flr_pinned() {   # refuse to FLR an unpinned device (link-down-reset escalation risk)
    [[ "$(cat /sys/bus/pci/devices/$GPU/reset_method 2>/dev/null)" == "flr" ]] \
        || fatal "reset_method not pinned to 'flr' — refusing to load the module (pci_reset_function could escalate to a link-down slot/bus reset during the settle)"
}

pin_flr() {   # pin reset_method=flr so pci_reset_function can't escalate to a link-down reset
    local rm="/sys/bus/pci/devices/$GPU/reset_method"
    [[ -e "$rm" ]] || { warn "no $rm (device absent?) — cannot pin reset_method"; return 1; }
    echo flr > "$rm" 2>/dev/null || { warn "could not write reset_method"; return 1; }
    local got; got=$(cat "$rm" 2>/dev/null)
    [[ "$got" == "flr" ]] || { warn "reset_method pin did not stick (got '$got')"; return 1; }
    log "reset_method pinned to 'flr' ✓"
}

drain_injector() {
    kubectl patch ds -n "$DS_NS" "$DS_NAME" --type merge \
      -p '{"spec":{"template":{"spec":{"nodeSelector":{"oa.recovery-drain/excluded":"true"}}}}}' >/dev/null 2>&1 \
      || warn "injector DS drain patch failed (not k8s?)"
    kubectl delete pod -n "$DS_NS" -l app.kubernetes.io/name="$DS_NAME" --wait=true --timeout=60s >/dev/null 2>&1 || true
}
undrain_injector() {
    kubectl patch ds -n "$DS_NS" "$DS_NAME" --type merge \
      -p '{"spec":{"template":{"spec":{"nodeSelector":null}}}}' >/dev/null 2>&1 || warn "injector un-drain failed"
}
quiesce_nvidia() {   # unload WITHOUT touching nvidia-smi — a query on a desynced chip is the
                     # forbidden retry (it escalated cycle-2 to a platform reset). Leave
                     # persistence as-is (an -pm 0 here would also flip a recovered chip's
                     # close-path back to the wedge route). rmmod is the least-bad teardown.
    rmmod nvidia_uvm 2>/dev/null || true
    rmmod nvidia_drm 2>/dev/null || true
    rmmod nvidia     2>/dev/null || true
}

# ---------- verbs ----------
do_preflight() {
    log "=== PREFLIGHT (one-time) ==="
    # cmdline preconditions the resize relies on
    local c; c=$(cat /proc/cmdline)
    [[ "$c" == *hpmmioprefsize=32G* ]] || fatal "cmdline missing pci=hpmmioprefsize=32G"
    [[ "$c" == *realloc=on*         ]] || warn  "cmdline missing pci=realloc=on"
    log "cmdline OK (hpmmioprefsize=32G$([[ "$c" == *realloc=on* ]] && echo ', realloc=on'))"

    # capture must be armed (the only net once recover=0 disables in-driver AER recovery)
    if [[ "$(cat /sys/kernel/config/netconsole/*/enabled 2>/dev/null | head -1)" == "1" ]]; then
        log "netconsole capture armed ✓ (receiver $RX)"
    else
        warn "netconsole does NOT look armed — arm it before any wet step:"
        warn "  tools/oa-harness/arm-wedge-capture.sh arm $RX  &&  echo 1 > /proc/sys/kernel/{soft,hard}lockup_panic"
    fi
    [[ "$(cat /proc/sys/kernel/hardlockup_panic 2>/dev/null)" == "1" ]] || warn "hardlockup_panic != 1 (recommended for the soft-wedge class)"

    # block ALL auto-consumers that could open the device in the fail window
    if systemctl list-unit-files nvidia-persistenced.service >/dev/null 2>&1; then
        systemctl mask --now nvidia-persistenced >/dev/null 2>&1 && log "nvidia-persistenced masked ✓" \
            || warn "could not mask nvidia-persistenced"
    else
        log "nvidia-persistenced not present (nothing to mask)"
    fi
    drain_injector; log "injector drained"
    quiesce_nvidia; assert_unbound; log "nvidia unloaded, $GPU unbound ✓"

    # recover=0 drop-in + the AUTHORITATIVE resolved-arg proof
    printf 'options nvidia NVreg_TbEgpuRecoverEnable=0\n' > "$DROPIN"
    log "wrote $DROPIN"
    local resolved
    resolved=$(modprobe -n -v --ignore-install nvidia 2>/dev/null | tr ' ' '\n' | grep -i 'TbEgpuRecoverEnable' | tail -1)
    log "resolved insmod arg (last wins): '${resolved:-<none>}'"
    [[ "$resolved" == *NVreg_TbEgpuRecoverEnable=0 ]] \
        || fatal "recover=0 NOT proven — resolved modprobe arg is '${resolved:-<none>}', expected ...=0. Do NOT proceed."
    log "recover=0 PROVEN at the resolved-arg level ✓"

    pin_flr || warn "reset_method not pinned (device may be absent now — re-pinned each cycle after reauth)"
    log "PREFLIGHT done. Next: ./e2-verify.sh cycle 1 2000"
}

do_substrate() {
    log "=== SUBSTRATE (fresh broken-256M) ==="
    assert_capture_armed
    drain_injector
    quiesce_nvidia
    assert_unbound
    log "deauth/reauth TB $TB_DEV ..."
    echo 0 > "/sys/bus/thunderbolt/devices/$TB_DEV/authorized" 2>/dev/null || fatal "TB deauth failed ($TB_DEV present?)"
    sleep 4
    echo 1 > "/sys/bus/thunderbolt/devices/$TB_DEV/authorized" 2>/dev/null || fatal "TB reauth failed"
    # wait for the GPU to re-enumerate
    local i=0
    while [[ ! -e "/sys/bus/pci/devices/$GPU" ]] && (( i < 20 )); do sleep 0.5; i=$((i+1)); done
    [[ -e "/sys/bus/pci/devices/$GPU" ]] || fatal "GPU $GPU did not return after reauth — check journalctl"
    sleep 2
    # ASSERT the substrate is the real chip-CTRL-reset broken-256M state
    local b n; b=$(bar1_mib); n=$(rebar_ctrl_nibble)
    log "post-reauth: BAR1=${b} MiB, chip ReBAR nibble=${n} (8=256M, 15=32G)"
    (( b == 256 )) || fatal "substrate INVALID: BAR1=${b} MiB, expected exactly 256 (0=off-bus, 32768=already healthy). Abort cycle."
    (( n == 8 ))   || fatal "substrate INVALID: chip ReBAR nibble=${n}, expected 8. Abort cycle."
    pin_flr || fatal "reset_method re-pin failed after reauth — refusing to FLR an unpinned device (link-down reset risk)"
    log "substrate VALID ✓ (256 MiB, nibble 8)"
}

do_rearm() {   # $1=settle_ms  $2=verify(0|1, default 1)
    local settle="${1:?usage: rearm <settle_ms> [verify]}" v="${2:-1}"
    assert_capture_armed
    assert_unbound
    [[ "$(rebar_ctrl_nibble)" == "8" && "$(bar1_mib)" == "256" ]] \
        || fatal "refusing to rearm: substrate is not 256M/nibble-8 (run 'substrate' first)"
    assert_flr_pinned   # the module is about to call pci_reset_function
    rmmod "$MOD" 2>/dev/null || true
    local stamp sentinel
    stamp=$(date -u +%s 2>/dev/null || echo x)
    sentinel="E2VERIFY-REARM-$$-$stamp"
    echo "$sentinel" > /dev/kmsg 2>/dev/null || true
    log "insmod $MOD dry_run=0 flr=1 verify=$v settle_ms=$settle"
    if ! insmod "$KO" gpu="$GPU" dry_run=0 flr=1 verify="$v" settle_ms="$settle"; then
        warn "insmod failed (check dmesg)"; return 1
    fi
    sleep 1
    local slice; slice=$(dmesg | sed -n "/$sentinel/,\$p")
    grep 'tbegpu-rearm:' <<<"$slice" | tail -30 | sed 's/^/    /'
    local result; result=$(grep -oE 'RESULT=[A-Z]+[^\n]*' <<<"$slice" | tail -1)
    rmmod "$MOD" 2>/dev/null || warn "rmmod $MOD failed (module wedged?)"
    log "module ${result:-<no RESULT line — inspect dmesg>}"
    [[ "$result" == RESULT=OK* ]]
}

# ATOMIC bind+verdict+fail-safe. Single device open. On FAIL: rmmod NOW, never re-open.
do_bind() {
    log "=== BIND (atomic single-shot) ==="
    assert_capture_armed
    assert_unbound
    lsmod | grep -q "^$MOD " && fatal "$MOD still loaded — rmmod it before bind"
    mark "BIND-START gpu=$GPU"
    local sentinel stamp
    stamp=$(date -u +%s 2>/dev/null || echo x)
    sentinel="E2VERIFY-BIND-$$-$stamp"
    echo "$sentinel" > /dev/kmsg 2>/dev/null || true

    log "modprobe --ignore-install nvidia"
    if ! modprobe --ignore-install nvidia; then
        warn "modprobe failed"; quiesce_nvidia; mark "BIND-FAIL modprobe"; return 1
    fi
    # recover=0 MUST be live at the loaded-module level, else a FAIL fires the A3 retry-wedge
    local rec; rec=$(cat "$RECOVER_PARAM" 2>/dev/null)
    if [[ "$rec" != "0" ]]; then
        warn "recover=$rec at loaded-module level (expected 0) — aborting + rmmod (A3 retry-wedge risk)"
        quiesce_nvidia; mark "BIND-ABORT recover=$rec"; fatal "recover!=0 after modprobe — host suspect, drop-in/ordering broke"
    fi
    log "recover=0 confirmed at loaded-module level ✓"

    if ! driver_bound; then
        warn "nvidia loaded but did NOT bind $GPU"; quiesce_nvidia; mark "BIND-FAIL no-bind"; return 1
    fi

    # THE single open: triggers RmInitAdapter AND engages persistence on success.
    log "single open: nvidia-smi -pm 1 (triggers RmInitAdapter; persistence-first per fix-bar1)"
    local smi_rc=0
    timeout 20 nvidia-smi -pm 1 >/tmp/e2-smi.$$ 2>&1; smi_rc=$?
    sed 's/^/    /' /tmp/e2-smi.$$; rm -f /tmp/e2-smi.$$

    # classify from dmesg AFTER the sentinel (survives a truncated capture if marked)
    local slice; slice=$(dmesg | sed -n "/$sentinel/,\$p")
    local trip; trip=$(grep -oE 'RmInitAdapter failed! \(0x[0-9a-fx:]+\)' <<<"$slice" | tail -1)
    local recover_fired; recover_fired=$(grep -oE 'tb_egpu recover: scheduling recovery|pci_reset_bus' <<<"$slice" | tail -1)

    if [[ -n "$recover_fired" ]]; then
        warn "RECOVER FIRED ('$recover_fired') — data point CONTAMINATED + host SUSPECT"
        quiesce_nvidia; mark "BIND-CONTAM recover-fired"; return 2
    fi

    if (( smi_rc == 0 )) && [[ -z "$trip" ]]; then
        # PASS — persistence already engaged; ONE more query is now safe
        local bar1; bar1=$(timeout 15 nvidia-smi -q 2>/dev/null | awk '/BAR1 Memory/{g=1} g&&/Total/{print $(NF-1); exit}')
        log "PASS ✓ — RmInitAdapter clean; nvidia-smi BAR1 Total: ${bar1:-?} MiB"
        mark "BIND-PASS bar1=${bar1:-?}"
        return 0
    fi

    # FAIL — fail-safe FIRST, classify SECOND, NEVER re-open
    warn "BIND FAILED (nvidia-smi rc=$smi_rc, triplet='${trip:-none}') — rmmod NOW, no retry"
    quiesce_nvidia
    local verdict_rc=1
    case "$trip" in
        *0x24:0x72:1307*) warn "classify: SETTLE-FAIL (kbusVerifyBar2 / aperture not re-fenced) — DETERMINISM REFUTED per the pre-registered rule: do NOT retire fix-bar1; STOP."; verdict_rc=3 ;;
        *0x22:0x38:859*)  warn "classify: WRONG-SUBSTRATE/placement (0x22:0x38:859) — discard, re-examine substrate" ;;
        *0x62:0x40:2131*) warn "classify: SECOND-OPEN/WPR2 (0x62:0x40:2131) — fail-safe was violated; discard + host suspect" ;;
        "")               warn "classify: no RmInitAdapter triplet (modprobe/probe-level or smi timeout) — inspect dmesg" ;;
        *)                warn "classify: other triplet $trip — inspect dmesg" ;;
    esac
    mark "BIND-FAIL trip=${trip:-none}"
    return $verdict_rc
}

do_cycle() {   # $1=index $2=settle_ms $3=verify(default 1) — one full data point
    local i="${1:?usage: cycle <i> <settle_ms> [verify]}" settle="${2:?usage: cycle <i> <settle_ms> [verify]}" v="${3:-1}"
    log "########## CYCLE $i (settle_ms=$settle verify=$v) ##########"
    do_substrate || { warn "cycle $i: substrate failed"; return 1; }
    mark "CYCLE $i settle=$settle verify=$v substrate-BAR1=256M"
    if ! do_rearm "$settle" "$v"; then
        # The substrate was asserted VALID (256M/nibble-8), so a no-OK rearm is the
        # light-reset failing to reach a bindable state — a RECORDED NEGATIVE data
        # point counting AGAINST determinism, NOT a discard.
        warn "cycle $i: module did NOT report RESULT=OK on a VALID substrate — NEGATIVE data point (recovery did not reach a bindable state)."
        log  "cycle $i VERDICT: REARM-FAIL (negative — counts against determinism; no bind attempted)"
        sync; return 1
    fi
    do_bind; local rc=$?
    case $rc in
        0) log  "cycle $i VERDICT: PASS" ;;
        2) warn "cycle $i VERDICT: CONTAMINATED (recover fired) — STOP, investigate host" ;;
        3) warn "cycle $i VERDICT: SETTLE-FAIL → DETERMINISM REFUTED per the pre-registered rule — STOP; do NOT retire fix-bar1" ;;
        *) log  "cycle $i VERDICT: BIND-FAIL (see classify above)" ;;
    esac
    sync
    return $rc
}

do_restore() {
    log "=== RESTORE (recover the chip; KEEP recover=0 belt) ==="
    quiesce_nvidia
    log "fix-bar1 --bind (proven pciehp slot-cycle recovery + persistence)"
    "$FIXBAR1" --bind || warn "fix-bar1 --bind reported a problem — inspect manually"
    local b; b=$(bar1_mib)
    (( b >= 32768 )) && log "chip healthy: BAR1=${b} MiB ✓" || warn "BAR1=${b} MiB after restore — NOT healthy, investigate"
    log "drop-in left in place across the recovery bind by design; run 'teardown' when fully done."
}

do_teardown() {
    log "=== TEARDOWN (end of session) ==="
    rm -f "$DROPIN" && log "removed $DROPIN"
    echo default > "/sys/bus/pci/devices/$GPU/reset_method" 2>/dev/null && log "reset_method unpinned (default)" || true
    systemctl unmask nvidia-persistenced >/dev/null 2>&1 && log "nvidia-persistenced unmasked" || true
    undrain_injector; log "injector un-drained (it will re-adopt the driver)"
    log "Capture left armed — disarm manually when done: tools/oa-harness/arm-wedge-capture.sh disarm"
    log "Soak clock is reset — restart the apnex.33 14-day soak from a clean idle baseline."
}

do_status() {
    log "=== STATUS ==="
    printf '  BAR1            : %s MiB\n' "$(bar1_mib)"
    printf '  chip ReBAR nib  : %s (8=256M, 15=32G, -1=unreadable)\n' "$(rebar_ctrl_nibble)"
    printf '  nvidia loaded   : %s\n' "$(nvidia_loaded && echo yes || echo no)"
    printf '  driver bound    : %s\n' "$(driver_bound && readlink -f /sys/bus/pci/devices/$GPU/driver || echo none)"
    printf '  recover (loaded): %s\n' "$(cat "$RECOVER_PARAM" 2>/dev/null || echo n/a)"
    printf '  reset_method    : %s\n' "$(cat /sys/bus/pci/devices/$GPU/reset_method 2>/dev/null || echo n/a)"
    printf '  recover drop-in : %s\n' "$([[ -f "$DROPIN" ]] && echo present || echo absent)"
    printf '  persistenced    : %s\n' "$(systemctl is-enabled nvidia-persistenced 2>/dev/null || echo n/a)"
    printf '  capture armed   : %s\n' "$([[ "$(cat /sys/kernel/config/netconsole/*/enabled 2>/dev/null | head -1)" == "1" ]] && echo yes || echo no)"
    local resolved; resolved=$(modprobe -n -v --ignore-install nvidia 2>/dev/null | tr ' ' '\n' | grep -i TbEgpuRecoverEnable | tail -1)
    printf '  recover resolved: %s\n' "${resolved:-<none>}"
}

# ---------- dispatch ----------
case "${1:-}" in
    preflight) do_preflight ;;
    substrate) do_substrate ;;
    rearm)     shift; do_rearm "$@" ;;
    bind)      do_bind ;;
    cycle)     shift; do_cycle "$@" ;;
    restore)   do_restore ;;
    teardown)  do_teardown ;;
    status)    do_status ;;
    *) cat >&2 <<EOF
usage: $0 <verb> [args]
  preflight                      one-time: drain, mask, drop-in + recover=0 proof, pin flr
  status                         print current state
  cycle <i> <settle_ms> [verify] one full data point (verify default 1)
  substrate                      make + assert a fresh 256 MiB substrate
  rearm <settle_ms> [verify]     run the module; reports RESULT=
  bind                           ATOMIC modprobe + one open + verdict + fail-safe
  restore                        recover the chip via fix-bar1 --bind (keeps drop-in)
  teardown                       remove drop-in, unmask, un-drain, unpin
EOF
       exit 2 ;;
esac
