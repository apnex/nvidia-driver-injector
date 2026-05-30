#!/usr/bin/env bash
# tools/oa-harness/lib.sh — shared library for the #282 OPEN-arm experiment lanes.
#
# Design constraints (see docs/missions/.../open-arm-forensics-ledger.md):
#   - We run ON the host (obpc). A hard wedge kills this process; forensics MUST
#     be fsync'd to disk BEFORE any step that can wedge. oa_mark() does that.
#   - CHIP-SAFETY: after any wedge/fire the FIRST check is BAR1-via-sysfs. Never
#     run nvidia-smi / MMIO / RPC on a suspected-wedged or broken-BAR1 chip.
#   - One variable per run; n>=3 to resolve; 10s thermal cap on busy-poll runs.
#
# Sourced by the per-rung runners (rung4.sh, precondition.sh, ...).
#
# NOTE: deliberately NOT `set -e` — in a freeze-risk harness we continue past
# non-fatal errors and ALWAYS collect. Errors are handled explicitly.
set -uo pipefail

# ---- host-specific topology (obpc / NUC15 + AORUS RTX5090) ----
OA_GPU_VENDOR="0x10de"
OA_GPU_DEVICE="0x2b85"          # GB202 RTX 5090
OA_ARCH_BASE="/var/log/mission-1-archaeology"
OA_INJECTOR_NS="kube-system"
OA_INJECTOR_DS="nvidia-driver-injector"
OA_BAR1_MIN_MIB=32768           # 32 GiB
OA_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

oa_log()  { printf '[oa] %s\n' "$*"; }
oa_warn() { printf '[oa] WARN: %s\n' "$*" >&2; }
oa_die()  { printf '[oa] FATAL: %s\n' "$*" >&2; exit 1; }

