#!/usr/bin/env bash
# remove.sh — reverse apply.sh.
#
# Idempotent. Safe to run on a host where apply.sh was never run
# (it'll just print "already absent" for everything).
#
# What this does:
#   1. Stop + disable + remove the bridge-link-cap systemd unit.
#   2. Remove /usr/local/sbin/nvidia-driver-injector-bridge-link-cap.
#   3. Remove /etc/modprobe.d/nvidia-driver-injector.conf.
#   4. Remove /etc/udev/rules.d/79-nvidia-driver-injector.rules.
#   5. Re-enable Vulkan/EGL/OpenCL ICDs (rename .disabled → original).
#   6. Reload systemd + udev.
#
# What this does NOT do (operator opt-in):
#   - Revert kernel cmdline changes (use --revert-cmdline).
#     This is OFF by default because the kernel cmdline tuning is
#     useful for any deployment of this hardware, not just the
#     injector. Reverting may impact other tools/workloads on the
#     same host.
#   - Deep-purge files this repo did NOT install (use --purge).
#     Patched nvidia.ko on disk + .aorus-disabled ICDs from a prior
#     apnex/aorus-5090-egpu install can confuse the boot path
#     (vendor softdep auto-loads the on-disk .ko even after our
#     modprobe.d guard is removed). --purge cleans those up so
#     the host reaches a true blank-equivalent state. See below.
#   - Remove kernel-devel.
#   - Remove the ollama UNIX group (it may be in use by other things).
#   - Remove nvidia-persistenced or related RPM packages.
#   - Stop / remove the injector container itself
#     (run `docker compose run --rm driver-injector uninstall &&
#     docker compose down` separately first).
#
# Flags:
#   --no-act           Print every action without making changes.
#   --revert-cmdline   Strip the kernel cmdline args this repo added
#                      (iommu=off etc.). Reboot required after.
#   --purge            Deep clean for "fresh-host" testing. In addition
#                      to the standard reverse-apply, also:
#                        - remove /usr/lib/modules/<kver>/extra/nvidia*.ko*
#                          (patched on-disk module from a prior install)
#                        - restore *.aorus-disabled ICDs to active
#                          (legacy from prior apnex/aorus-5090-egpu install)
#                      Implies --revert-cmdline. Reboot required after.
#                      Use this when you want to validate the canonical
#                      "fresh Fedora install + apply.sh" workflow.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

NO_ACT=0
REVERT_CMDLINE=0
PURGE=0

for arg in "$@"; do
    case "$arg" in
        --no-act)         NO_ACT=1 ;;
        --revert-cmdline) REVERT_CMDLINE=1 ;;
        --purge)          PURGE=1; REVERT_CMDLINE=1 ;;
        -h|--help)
            sed -n '/^# remove\.sh/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

if [[ "$EUID" -ne 0 && "$NO_ACT" -eq 0 ]]; then
    echo "remove.sh must be run as root (or with --no-act)" >&2
    exit 1
fi

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()   { printf '\n=== %s ===\n' "$*"; }
act()    {
    if [[ "$NO_ACT" -eq 1 ]]; then printf '  [DRY-RUN] %s\n' "$*"
    else eval "$*"
    fi
}

# Pre-flight: warn if injector container is currently running with the
# patched module loaded — operator likely wants to take it down first.
if grep -q '^nvidia ' /proc/modules 2>/dev/null; then
    yellow "warning: nvidia module is currently loaded."
    yellow "Recommended order:"
    yellow "  1. cd /path/to/this/repo"
    yellow "  2. docker compose run --rm driver-injector uninstall"
    yellow "  3. docker compose down"
    yellow "  4. sudo ./scripts/remove.sh   ← you are here"
    yellow ""
    yellow "Continuing anyway; remove.sh only touches host config files."
fi

# ===========================================================================
# Step 1: bridge-link-cap systemd unit
# ===========================================================================
step "1/6 bridge-link-cap systemd unit"

unit="nvidia-driver-injector-bridge-link-cap.service"
unit_path="/etc/systemd/system/${unit}"

if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
    act "systemctl stop ${unit} 2>/dev/null || true"
    act "systemctl disable ${unit} 2>/dev/null || true"
    act "rm -f ${unit_path}"
    green "  removed ${unit_path}"
else
    yellow "  ${unit} not installed — already absent"
fi

# ===========================================================================
# Step 2: bridge-link-cap binary
# ===========================================================================
step "2/6 bridge-link-cap binary"

bin="/usr/local/sbin/nvidia-driver-injector-bridge-link-cap"
if [[ -f "$bin" ]]; then
    act "rm -f ${bin}"
    green "  removed ${bin}"
else
    yellow "  ${bin} already absent"
fi

# ===========================================================================
# Legacy step (no-op for current installs): remove host-side gpu-engage
# ===========================================================================
# Older installs of this repo had a gpu-engage Layer-1 service. The
# functionality has been folded into the injector container's entrypoint
# (`nvidia-smi -pm 1` after bind). This block cleans up the old artifacts
# so apply→remove cycles work cleanly on upgraded hosts.
unit="nvidia-driver-injector-gpu-engage.service"
unit_path="/etc/systemd/system/${unit}"
if systemctl list-unit-files "$unit" 2>/dev/null | grep -q "$unit"; then
    yellow "  legacy: removing pre-folded gpu-engage service"
    act "systemctl stop ${unit} 2>/dev/null || true"
    act "systemctl disable ${unit} 2>/dev/null || true"
    act "rm -f ${unit_path}"
fi
[[ -f /usr/local/sbin/nvidia-driver-injector-gpu-engage ]] && \
    act "rm -f /usr/local/sbin/nvidia-driver-injector-gpu-engage"

