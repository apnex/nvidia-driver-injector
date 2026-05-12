#!/usr/bin/env bash
# apply.sh — Layer 1 host bring-up for the nvidia-driver-injector
# deployment geometry.
#
# Idempotent. Run once at install time, again after kernel upgrades, or
# any time you want to reconcile host state with the repo's expected
# Layer 1 posture.
#
# What this does:
#   1. Refuse if apnex/aorus-5090-egpu artifacts are present
#      (override with --force-coexist; see conflict-check.sh).
#   2. Set kernel cmdline via grubby (asks before reboot).
#   3. Verify kernel-devel is installed for $(uname -r).
#   4. Install /etc/modprobe.d/nvidia-driver-injector.conf
#      (production NVreg options including LeverMRecoverEnable=1).
#   5. Install + enable
#      /etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service
#      (runs Before=docker.service to apply Lever H17 cap).
#   6. Install /etc/udev/rules.d/79-nvidia-driver-injector.rules
#      (group permissions on /dev/nvidia*).
#   7. Disable Vulkan/EGL/OpenCL ICD entries (compute-only posture).
#   8. Ensure 'gpu' UNIX group exists (used as the device-file
#      access group) and rewrite NVreg_DeviceFileGID in modprobe.d to
#      match the host's actual GID.
#   9. systemctl daemon-reload + udev reload.
#
# What this does NOT do:
#   - Build or load nvidia.ko. That's the injector container's job
#     (Layer 2). Once this script exits, `docker compose up -d` in the
#     repo root will load the patched module via modprobe, picking up
#     the modprobe.d options this script just installed.
#
# Flags:
#   --no-act         Print every action without making changes.
#   --force-coexist  Skip the aorus-egpu conflict check (use with care).
#   --skip-cmdline   Don't touch kernel cmdline (you'll manage it yourself).
#   --skip-icd       Don't touch Vulkan/EGL/OpenCL ICD files.
#
# This script lives in the nvidia-driver-injector repo; it is a
# *cleanroom* equivalent of the Layer 1 bits of apnex/aorus-5090-egpu's
# apply.sh, written specifically for the container deployment geometry.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST_FILES="${REPO_ROOT}/scripts/host-files"

NO_ACT=0
FORCE_COEXIST=0
SKIP_CMDLINE=0
SKIP_ICD=0

for arg in "$@"; do
    case "$arg" in
        --no-act)        NO_ACT=1 ;;
        --force-coexist) FORCE_COEXIST=1 ;;
        --skip-cmdline)  SKIP_CMDLINE=1 ;;
        --skip-icd)      SKIP_ICD=1 ;;
        -h|--help)
            sed -n '/^# apply\.sh/,/^set -euo/p' "$0" | sed 's/^# \?//' | head -n -1
            exit 0
            ;;
        *)
            printf 'unknown flag: %s\n' "$arg" >&2; exit 2 ;;
    esac
done

if [[ "$EUID" -ne 0 && "$NO_ACT" -eq 0 ]]; then
    echo "apply.sh must be run as root (or with --no-act)" >&2
    exit 1
fi