# ---- discovery (auto-detect; tuned for this single-host topology) ----
oa_discover() {
    OA_GPU=""
    for d in /sys/bus/pci/devices/*; do
        [[ -r "$d/vendor" && -r "$d/device" ]] || continue
        [[ "$(<"$d/vendor")" == "$OA_GPU_VENDOR" && "$(<"$d/device")" == "$OA_GPU_DEVICE" ]] || continue
        OA_GPU="$(basename "$d")"; break
    done
    [[ -n "$OA_GPU" ]] || oa_die "no GPU ${OA_GPU_VENDOR}:${OA_GPU_DEVICE} found"
    OA_GPU_SHORT="${OA_GPU#0000:}"
    OA_AUD="${OA_GPU%.*}.1"
    [[ -e "/sys/bus/pci/devices/$OA_AUD" ]] || OA_AUD=""
    # TB device = first non-controller (N-M, M!=0) — the AORUS box is 0-1
    OA_TB=""
    for t in /sys/bus/thunderbolt/devices/[0-9]-[0-9]; do
        [[ -f "$t/authorized" ]] || continue
        local b; b="$(basename "$t")"
        [[ "$b" == *-0 ]] && continue
        OA_TB="$b"; break
    done
    oa_log "GPU=$OA_GPU audio=${OA_AUD:-none} TB=${OA_TB:-none}"
}

# ---- run dir + manifest ----
# oa_init_run <name>  — sets OA_RUNDIR, writes manifest, arms sysrq.
oa_init_run() {
    local name="$1"
    local ts; ts="$(date -u +%Y%m%dT%H%M%SZ)"
    OA_RUNDIR="${OA_ARCH_BASE}/${name}-${ts}"
    mkdir -p "$OA_RUNDIR" || oa_die "cannot mkdir $OA_RUNDIR"
    {
        echo "run=${name}"
        echo "utc_start=${ts}"
        echo "host=$(hostname)"
        echo "kernel=$(uname -r)"
        echo "cmdline=$(cat /proc/cmdline)"
        echo "driver_version=$(cat /sys/module/nvidia/version 2>/dev/null || echo '(unloaded)')"
        echo "git_head=$(cd "$OA_REPO_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo '?')"
        echo "gpu=${OA_GPU} audio=${OA_AUD} tb=${OA_TB}"
    } > "$OA_RUNDIR/MANIFEST.txt"
    : > "$OA_RUNDIR/markers.log"
    oa_arm_sysrq
    oa_log "run dir: $OA_RUNDIR"
}

# ---- the cross-host-death forensic anchor ----
# oa_mark <msg> — append an fsync'd, timestamped marker. Call this IMMEDIATELY
# before AND after every step that can wedge the host. The fsync is what makes
# the marker survive a hard kernel lock (5 of 6 2026-05-29 archives lost their
# trigger BECAUSE journald never flushed — this is the fix).
oa_mark() {
    local msg="$*"
    local line; line="$(date -u +%H:%M:%S.%3N) ${msg}"
    printf '%s\n' "$line" >> "$OA_RUNDIR/markers.log"
    sync                                  # flush to disk — survives the wedge
    printf '<5>oa-mark: %s\n' "$msg" > /dev/kmsg 2>/dev/null || true
    oa_log "MARK: $msg"
}

oa_arm_sysrq() { echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || oa_warn "could not arm sysrq"; }

# ---- BAR1 (the FIRST post-wedge check) ----
oa_bar1_mib() {
    local line start end
    line="$(sed -n '2p' "/sys/bus/pci/devices/${OA_GPU}/resource" 2>/dev/null)" || { echo -1; return; }
    read -r start end _ <<< "$line"
    [[ -n "$start" && -n "$end" ]] || { echo -1; return; }
    echo $(( ( (end - start + 1) ) / 1024 / 1024 ))   # bash auto-parses 0x..
}
oa_bar1_ok() { local m; m="$(oa_bar1_mib)"; [[ "$m" -ge "$OA_BAR1_MIN_MIB" ]]; }

# ---- passive forensic snapshot (NO nvidia-smi / NO MMIO) ----
# oa_passive_snapshot <label>
oa_passive_snapshot() {
    local label="$1"
    local out="$OA_RUNDIR/snap-${label}.txt"
    {
        echo "=== passive snapshot: ${label} @ $(date -Iseconds) ==="
        echo "--- BAR1 (sysfs) ---"; echo "  BAR1=$(oa_bar1_mib) MiB"
        echo "--- power/link (sysfs) ---"
        for f in power/control power/runtime_status current_link_speed current_link_width; do
            printf '  %-22s %s\n' "$f" "$(cat /sys/bus/pci/devices/$OA_GPU/$f 2>&1)"
        done
        echo "--- driver bind ---"
        echo "  driver=$(basename "$(readlink /sys/bus/pci/devices/$OA_GPU/driver 2>/dev/null || echo none)")"
        echo "  module_version=$(cat /sys/module/nvidia/version 2>/dev/null || echo '(unloaded)')"
        echo "  tb_egpu_state=$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_state 2>/dev/null || echo n/a)"
        echo "  f40b_fires=$(cat /sys/bus/pci/devices/$OA_GPU/tb_egpu_f40b_fires 2>/dev/null || echo n/a)"
        echo "--- AER config-space (setpci, config TLPs only) ---"
        # device + upstream bridge AER uncorrectable/correctable status
        local AERCAP
        AERCAP=$(setpci -s "$OA_GPU_SHORT" ECAP_AER+0x04.l 2>/dev/null || echo '?')
        echo "  device UESta(AER+0x04)=$AERCAP"
        echo "  device CESta(AER+0x10)=$(setpci -s "$OA_GPU_SHORT" ECAP_AER+0x10.l 2>/dev/null || echo '?')"
        local PARENT
        PARENT=$(basename "$(readlink -f /sys/bus/pci/devices/$OA_GPU/.. 2>/dev/null)")
        PARENT="${PARENT#0000:}"
        echo "  parent bridge=$PARENT"
        echo "  bridge UESta=$(setpci -s "$PARENT" ECAP_AER+0x04.l 2>/dev/null || echo '?')"
        echo "  bridge CESta=$(setpci -s "$PARENT" ECAP_AER+0x10.l 2>/dev/null || echo '?')"
        echo "--- dmesg tail (50) ---"
        dmesg 2>/dev/null | tail -50
    } > "$out" 2>&1
    sync
    oa_log "snapshot -> $out"
}

# ---- Rung 3.5 entry gate: assert A6 present + pin chip at D0 ----
oa_assert_a6() {
    local v; v="$(cat /sys/module/nvidia/version 2>/dev/null || echo '')"
    [[ "$v" == *apnex* || "$v" == *aorus.1[89]* || "$v" == *aorus.2* ]] \
        || oa_die "loaded module '$v' may NOT carry A6 (need apnex / aorus.18-f40b+)"
    [[ -r /sys/module/nvidia/parameters/NVreg_TbEgpuOpenTimeoutMs ]] \
        || oa_die "NVreg_TbEgpuOpenTimeoutMs absent — A6 not in this module"
    local budget; budget="$(cat /sys/module/nvidia/parameters/NVreg_TbEgpuOpenTimeoutMs)"
    oa_log "A6 present: version=$v open_timeout=${budget}ms"
    [[ "$budget" -gt 0 ]] || oa_warn "open_timeout=0 — A6 DISABLED (this is the DESTRUCTIVE lane)"
}
oa_pin_d0() {
    echo on > "/sys/bus/pci/devices/$OA_GPU/power/control" 2>/dev/null || oa_warn "GPU pin D0 failed"
    [[ -n "$OA_AUD" ]] && { echo on > "/sys/bus/pci/devices/$OA_AUD/power/control" 2>/dev/null || oa_warn "audio pin D0 failed"; }
    local st; st="$(cat /sys/bus/pci/devices/$OA_GPU/power/runtime_status 2>/dev/null)"
    oa_log "D0 pin: GPU control=$(cat /sys/bus/pci/devices/$OA_GPU/power/control) status=$st"
    [[ "$st" == "active" ]] || oa_warn "GPU runtime_status=$st (expected active)"
}