# ===========================================================================
# Step 3: modprobe.d
# ===========================================================================
step "3/6 /etc/modprobe.d/nvidia-driver-injector.conf"

f="/etc/modprobe.d/nvidia-driver-injector.conf"
if [[ -f "$f" ]]; then
    act "rm -f ${f}"
    green "  removed ${f}"
else
    yellow "  ${f} already absent"
fi

# ===========================================================================
# Step 6: udev rules
# ===========================================================================
step "4/6 /etc/udev/rules.d/{79,80}-nvidia-driver-injector*.rules"

for f in /etc/udev/rules.d/79-nvidia-driver-injector.rules \
         /etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules; do
    if [[ -f "$f" ]]; then
        act "rm -f ${f}"
        green "  removed ${f}"
    else
        yellow "  ${f} already absent"
    fi
done

# Audio function will re-bind to snd_hda_intel on next reboot / TB
# re-enumeration once the disable rule is gone; no explicit unbind reverse
# needed (driver_override is cleared by udev when the device disappears).

# ===========================================================================
# Step 5: re-enable ICDs
# ===========================================================================
step "5/6 re-enable Vulkan/EGL/OpenCL ICDs"

icd_paths=(
    /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
    /usr/share/vulkan/implicit_layer.d/nvidia_layers.json
    /usr/share/glvnd/egl_vendor.d/10_nvidia.json
    /etc/OpenCL/vendors/nvidia.icd
)
for f in "${icd_paths[@]}"; do
    disabled="${f}.nvidia-driver-injector-disabled"
    if [[ -f "$disabled" ]]; then
        act "mv '${disabled}' '${f}'"
        green "  re-enabled ${f}"
    elif [[ -f "$f" ]]; then
        green "  ${f} already enabled"
    else
        yellow "  ${f} not present (driver may not have shipped this ICD)"
    fi
done

# ===========================================================================
# Step 6: optional cmdline revert
# ===========================================================================
step "6/6 reload + optional cmdline revert"

act "systemctl daemon-reload"
act "udevadm control --reload-rules"

if [[ "$REVERT_CMDLINE" -eq 1 ]]; then
    if command -v grubby >/dev/null 2>&1; then
        REVERT_ARGS=(
            "iommu=off"
            "intel_iommu=off"
            "thunderbolt.host_reset=false"
            "pcie_aspm.policy=performance"
            "thunderbolt.clx=0"
            "pcie_port_pm=off"
        )
        # Remove pci=resource_alignment too (best-effort — its value
        # depends on bridge BDF we may no longer be able to detect).
        # Buffer grubby first to avoid SIGPIPE from awk-exit.
        grubby_out=$(grubby --info=ALL 2>/dev/null || true)
        current=$(printf '%s\n' "$grubby_out" | awk -F\" '/^args=/ {print $2; exit}')
        ra_match=$(grep -oE 'pci=resource_alignment=35@[0-9a-f]+:[0-9a-f]+:[0-9a-f]+\.[0-9a-f]+' \
                   <<<"$current" | head -1 || true)
        [[ -n "$ra_match" ]] && REVERT_ARGS+=("$ra_match")

        act "grubby --update-kernel=ALL --remove-args='${REVERT_ARGS[*]}'"
        yellow "  cmdline reverted; reboot to apply"
    else
        yellow "  grubby not present; revert kernel cmdline manually"
    fi
else
    yellow "  --revert-cmdline not given; kernel cmdline left as-is"
    yellow "  (the iommu=off etc. tuning is generally useful, not injector-specific)"
fi

# ===========================================================================
# Step 7: --purge mode — deep clean for "fresh-host" testing
# ===========================================================================
if [[ "$PURGE" -eq 1 ]]; then
    step "7/7 --purge: deep clean (patched .ko + legacy .aorus-disabled ICDs)"

    # Patched on-disk module from a prior install. /usr/lib/modules/<kver>/
    # extra/ is the canonical location for vendor-rebuilt or akmod modules.
    # If we leave the .ko here, vendor `softdep nvidia post: ...` in
    # /usr/lib/modprobe.d/nvidia.conf will auto-load it on next boot —
    # without our modprobe.d guards, that means RecoverEnable=0 and no
    # bridge-link-cap (yesterday's wedge scenario).
    extra_dir="/lib/modules/$(uname -r)/extra"
    if [[ -d "$extra_dir" ]]; then
        for ko in "$extra_dir"/nvidia*.ko* "$extra_dir"/nvidia*.ko.xz.dnf-stock-*; do
            if [[ -f "$ko" ]]; then
                act "rm -f '${ko}'"
                green "  removed ${ko}"
            fi
        done
    fi

    # Restore .aorus-disabled ICDs (legacy from a prior aorus-5090-egpu
    # install). Standard remove.sh only knows about our own
    # .nvidia-driver-injector-disabled extension. A prior aorus-egpu install
    # would have left these renamed but never restored.
    icd_paths=(
        /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
        /usr/share/vulkan/implicit_layer.d/nvidia_layers.json
        /usr/share/glvnd/egl_vendor.d/10_nvidia.json
        /etc/OpenCL/vendors/nvidia.icd
    )
    for f in "${icd_paths[@]}"; do
        legacy="${f}.aorus-disabled"
        if [[ -f "$legacy" ]]; then
            act "mv '${legacy}' '${f}'"
            green "  restored legacy-disabled ${f}"
        fi
    done

    yellow ""
    yellow "  --purge complete. The host is now blank-equivalent."
    yellow "  Reboot before running apply.sh to validate the fresh-install path:"
    yellow "    sudo reboot"
fi

green ""
green "Layer 1 uninstall complete."
echo "If --revert-cmdline was set, reboot to apply the kernel cmdline change."