green()  { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
red()    { printf '\033[31m%s\033[0m\n' "$*" >&2; }
step()   { printf '\n=== %s ===\n' "$*"; }
act() {
    if [[ "$NO_ACT" -eq 1 ]]; then
        printf '  [DRY-RUN] %s\n' "$*"
    else
        eval "$*"
    fi
}

# ===========================================================================
# Step 0: conflict check
# ===========================================================================
step "0/9 conflict check (apnex/aorus-5090-egpu artifacts?)"

if [[ "$FORCE_COEXIST" -eq 1 ]]; then
    yellow "  --force-coexist set; skipping conflict check (you own the consequences)"
else
    # shellcheck source=lib/conflict-check.sh
    if ! source "${REPO_ROOT}/scripts/lib/conflict-check.sh"; then
        exit 3
    fi
    green "  no aorus-egpu artifacts detected"
fi

# ===========================================================================
# Step 1: kernel cmdline
# ===========================================================================
step "1/9 kernel cmdline (grubby)"

REQUIRED_ARGS=(
    "iommu=off"
    "intel_iommu=off"
    "thunderbolt.host_reset=false"
    "pcie_aspm.policy=performance"
    "thunderbolt.clx=0"
    "pcie_port_pm=off"
)

if [[ "$SKIP_CMDLINE" -eq 1 ]]; then
    yellow "  --skip-cmdline set; not touching boot args"
else
    if ! command -v grubby >/dev/null 2>&1; then
        yellow "  grubby not present (non-Fedora-family host?). Set the following"
        yellow "  kernel cmdline args yourself, by whatever means your distro uses:"
        printf '    %s\n' "${REQUIRED_ARGS[@]}" >&2
    else
        # Avoid SIGPIPE from `awk ... exit` against grubby. Buffer
        # grubby's full output, then extract the first args= line.
        grubby_out=$(grubby --info=ALL 2>/dev/null || true)
        current_cmdline=$(printf '%s\n' "$grubby_out" | awk -F\" '/^args=/ {print $2; exit}')
        missing_args=()
        for a in "${REQUIRED_ARGS[@]}"; do
            if ! grep -q -- "$a" <<<"$current_cmdline"; then
                missing_args+=("$a")
            fi
        done
        if [[ ${#missing_args[@]} -eq 0 ]]; then
            green "  all required cmdline args already present"
        else
            yellow "  missing cmdline args: ${missing_args[*]}"
            act "grubby --update-kernel=ALL --args='${missing_args[*]}'"
            yellow "  kernel cmdline changed; reboot required for changes to take effect"
            CMDLINE_CHANGED=1
        fi
    fi

    # pci=resource_alignment needs the bridge BDF, which depends on the TB
    # port the eGPU is plugged into. Detect rather than hardcode.
    bridge_bdf=$(
        for d in /sys/bus/pci/devices/*; do
            [[ -r "$d/vendor" && -r "$d/device" ]] || continue
            v=$(<"$d/vendor"); dv=$(<"$d/device")
            if [[ "$v" == "0x10de" && "$dv" == "0x2b85" ]]; then
                basename "$(dirname "$(readlink -f "$d")")"
                break
            fi
        done
    )
    if [[ -n "${bridge_bdf:-}" ]] && command -v grubby >/dev/null 2>&1; then
        # Match the directive substring (without the `pci=` prefix) so
        # we recognise both forms:
        #   pci=resource_alignment=35@<bdf>             (standalone arg)
        #   pci=realloc=off,...,resource_alignment=35@<bdf>  (compound)
        # Without this, apply.sh re-adds a redundant arg every
        # run on a host where the compound form was previously set.
        ra_match="resource_alignment=35@${bridge_bdf}"
        ra_arg="pci=${ra_match}"
        if ! grep -q -- "$ra_match" <<<"$current_cmdline"; then
            yellow "  missing PCI resource_alignment for ${bridge_bdf}"
            act "grubby --update-kernel=ALL --args='${ra_arg}'"
            CMDLINE_CHANGED=1
        else
            green "  pci=resource_alignment present for ${bridge_bdf}"
        fi
    elif [[ -z "${bridge_bdf:-}" ]]; then
        yellow "  AORUS GPU not currently enumerated; can't auto-set"
        yellow "  pci=resource_alignment. Plug in the eGPU and re-run, or set"
        yellow "  the arg manually using the bridge BDF above your GPU."
    fi
fi

# ===========================================================================
# Step 2: kernel-devel
# ===========================================================================
step "2/9 kernel-devel for $(uname -r)"

KSRC="/lib/modules/$(uname -r)/build"
if [[ -e "$KSRC/Makefile" ]]; then
    green "  kernel-devel present at ${KSRC}"
else
    if command -v dnf >/dev/null 2>&1; then
        yellow "  kernel-devel missing — installing via dnf"
        act "dnf install -y kernel-devel-$(uname -r)"
    elif command -v apt-get >/dev/null 2>&1; then
        yellow "  kernel-devel missing — installing via apt"
        act "apt-get install -y linux-headers-$(uname -r)"
    else
        red "  kernel-devel missing and no recognised package manager"
        red "  install the kernel-devel package matching $(uname -r) manually"
        exit 4
    fi
fi

# ===========================================================================
# Step 3: gpu group + rewrite NVreg_DeviceFileGID in modprobe.d
# ===========================================================================
step "3/9 gpu UNIX group + GID-rewrite in modprobe.d"

if getent group gpu >/dev/null 2>&1; then
    GPU_GID=$(getent group gpu | cut -d: -f3)
    green "  gpu group exists (gid=${GPU_GID})"
else
    yellow "  gpu group absent — creating"
    act "groupadd -r gpu"
    GPU_GID=$(getent group gpu 2>/dev/null | cut -d: -f3 || echo 968)
fi

# ===========================================================================
# Step 4: modprobe.d
# ===========================================================================
step "4/9 /etc/modprobe.d/nvidia-driver-injector.conf"

# Clean up the aorus-5090-egpu transition stub if it exists. remove.sh
# from that repo installs zz-aorus-egpu-blacklist.conf as a temporary
# guard against stock nvidia auto-loading during the gap between
# remove.sh and the next install. Our nvidia-driver-injector.conf
# provides equivalent blacklist coverage, so the transition stub is
# now redundant.
transition_stub="/etc/modprobe.d/zz-aorus-egpu-blacklist.conf"
if [[ -f "$transition_stub" ]]; then
    yellow "  found aorus-5090-egpu transition blacklist stub — removing"
    yellow "  (this repo's modprobe.d provides equivalent coverage)"
    act "rm -f ${transition_stub}"
fi

src="${HOST_FILES}/etc/modprobe.d/nvidia-driver-injector.conf"
dst="/etc/modprobe.d/nvidia-driver-injector.conf"

if [[ "$NO_ACT" -eq 1 ]]; then
    printf '  [DRY-RUN] install %s -> %s (with NVreg_DeviceFileGID=%s)\n' \
        "$src" "$dst" "$GPU_GID"
else
    sed "s/NVreg_DeviceFileGID=968/NVreg_DeviceFileGID=${GPU_GID}/g" "$src" > "$dst"
    chmod 0644 "$dst"
    green "  installed ${dst} (NVreg_DeviceFileGID=${GPU_GID})"
fi

# ===========================================================================
# Step 5: systemd unit + binary for bridge-link-cap
# ===========================================================================
step "5/9 nvidia-driver-injector-bridge-link-cap (binary + systemd unit)"

act "install -m 0755 -D ${HOST_FILES}/usr/local/sbin/nvidia-driver-injector-bridge-link-cap /usr/local/sbin/nvidia-driver-injector-bridge-link-cap"
act "install -m 0644 -D ${HOST_FILES}/etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service /etc/systemd/system/nvidia-driver-injector-bridge-link-cap.service"
act "systemctl daemon-reload"
act "systemctl enable nvidia-driver-injector-bridge-link-cap.service"
green "  bridge-link-cap installed + enabled"

# ===========================================================================
# Step 6: udev rules
# ===========================================================================
# Two rules:
#   79-nvidia-driver-injector.rules           — /dev/nvidia* permissions
#   80-nvidia-driver-injector-disable-audio.rules — unbind the eGPU's HDMI
#       audio function (compute-only host; keeps it out of D0 and off the
#       snd_hda_intel autoload path)
step "6/9 udev rules"

act "install -m 0644 -D ${HOST_FILES}/etc/udev/rules.d/79-nvidia-driver-injector.rules /etc/udev/rules.d/79-nvidia-driver-injector.rules"
act "install -m 0644 -D ${HOST_FILES}/etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules /etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules"
act "udevadm control --reload-rules"
act "udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de --attr-match=device=0x22e8 --action=add 2>/dev/null || true"
green "  udev rules installed (perms + audio-disable)"

# ===========================================================================
# Step 7: Vulkan/EGL/OpenCL ICD disable (compute-only posture)
# ===========================================================================
step "7/9 Vulkan/EGL/OpenCL ICD disable"

if [[ "$SKIP_ICD" -eq 1 ]]; then
    yellow "  --skip-icd set; not touching ICD files"
else
    icd_paths=(
        /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json
        /usr/share/vulkan/implicit_layer.d/nvidia_layers.json
        /usr/share/glvnd/egl_vendor.d/10_nvidia.json
        /etc/OpenCL/vendors/nvidia.icd
    )
    for f in "${icd_paths[@]}"; do
        if [[ -f "$f" ]]; then
            act "mv '${f}' '${f}.nvidia-driver-injector-disabled'"
            green "  disabled ${f}"
        elif [[ -f "${f}.nvidia-driver-injector-disabled" ]]; then
            green "  ${f} already disabled"
        else
            yellow "  ${f} not present (driver may not have shipped this ICD)"
        fi
    done
fi

# ===========================================================================
# Step 8: summary + reboot guidance
# ===========================================================================
step "8/9 summary"

green "Layer 1 install complete."
echo
echo "Next steps:"
if [[ "${CMDLINE_CHANGED:-0}" -eq 1 ]]; then
    yellow "  1. Reboot to apply kernel cmdline changes:"
    echo "       sudo reboot"
    echo "  2. After reboot, bring up the injector container:"
else
    echo "  1. Bring up the injector container:"
fi
echo "       cd ${REPO_ROOT}"
echo "       docker compose up -d"
echo
echo "  2. Once the injector container reports healthy, bring up your"
echo "     workload (e.g., vLLM):"
echo "       cd /path/to/your/workload && docker compose up -d"
echo

# ===========================================================================
# Step 9: optional kick-the-bridge-cap-now if no reboot needed
# ===========================================================================
step "9/9 apply bridge-link-cap now (without rebooting)"

if [[ "${CMDLINE_CHANGED:-0}" -eq 0 && "$NO_ACT" -eq 0 ]]; then
    if /usr/local/sbin/nvidia-driver-injector-bridge-link-cap status 2>/dev/null | grep -q '^bridge='; then
        green "  applying bridge-link-cap now (so the next docker run sees a capped link)"
        /usr/local/sbin/nvidia-driver-injector-bridge-link-cap apply
    else
        yellow "  GPU not currently enumerated; cap will apply at next boot"
    fi
else
    yellow "  reboot pending or dry-run; skipping live apply"
fi
