#!/usr/bin/env bash
# cap-retest-probe.sh — controlled bridge-link-cap retest probe.
#
# Purpose
# -------
# Reproduce the 2026-05-10 freeze conditions in a controlled way so a
# kernel deadlock leaves analyzable evidence on disk instead of being
# lost to a power-cycle.
#
# Methodology (per feedback_freeze_risk_methodology + reliability ledger)
# ------------------------------------------------------------------
# 1. fsync after every progress marker so a freeze can't lose state
# 2. Sysfs-only probes first (no /dev/nvidia0 open) — cheap experiments
#    before expensive ones
# 3. ONE controlled trigger (`nvidia-smi -L` — same op that wedged us)
# 4. Wait + post-capture
# 5. n=1 per user request 2026-05-10; promote to n=3 if outcome merits
#
# Pre-requisites
# --------------
# - Reboot has just happened, so bridge-link-cap.service applied the
#   intended cap config at boot (verify in step 0)
# - Driver-injector container is running with the patched module loaded
# - GPU should NOT have been touched yet by anything else (e.g. you
#   running `nvidia-smi` manually) before this probe — that's the
#   workload class we're characterising
#
# Output
# ------
# /root/nvidia-driver-injector/archive/cap-retest-probes/<run-id>/
#   00-config.txt            — what cap config we expected this run
#   01-cap-state.txt         — bridge LnkCtl2/LnkSta + GPU LnkSta
#   02-aer-baseline.txt      — AER counters before trigger
#   03-dmesg-pre.log         — dmesg before trigger
#   04-sysfs-probe.txt       — sysfs reads (no /dev/nvidia* open)
#   05-trigger-output.txt    — nvidia-smi -L output + exit
#   06-dmesg-post.log        — dmesg after trigger + settle
#   07-aer-post.txt          — AER counters after
#   08-cap-state-post.txt    — cap state after (did link drop?)
#   run.log                  — timestamped progression of the probe
#
# If the host freezes mid-probe, run.log + the last-written numbered
# file tell you exactly which step was active when the freeze fired.

set -u

REPO_ROOT="${REPO_ROOT:-/root/nvidia-driver-injector}"
GPU_VENDOR="0x10de"
GPU_DEVICE="0x2b85"
WAIT_SETTLE="${WAIT_SETTLE:-10}"

