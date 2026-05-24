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
#      (production NVreg options including NVreg_TbEgpuRecoverEnable=1).
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
#  10. k3s / Kubernetes integration (only if k3s is present on the host):
#      a) `nvidia-ctk runtime configure --runtime=containerd` so containerd
#         picks up the nvidia runtime handler (idempotent — no-op on
#         subsequent runs once the config drop-in is in place).
#      b) Install the cluster-side `RuntimeClass nvidia` so consumer
#         Deployments can `runtimeClassName: nvidia`.
#      Skipped entirely with `--skip-k3s` (docker-compose-only operators).
#
# What this does NOT do:
#   - Build or load nvidia.ko. That's the injector container's job
#     (Layer 2). Once this script exits, EITHER `docker compose up -d`
#     in the repo root OR `kubectl apply -f k8s/daemonset.yaml` will load
#     the patched module via modprobe, picking up the modprobe.d options
#     this script just installed.
#
# Flags:
#   --no-act         Print every action without making changes.
#   --force-coexist  Skip the aorus-egpu conflict check (use with care).
#   --skip-cmdline   Don't touch kernel cmdline (you'll manage it yourself).
#   --skip-icd       Don't touch Vulkan/EGL/OpenCL ICD files.
#   --skip-k3s       Don't touch k3s containerd config or RuntimeClass.
#                    Use this for docker-compose-only deployments, or when
#                    you manage k3s integration via your own config tool.
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
SKIP_K3S=0

for arg in "$@"; do
    case "$arg" in
        --no-act)        NO_ACT=1 ;;
        --force-coexist) FORCE_COEXIST=1 ;;
        --skip-cmdline)  SKIP_CMDLINE=1 ;;
        --skip-icd)      SKIP_ICD=1 ;;
        --skip-k3s)      SKIP_K3S=1 ;;
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
step "0/10 conflict check (apnex/aorus-5090-egpu artifacts?)"

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
step "1/10 kernel cmdline (grubby)"

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
step "2/10 kernel-devel for $(uname -r)"

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
step "3/10 gpu UNIX group + GID-rewrite in modprobe.d"

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
step "4/10 /etc/modprobe.d/nvidia-driver-injector.conf"

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
step "5/10 nvidia-driver-injector-bridge-link-cap (binary + systemd unit)"

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
step "6/10 udev rules"

act "install -m 0644 -D ${HOST_FILES}/etc/udev/rules.d/79-nvidia-driver-injector.rules /etc/udev/rules.d/79-nvidia-driver-injector.rules"
act "install -m 0644 -D ${HOST_FILES}/etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules /etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules"
act "udevadm control --reload-rules"
act "udevadm trigger --subsystem-match=pci --attr-match=vendor=0x10de --attr-match=device=0x22e8 --action=add 2>/dev/null || true"
green "  udev rules installed (perms + audio-disable)"

# ===========================================================================
# Step 7: Vulkan/EGL/OpenCL ICD disable (compute-only posture)
# ===========================================================================
step "7/10 Vulkan/EGL/OpenCL ICD disable"

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
# Step 8: apply bridge-link-cap now (without rebooting)
# ===========================================================================
step "8/10 apply bridge-link-cap now (without rebooting)"

if [[ "${CMDLINE_CHANGED:-0}" -eq 0 && "$NO_ACT" -eq 0 ]]; then
    if /usr/local/sbin/nvidia-driver-injector-bridge-link-cap status 2>/dev/null | grep -q '^bridge='; then
        green "  starting bridge-link-cap.service (applies cap; leaves service active=exited)"
        # Use `systemctl start` rather than running the binary directly so
        # the service's runtime state reflects reality after a fresh
        # install. status.sh checks `is-active` on the service; running
        # the binary directly leaves the service in inactive(dead) until
        # the next boot, producing a false-FAIL on the post-install verify.
        systemctl start nvidia-driver-injector-bridge-link-cap.service
    else
        yellow "  GPU not currently enumerated; cap will apply at next boot"
    fi
else
    yellow "  reboot pending or dry-run; skipping live apply"
fi

# ===========================================================================
# Step 9: k3s / Kubernetes integration (containerd config + RuntimeClass)
# ===========================================================================
# Detects k3s presence (binary OR systemd unit). When present:
#   a) `nvidia-ctk runtime configure --runtime=containerd` adds the nvidia
#      runtime handler to containerd's config. k3s reads its containerd config
#      from /var/lib/rancher/k3s/agent/etc/containerd/config.toml and merges
#      drop-ins from config-v3.toml.d/. nvidia-ctk targets /etc/containerd by
#      default; on k3s, the canonical pattern is the drop-in template
#      (/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.tmpl) which
#      k3s also auto-merges when the nvidia-container-runtime binary is
#      present at /usr/bin/nvidia-container-runtime. We let k3s auto-detect
#      where it can; otherwise nvidia-ctk's idempotent config drop-in covers
#      vanilla containerd hosts.
#   b) Cluster-side `RuntimeClass nvidia` so consumer pods can opt in with
#      `spec.runtimeClassName: nvidia`. Idempotent via `kubectl apply`.
#
# Skipped entirely with `--skip-k3s`.
step "9/10 k3s integration (containerd runtime + RuntimeClass)"

