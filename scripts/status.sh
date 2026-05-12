#!/usr/bin/env bash
# status.sh — Read-only health check for the nvidia-driver-injector
# deployment geometry.
#
# Modeled on the structure + formatting conventions of
# apnex/aorus-5090-egpu's status.sh (helpers, sections, OK/WARN/FAIL
# scoring, exit codes), but with checks specific to this repo's
# Layer 1 + Layer 2 architecture. The two repos are alternative
# geometries — running this script on a host that has aorus-5090-egpu
# installed will report DEGRADED in section 0 (geometry conflict).
#
# Exit codes:
#   0  all checks pass
#   1  warnings present (system functional but suboptimal)
#   2  failures present (system broken or wedge-prone)
#
# Usage:  ./scripts/status.sh
# No flags. No mutations. Safe to run any time.

set -uo pipefail

# ANSI colours; only emit if stdout is a TTY.
if [[ -t 1 ]]; then
    C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
else
    C_OK=''; C_WARN=''; C_FAIL=''; C_INFO=''; C_RESET=''; C_BOLD=''
fi

ok_count=0
warn_count=0
fail_count=0

ok()    { printf '  %s[OK]%s   %s\n'   "$C_OK"   "$C_RESET" "$*"; ok_count=$((ok_count+1)); }
warn()  { printf '  %s[WARN]%s %s\n'   "$C_WARN" "$C_RESET" "$*"; warn_count=$((warn_count+1)); }
fail_() { printf '  %s[FAIL]%s %s\n'   "$C_FAIL" "$C_RESET" "$*"; fail_count=$((fail_count+1)); }
info()  { printf '  %s[INFO]%s %s\n'   "$C_INFO" "$C_RESET" "$*"; }
section() { printf '\n%s== %s ==%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Auto-detect the GPU + parent bridge (matches install-host.sh logic)
EGPU_VENDOR_ID="0x10de"; EGPU_DEVICE_ID="0x2b85"
GPU_BDF=""; BRIDGE_BDF=""
for d in /sys/bus/pci/devices/*; do
    [[ -r "$d/vendor" && -r "$d/device" ]] || continue
    [[ "$(<"$d/vendor")" == "$EGPU_VENDOR_ID" && "$(<"$d/device")" == "$EGPU_DEVICE_ID" ]] || continue
    GPU_BDF="$(basename "$d")"
    BRIDGE_BDF="$(basename "$(dirname "$(readlink -f "$d")")")"
    break
done

check_arg_in_cmdline() {
    local arg="$1"
    if grep -qE "(^| )${arg}( |$)" /proc/cmdline; then
        ok "cmdline: $arg"
    else
        fail_ "cmdline missing: $arg"
    fi
}

mod_loaded() { awk '$1 == "'"$1"'" {found=1; exit} END {exit !found}' /proc/modules; }

# ============================================================================
section "0. Geometry boundary — apnex/aorus-5090-egpu artifacts"
# ============================================================================
# This script's checks assume the injector geometry. If aorus-egpu is
# installed too, the host has overlapping configurations and is in an
# unsupported state.
aorus_artifacts=()
for f in /usr/local/sbin/aorus-egpu-* /etc/aorus-egpu /var/lib/aorus-egpu \
         /etc/modprobe.d/aorus-egpu-*.conf \
         /etc/systemd/system/aorus-egpu-*.service; do
    [[ -e "$f" ]] && aorus_artifacts+=("$f")
done
if [[ ${#aorus_artifacts[@]} -eq 0 ]]; then
    ok "no aorus-5090-egpu artifacts (clean geometry boundary)"
else
    fail_ "aorus-5090-egpu artifacts present (${#aorus_artifacts[@]} files); pick one geometry — see docs/architecture.md"
fi

# ============================================================================
section "1. Boot arguments (/proc/cmdline)"
# ============================================================================
check_arg_in_cmdline 'iommu=off'
check_arg_in_cmdline 'intel_iommu=off'
check_arg_in_cmdline 'thunderbolt.host_reset=false'
check_arg_in_cmdline 'pcie_aspm.policy=performance'
check_arg_in_cmdline 'thunderbolt.clx=0'
check_arg_in_cmdline 'pcie_port_pm=off'
# resource_alignment can be standalone OR embedded in a compound pci= arg
if grep -qE 'resource_alignment=35@[0-9a-f]+:[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+' /proc/cmdline; then
    ok "cmdline: pci=resource_alignment (BAR1 sizing)"
else
    fail_ "cmdline missing: pci=resource_alignment — BAR1 will not size to 32 GiB"
fi

# IOMMU runtime check (Lever T)
if [[ -d /sys/class/iommu/dmar0 ]]; then
    fail_ "/sys/class/iommu/dmar0 present (cmdline iommu=off didn't take effect; reboot needed)"
else
    ok "IOMMU disabled (no /sys/class/iommu/dmar0)"
fi

# Thunderbolt host_reset runtime
if [[ -r /sys/module/thunderbolt/parameters/host_reset ]]; then
    hr="$(</sys/module/thunderbolt/parameters/host_reset)"
    [[ "$hr" == "N" ]] && ok "thunderbolt host_reset runtime: N" || fail_ "thunderbolt host_reset runtime: $hr (boot arg not in effect)"
fi

# ============================================================================
section "2. Layer 1 — host artifacts (this repo's apply.sh)"
# ============================================================================
for f in /etc/modprobe.d/nvidia-driver-injector.conf \
         /etc/udev/rules.d/79-nvidia-driver-injector.rules \
         /etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service \
         /usr/local/sbin/nvidia-driver-injector-bridge-link-cap; do
    [[ -e "$f" ]] && ok "present: $f" || fail_ "missing: $f (run: sudo ./scripts/apply.sh)"
done

# ============================================================================
section "3. Layer 1 — bridge-link-cap systemd unit (Lever H17)"
# ============================================================================
if systemctl cat nvidia-driver-injector-bridge-link-cap.service >/dev/null 2>&1; then
    if systemctl is-enabled nvidia-driver-injector-bridge-link-cap.service >/dev/null 2>&1; then
        ok "bridge-link-cap.service: enabled (will run at next boot)"
    else
        fail_ "bridge-link-cap.service: NOT enabled"
    fi
    if systemctl is-active nvidia-driver-injector-bridge-link-cap.service >/dev/null 2>&1; then
        ok "bridge-link-cap.service: active (cap applied)"
    else
        fail_ "bridge-link-cap.service: NOT active"
    fi
    # Verify ordering — must be Before=docker.service for the cap to run
    # before any container can race the nvidia bind.
    before=$(systemctl show -p Before nvidia-driver-injector-bridge-link-cap.service --value 2>/dev/null)
    if grep -q 'docker.service' <<<"$before"; then
        ok "bridge-link-cap.service: ordered Before=docker.service"
    else
        warn "bridge-link-cap.service: missing Before=docker.service (race risk on next boot)"
    fi
else
    fail_ "bridge-link-cap.service: not installed"
fi

# Persistence mode is now engaged from inside the injector container's
# entrypoint (nvidia-smi -pm 1 after bind), not via a Layer-1 service.
# We verify the runtime effect here; the container-side check is in
# section 12.
if command -v nvidia-smi >/dev/null 2>&1; then
    pm=$(nvidia-smi --query-gpu=persistence_mode --format=csv,noheader 2>/dev/null | head -1)
    if [[ "$pm" == "Enabled" ]]; then
        ok "GPU persistence_mode: Enabled (GSP + thermal subsystem engaged — set by injector container)"
    else
        warn "GPU persistence_mode: ${pm:-unknown} — expected Enabled; injector container's nvidia-smi -pm 1 may have failed (idle power will be ~63 W instead of ~22 W)"
    fi
fi

# ============================================================================
section "4. PCI device + bridge link"
# ============================================================================
if [[ -z "$GPU_BDF" ]]; then
    fail_ "no AORUS RTX 5090 (10de:2b85) on PCI bus — eGPU disconnected, TB unauthorized, or boltctl broken"
else
    ok "GPU enumerated at $GPU_BDF"
    info "parent bridge: $BRIDGE_BDF"

    bar1=$(stat -c%s /sys/bus/pci/devices/$GPU_BDF/resource1 2>/dev/null || echo 0)
    if [[ "$bar1" == "34359738368" ]]; then
        ok "BAR1 = 32 GiB"
    else
        fail_ "BAR1 = $((bar1 / 1024 / 1024)) MiB (expected 32 GiB)"
    fi

    if [[ -n "$BRIDGE_BDF" ]]; then
        lnksta=$(setpci -s "$BRIDGE_BDF" CAP_EXP+0x12.W 2>/dev/null)
        lnkctl2=$(setpci -s "$BRIDGE_BDF" CAP_EXP+0x30.W 2>/dev/null)
        speed=$(( 0x$lnksta & 0xF ))
        target=$(( 0x$lnkctl2 & 0xF ))
        bit5=$(( (0x$lnkctl2 >> 5) & 1 ))
        active=$(( (0x$lnksta >> 12) & 1 ))
        # The load-bearing check is LnkCtl2 bit 5 (Hardware Autonomous
        # Speed Disable) — NOT the Target Link Speed. Target is cosmetic
        # on this Intel TB controller (kernel/driver rewrites it to
        # match live link speed). Bit 5 actually prevents the
        # autonomous Gen3↔Gen4 oscillation that triggers GSP_LOCKDOWN.
        if [[ "$bit5" -eq 1 && "$active" -eq 1 ]]; then
            ok "bridge link: live=Gen$speed active, bit5=1 (Lever H17 in force)"
            info "  LnkCtl2=0x$lnkctl2 — Target=Gen$target (cosmetic; bit 5 is what protects)"
        elif [[ "$bit5" -eq 0 ]]; then
            fail_ "bridge link: LnkCtl2 bit 5 NOT set — autonomous speed changes still possible (wedge risk)"
        else
            warn "bridge link: bit5=$bit5 active=$active (unusual)"
        fi
    fi

    # HDMI audio function (function .1) — compute-only host; should NOT
    # be bound to snd_hda_intel. Driver-override sentinel from the
    # 80-nvidia-driver-injector-disable-audio.rules should be in place.
    audio_bdf="${GPU_BDF%.*}.1"
    if [[ -d "/sys/bus/pci/devices/${audio_bdf}" ]]; then
        if [[ -L "/sys/bus/pci/devices/${audio_bdf}/driver" ]]; then
            adrv=$(basename "$(readlink "/sys/bus/pci/devices/${audio_bdf}/driver")")
            fail_ "HDMI audio function ${audio_bdf} bound to ${adrv} (compute-only host — expected no binding; udev rule 80- should unbind)"
        else
            ok "HDMI audio function ${audio_bdf}: unbound (compute-only posture)"
        fi
        override=$(cat "/sys/bus/pci/devices/${audio_bdf}/driver_override" 2>/dev/null)
        if [[ "$override" == "nvidia-driver-injector-disabled" ]]; then
            ok "HDMI audio function ${audio_bdf}: driver_override sentinel set"
        else
            warn "HDMI audio function ${audio_bdf}: driver_override='${override}' (expected 'nvidia-driver-injector-disabled')"
        fi
    fi
fi

# ============================================================================
section "5. nvidia kernel module"
# ============================================================================
if mod_loaded nvidia; then
    ver=$(cat /sys/module/nvidia/version 2>/dev/null || echo unknown)
    if [[ "$ver" == *aorus* ]]; then
        ok "nvidia loaded: $ver (patched build)"
    else
        warn "nvidia loaded: $ver (NOT patched — stock auto-load occurred)"
    fi
    mod_loaded nvidia_uvm && ok "nvidia_uvm loaded" || warn "nvidia_uvm: not loaded (cuInit will try to load it)"
    if mod_loaded nvidia_drm; then
        fail_ "nvidia_drm LOADED (compute-only mode requires unloaded — possible GNOME-freeze risk)"
    else
        ok "nvidia_drm unloaded (compute-only)"
    fi
    if [[ -n "$GPU_BDF" && -e "/sys/bus/pci/devices/$GPU_BDF/driver" ]]; then
        bound=$(basename "$(readlink "/sys/bus/pci/devices/$GPU_BDF/driver")")
        [[ "$bound" == "nvidia" ]] && ok "GPU bound to nvidia" || fail_ "GPU bound to '$bound' (expected nvidia)"
    fi
else
    info "nvidia not loaded (host blank-equivalent OR injector container down)"
fi

# ============================================================================
section "6. NVreg parameters (production posture from modprobe.d)"
# ============================================================================
# Only meaningful when nvidia is loaded. Most NVreg_* options are
# write-only at module-load time — they aren't exposed at runtime
# under /sys/module/nvidia/parameters/. We verify the ones we can
# (LeverMRecoverEnable IS exposed) and trust section 7's /dev/nvidia*
# perm check to indirectly confirm NVreg_DeviceFile* applied.
if mod_loaded nvidia; then
    re=$(cat /sys/module/nvidia/parameters/NVreg_TbEgpuLeverMRecoverEnable 2>/dev/null || echo "?")
    if [[ "$re" == "1" ]]; then
        ok "Lever M-recover: armed (RecoverEnable=1)"
    elif [[ "$re" == "0" ]]; then
        fail_ "Lever M-recover: NOT armed (RecoverEnable=0; modprobe.d not in load path)"
    else
        warn "Lever M-recover: unknown (RecoverEnable=$re)"
    fi
    info "NVreg_DeviceFile* + RmForceExternalGpu are write-only at load;"
    info "  see section 7 (perm check) for indirect verification of DeviceFileMode/UID/GID."
fi

# ============================================================================
section "7. /dev/nvidia* device-file permissions"
# ============================================================================
if mod_loaded nvidia; then
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        if [[ -e "$dev" ]]; then
            stat=$(stat -c "%a %U:%G" "$dev")
            if [[ "$stat" == "660 root:gpu" ]]; then
                ok "$dev: $stat"
            else
                warn "$dev: $stat (expected 660 root:gpu)"
            fi
        else
            warn "$dev: missing"
        fi
    done
fi

# ============================================================================
section "8. Q-watchdog kthread (Mode B detector)"
# ============================================================================
if mod_loaded nvidia; then
    if pgrep -af '\[aorus-qwd-' >/dev/null 2>&1; then
        kt=$(pgrep -af '\[aorus-qwd-' | awk '{print $NF}')
        ok "Q-watchdog kthread running: $kt"
    else
        warn "Q-watchdog kthread NOT running"
    fi
fi

# ============================================================================
section "9. ICD disable (compute-only posture)"
# ============================================================================
for f in /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json \
         /usr/share/vulkan/implicit_layer.d/nvidia_layers.json \
         /usr/share/glvnd/egl_vendor.d/10_nvidia.json \
         /etc/OpenCL/vendors/nvidia.icd; do
    if [[ -f "${f}.nvidia-driver-injector-disabled" ]]; then
        ok "disabled: $f"
    elif [[ -f "${f}.aorus-disabled" ]]; then
        warn "$f disabled by aorus-egpu (legacy naming; effectively disabled)"
    elif [[ -f "$f" ]]; then
        warn "$f present + active (not disabled)"
    else
        info "$f not present (vendor may not have shipped this ICD)"
    fi
done

# ============================================================================
section "10. Recent kernel error signals (last 24h)"
# ============================================================================
errors=$(journalctl -k --since='24 hours ago' --no-pager 2>/dev/null | \
         grep -iE 'Xid|fallen off the bus|GPU IS LOST|NVRM.*Failed|aer.*uncorrectable' | head -10)
if [[ -z "$errors" ]]; then
    ok "no Xid / fallen-off-bus / uncorrectable AER / NVRM Failed in last 24h"
else
    fail_ "kernel error signals found:"
    printf '%s\n' "$errors" | sed 's/^/        /'
fi

# ============================================================================
section "11. nvidia-smi smoke test"
# ============================================================================
if mod_loaded nvidia && command -v nvidia-smi >/dev/null 2>&1; then
    out=$(timeout 15 nvidia-smi --query-gpu=name,temperature.gpu,utilization.gpu,power.draw,pstate --format=csv,noheader 2>&1)
    if [[ "$out" == *"NVIDIA"* ]]; then
        ok "nvidia-smi: $out"
    else
        fail_ "nvidia-smi: $out"
    fi
elif mod_loaded nvidia; then
    info "nvidia-smi not in PATH (expected if compute-only host has no userspace tools)"
fi

# ============================================================================
section "12. Layer 2 — injector container"
# ============================================================================
if command -v docker >/dev/null 2>&1 && systemctl is-active docker >/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^nvidia-driver-injector$'; then
        st=$(docker ps --filter name=nvidia-driver-injector --format '{{.Status}}')
        ok "injector container running: $st"
    else
        info "injector container not running (Layer 2 down)"
    fi
else
    warn "docker daemon not running"
fi

# ============================================================================
section "Summary"
# ============================================================================
total=$((ok_count + warn_count + fail_count))
printf '\n  %d OK, %d WARN, %d FAIL (of %d checks)\n' "$ok_count" "$warn_count" "$fail_count" "$total"
if [[ "$fail_count" -eq 0 && "$warn_count" -eq 0 ]]; then
    printf '\n  %sStatus: HEALTHY%s\n\n' "$C_OK" "$C_RESET"
    exit 0
elif [[ "$fail_count" -eq 0 ]]; then
    printf '\n  %sStatus: HEALTHY WITH WARNINGS%s — see WARN items above.\n\n' "$C_WARN" "$C_RESET"
    exit 1
else
    printf '\n  %sStatus: DEGRADED%s — see FAIL items above.\n\n' "$C_FAIL" "$C_RESET"
    exit 2
fi