# locate GPU + bridge BDFs
detect_gpu_bdf() {
    local d v dv
    for d in /sys/bus/pci/devices/*; do
        [[ -r "$d/vendor" && -r "$d/device" ]] || continue
        v=$(<"$d/vendor"); dv=$(<"$d/device")
        if [[ "$v" == "$GPU_VENDOR" && "$dv" == "$GPU_DEVICE" ]]; then
            basename "$(readlink -f "$d")"
            return 0
        fi
    done
    return 1
}

GPU_BDF="$(detect_gpu_bdf || true)"
if [[ -z "$GPU_BDF" ]]; then
    echo "GPU not present (vendor=$GPU_VENDOR device=$GPU_DEVICE) — eGPU disconnected?" >&2
    exit 1
fi
BRIDGE_BDF="$(basename "$(dirname "$(readlink -f "/sys/bus/pci/devices/$GPU_BDF")")")"

if [[ "$EUID" -ne 0 ]]; then
    echo "cap-retest-probe.sh must be run as root" >&2
    exit 1
fi

RUN_ID="$(date -Iseconds | tr ':' '-')"
RUN_DIR="$REPO_ROOT/archive/cap-retest-probes/$RUN_ID"
mkdir -p "$RUN_DIR"
LOG="$RUN_DIR/run.log"

# fsync'd progress marker — a freeze can't lose this state
mark() {
    local m="$*"
    printf '[%s] %s\n' "$(date -Iseconds)" "$m" | tee -a "$LOG"
    sync
}

# write content to a file then fsync the file
fsync_write() {
    local f="$1" content="$2"
    printf '%s' "$content" > "$f"
    sync "$f" 2>/dev/null || sync
}

# write the *output* of a command to a file with fsync
fsync_capture() {
    local f="$1"
    shift
    "$@" > "$f" 2>&1 || true
    sync "$f" 2>/dev/null || sync
}

mark "=== cap-retest-probe start ==="
mark "GPU BDF:    $GPU_BDF"
mark "Bridge BDF: $BRIDGE_BDF"
mark "Run dir:    $RUN_DIR"

# ----------------------------------------------------------------------
# Step 0 — record the cap config we EXPECT (env override, binary defaults)
# ----------------------------------------------------------------------
mark "step 0: record expected config"
{
    echo "=== systemd unit Environment ==="
    systemctl show -p Environment nvidia-driver-injector-bridge-link-cap.service 2>/dev/null
    echo
    echo "=== drop-in overrides ==="
    ls -la /etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service.d/ 2>/dev/null || echo "(none)"
    echo
    echo "=== drop-in contents ==="
    grep -RH . /etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service.d/ 2>/dev/null || echo "(none)"
    echo
    echo "=== service status (first 30 lines) ==="
    systemctl status nvidia-driver-injector-bridge-link-cap.service --no-pager 2>&1 | head -30
} > "$RUN_DIR/00-config.txt" 2>&1
sync "$RUN_DIR/00-config.txt" || sync

# ----------------------------------------------------------------------
# Step 1 — bridge cap state (the load-bearing measurement)
# ----------------------------------------------------------------------
mark "step 1: capture cap state (bridge + GPU LnkSta)"
{
    echo "=== bridge $BRIDGE_BDF ==="
    /usr/local/sbin/nvidia-driver-injector-bridge-link-cap status 2>&1
    echo
    echo "=== bridge raw setpci ==="
    setpci -s "$BRIDGE_BDF" CAP_EXP+0x10.W CAP_EXP+0x12.W CAP_EXP+0x30.W 2>&1
    echo "  ^ LnkCtl(0x10), LnkSta(0x12), LnkCtl2(0x30)"
    echo
    echo "=== GPU $GPU_BDF LnkSta ==="
    setpci -s "$GPU_BDF" CAP_EXP+0x12.W 2>&1
    echo
    echo "=== lspci LnkCap/LnkSta on bridge (vvv) ==="
    lspci -s "$BRIDGE_BDF" -vvv 2>/dev/null | grep -E "Lnk(Cap|Sta|Ctl)" || true
} > "$RUN_DIR/01-cap-state.txt" 2>&1
sync "$RUN_DIR/01-cap-state.txt" || sync
mark "  cap state captured ($(grep -c LnkCtl2 "$RUN_DIR/01-cap-state.txt") LnkCtl2 lines)"

# ----------------------------------------------------------------------
# Step 2 — AER baseline
# ----------------------------------------------------------------------
mark "step 2: AER baseline counters"
{
    for path in \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_correctable" \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_fatal" \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_nonfatal" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_correctable" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_fatal" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_nonfatal"; do
        if [[ -r "$path" ]]; then
            echo "=== $path ==="
            cat "$path"
            echo
        fi
    done
} > "$RUN_DIR/02-aer-baseline.txt" 2>&1
sync "$RUN_DIR/02-aer-baseline.txt" || sync

# ----------------------------------------------------------------------
# Step 3 — dmesg pre-trigger snapshot (so we can diff later)
# ----------------------------------------------------------------------
mark "step 3: dmesg pre-trigger snapshot"
fsync_capture "$RUN_DIR/03-dmesg-pre.log" dmesg
mark "  $(wc -l < "$RUN_DIR/03-dmesg-pre.log") lines"

# tally any boot-time AER UE-Non-Fatal events (the metric that mattered last time)
boot_aer=$(grep -cE "AER:.*Uncorrected.*non[_-]fatal" "$RUN_DIR/03-dmesg-pre.log" 2>/dev/null || echo 0)
mark "  boot-time AER UE-Non-Fatal events in dmesg: $boot_aer"

# ----------------------------------------------------------------------
# Step 4 — sysfs-only probe (no /dev/nvidia0 open, cheap experiment first)
# ----------------------------------------------------------------------
mark "step 4: sysfs-only probe (driver bound? GPU readable without open?)"
{
    echo "=== /proc/modules nvidia ==="
    grep -E '^(nvidia|nvidia_uvm|nvidia_modeset|nvidia_drm) ' /proc/modules || echo "(no nvidia modules loaded)"
    echo
    echo "=== /sys/module/nvidia/parameters (NVreg_TbEgpu*) ==="
    for p in /sys/module/nvidia/parameters/NVreg_TbEgpu*; do
        [[ -r "$p" ]] || continue
        printf '%s = %s\n' "$(basename "$p")" "$(cat "$p")"
    done 2>&1 || echo "(unavailable)"
    echo
    echo "=== /sys/bus/pci/devices/$GPU_BDF/ ==="
    for f in vendor device class driver power_state current_link_speed current_link_width; do
        if [[ -r "/sys/bus/pci/devices/$GPU_BDF/$f" ]]; then
            printf '  %s = %s\n' "$f" "$(cat "/sys/bus/pci/devices/$GPU_BDF/$f")"
        elif [[ -L "/sys/bus/pci/devices/$GPU_BDF/$f" ]]; then
            printf '  %s -> %s\n' "$f" "$(readlink "/sys/bus/pci/devices/$GPU_BDF/$f")"
        fi
    done
    echo
    echo "=== /dev/nvidia* nodes (no open, just stat) ==="
    ls -la /dev/nvidia* 2>&1 || echo "(none)"
    echo
    echo "=== existing /dev/nvidia* holders (lsof) ==="
    lsof /dev/nvidia* 2>/dev/null || echo "(none)"
} > "$RUN_DIR/04-sysfs-probe.txt" 2>&1
sync "$RUN_DIR/04-sysfs-probe.txt" || sync

# ----------------------------------------------------------------------
# Step 5 — THE TRIGGER. The op that froze us last time.
# ----------------------------------------------------------------------
mark "step 5: TRIGGER — nvidia-smi -L"
mark "  if the host is going to freeze, it freezes here"
mark "  (last-written file before this means: probe got past step 4 cleanly)"
sync
{
    echo "=== nvidia-smi -L ==="
    timeout 30 nvidia-smi -L
    echo "exit_code=$?"
    echo
    echo "=== nvidia-smi --query-gpu=name,pci.bus_id,pstate --format=csv ==="
    timeout 30 nvidia-smi --query-gpu=name,pci.bus_id,pstate --format=csv
    echo "exit_code=$?"
} > "$RUN_DIR/05-trigger-output.txt" 2>&1
sync "$RUN_DIR/05-trigger-output.txt" || sync
mark "  trigger returned (we did NOT freeze!)"

# ----------------------------------------------------------------------
# Step 6 — settle + post-trigger dmesg
# ----------------------------------------------------------------------
mark "step 6: settle (${WAIT_SETTLE}s) + dmesg post"
sleep "$WAIT_SETTLE"
fsync_capture "$RUN_DIR/06-dmesg-post.log" dmesg
delta=$(($(wc -l < "$RUN_DIR/06-dmesg-post.log") - $(wc -l < "$RUN_DIR/03-dmesg-pre.log")))
mark "  $(wc -l < "$RUN_DIR/06-dmesg-post.log") lines ($delta new)"

# ----------------------------------------------------------------------
# Step 7 — AER counters post + diff
# ----------------------------------------------------------------------
mark "step 7: AER counters post"
{
    for path in \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_correctable" \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_fatal" \
        "/sys/bus/pci/devices/$GPU_BDF/aer_dev_nonfatal" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_correctable" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_fatal" \
        "/sys/bus/pci/devices/$BRIDGE_BDF/aer_dev_nonfatal"; do
        if [[ -r "$path" ]]; then
            echo "=== $path ==="
            cat "$path"
            echo
        fi
    done
} > "$RUN_DIR/07-aer-post.txt" 2>&1
sync "$RUN_DIR/07-aer-post.txt" || sync

# ----------------------------------------------------------------------
# Step 8 — cap state post (did the link drop?)
# ----------------------------------------------------------------------
mark "step 8: cap state post"
fsync_capture "$RUN_DIR/08-cap-state-post.txt" /usr/local/sbin/nvidia-driver-injector-bridge-link-cap status

# ----------------------------------------------------------------------
# Summary (terminal-friendly)
# ----------------------------------------------------------------------
mark ""
mark "=== SUMMARY ==="
mark "  bridge LnkCtl2 BEFORE trigger:"
grep -E 'LnkCtl2=' "$RUN_DIR/01-cap-state.txt" | head -1 | sed 's/^/    /' | tee -a "$LOG"
mark "  bridge LnkCtl2 AFTER  trigger:"
grep -E 'LnkCtl2=' "$RUN_DIR/08-cap-state-post.txt" | head -1 | sed 's/^/    /' | tee -a "$LOG"
mark ""
mark "  AER UE-Non-Fatal in dmesg pre  : $(grep -cE 'AER:.*Uncorrected.*non[_-]fatal' "$RUN_DIR/03-dmesg-pre.log" 2>/dev/null || echo ?)"
mark "  AER UE-Non-Fatal in dmesg post : $(grep -cE 'AER:.*Uncorrected.*non[_-]fatal' "$RUN_DIR/06-dmesg-post.log" 2>/dev/null || echo ?)"
mark "  GSP_LOCKDOWN_NOTICE pre        : $(grep -c 'GSP_LOCKDOWN_NOTICE' "$RUN_DIR/03-dmesg-pre.log" 2>/dev/null || echo ?)"
mark "  GSP_LOCKDOWN_NOTICE post       : $(grep -c 'GSP_LOCKDOWN_NOTICE' "$RUN_DIR/06-dmesg-post.log" 2>/dev/null || echo ?)"
mark ""
mark "  trigger output exit codes:"
grep -E '^exit_code=' "$RUN_DIR/05-trigger-output.txt" | sed 's/^/    /' | tee -a "$LOG"
mark ""
mark "Probe complete. Dossier: $RUN_DIR"