if [[ "$SKIP_K3S" -eq 1 ]]; then
    yellow "  --skip-k3s set; not touching k3s containerd config or RuntimeClass"
elif ! command -v k3s >/dev/null 2>&1 && ! systemctl list-unit-files k3s.service 2>/dev/null | grep -q '^k3s\.service'; then
    yellow "  k3s not present on this host; skipping k3s integration"
    yellow "  (re-run with k3s installed, or pass --skip-k3s to silence this)"
else
    green "  k3s detected"

    # (a) containerd configuration. k3s auto-merges the nvidia runtime when
    # /usr/bin/nvidia-container-runtime exists, so on a k3s host this is
    # often already wired up. Run nvidia-ctk anyway — it's idempotent and
    # covers operators who installed k3s before nvidia-container-toolkit.
    if command -v nvidia-ctk >/dev/null 2>&1; then
        act "nvidia-ctk runtime configure --runtime=containerd"
        # Verify post-config: either k3s's own containerd config OR
        # /etc/containerd/config.toml should reference the nvidia handler.
        k3s_cfg="/var/lib/rancher/k3s/agent/etc/containerd/config.toml"
        std_cfg="/etc/containerd/config.toml"
        found=0
        for cfg in "$k3s_cfg" "$std_cfg"; do
            if [[ -f "$cfg" ]] && grep -q "runtimes\.['\"\]nvidia['\"\]" "$cfg" 2>/dev/null; then
                green "    nvidia handler present in ${cfg}"
                found=1
            fi
        done
        if [[ "$found" -eq 0 ]]; then
            yellow "    nvidia handler not yet visible in containerd config;"
            yellow "    a containerd restart may be needed (sudo systemctl restart k3s)"
        fi
    else
        yellow "  nvidia-ctk not installed — install nvidia-container-toolkit first"
        yellow "  (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)"
    fi

    # (b) RuntimeClass — cluster-side resource so consumers can request the
    # nvidia runtime via spec.runtimeClassName. We talk to the local k3s API
    # via the embedded kubeconfig at /etc/rancher/k3s/k3s.yaml.
    if command -v kubectl >/dev/null 2>&1; then
        kubeconfig="/etc/rancher/k3s/k3s.yaml"
        if [[ ! -r "$kubeconfig" ]]; then
            yellow "    ${kubeconfig} not readable; skipping RuntimeClass install"
            yellow "    (k3s may not be running yet; re-run after k3s starts)"
        else
            if KUBECONFIG="$kubeconfig" kubectl get runtimeclass nvidia >/dev/null 2>&1; then
                green "    RuntimeClass/nvidia already present"
            else
                # printf-piped form so `act` (which uses eval) sees one
                # composable command string.
                rc_yaml='apiVersion: node.k8s.io/v1\nkind: RuntimeClass\nmetadata:\n  name: nvidia\nhandler: nvidia\n'
                act "printf '${rc_yaml}' | KUBECONFIG=${kubeconfig} kubectl apply -f -"
                green "    RuntimeClass/nvidia installed"
            fi
        fi
    else
        yellow "    kubectl not installed; cannot install RuntimeClass automatically."
        yellow "    Manually: kubectl apply -f - <<EOF"
        yellow "      apiVersion: node.k8s.io/v1"
        yellow "      kind: RuntimeClass"
        yellow "      metadata: { name: nvidia }"
        yellow "      handler: nvidia"
        yellow "    EOF"
    fi
fi

# ===========================================================================
# Step 10: summary + next-step guidance
# ===========================================================================
step "10/10 summary"

green "Layer 1 install complete."
echo
echo "Next steps:"
if [[ "${CMDLINE_CHANGED:-0}" -eq 1 ]]; then
    yellow "  1. Reboot to apply kernel cmdline changes:"
    echo "       sudo reboot"
    echo "  2. After reboot, bring up the injector — pick a path:"
else
    echo "  1. Bring up the injector — pick a path:"
fi
echo "       # Path A (dev / single-host): docker-compose"
echo "       cd ${REPO_ROOT} && docker compose up -d"
echo
echo "       # Path B (recommended for production): k3s DaemonSet"
echo "       cd ${REPO_ROOT} && kubectl apply -f k8s/daemonset.yaml"
echo "       kubectl rollout status -n kube-system ds/nvidia-driver-injector"
echo
echo "  2. Once ready, bring up your GPU consumer (e.g., vLLM):"
echo "     - Path A: cd /path/to/workload && docker compose up -d"
echo "     - Path B: see docs/consumer-contract.md (nodeSelector +"
echo "               runtimeClassName: nvidia)"
echo
