#!/usr/bin/env bash
# nvidia-driver-injector entrypoint — Approach B
# (distro-neutral; uses host's /lib/modules bind-mount).
#
# Subcommands:
#   load (default) — five-step bring-up:
#     1. PCI gate (eGPU enumerated?)
#     2. BAR1 verify (32 GiB?)
#     3. Build patched modules against host kernel
#     4. insmod nvidia.ko + nvidia-uvm.ko into host kernel
#     5. nvidia-modprobe -u -c 0 → UVM device files
#     Then sleep infinity as "container of intent".
#
#   uninstall — explicit, operator-intent teardown:
#     - Refuse if any process holds /dev/nvidia* (EBUSY-safe).
#     - rmmod nvidia_uvm, nvidia_modeset (if present), nvidia.
#     - Verify all gone; exit 0.
#     Module state is host state — this is the only graceful unload path.
#     `docker compose down` does NOT trigger this (correct asymmetry).
#     LEAVES the on-disk .ko at /lib/modules/<kver>/extra/ — the next
#     nvidia-tool invocation may auto-reload it.
#
#   purge — uninstall + remove the on-disk .ko files:
#     - Runs cmd_uninstall first (same safety checks).
#     - Then removes /lib/modules/<kver>/extra/nvidia*.ko.
#     After purge, kernel autoload has nothing to load — driver is truly
#     gone until the next container `load`. No reboot required.
#     Distinct from `scripts/remove.sh --purge` (which is the all-in-one
#     fresh-host reset path: Layer 1 reverse + cmdline revert + reboot).
#
# Invocation:
#   docker compose up -d                                  # load (default)
#   docker compose run --rm driver-injector uninstall     # graceful unload
#   docker compose run --rm driver-injector purge         # unload + rm .ko
#   docker run --rm --privileged --pid=host \
#     -v /sys:/sys -v /dev:/dev -v /lib/modules:/lib/modules \
#     apnex/nvidia-driver-injector:<tag> uninstall|purge
#   kubectl exec -n kube-system ds/nvidia-driver-injector -- \
#     /entrypoint.sh uninstall|purge                      # in-cluster

set -euo pipefail

# --- PC-4: structured exit codes ---
# CONTRACT: exit code values are STABLE. Never reuse a number across
# versions. Adding a new failure mode means adding a new number.
# Consumers (kubelet's lastState.terminated.exitCode, must-gather.sh,
# monitoring) treat these as a stable enum. Some codes are reserved
# for future fail-sites (PC-1 startupProbe, PC-3 readiness file) and
# may not yet appear in a fail() call — SC2034 here is intentional.
# shellcheck disable=SC2034
readonly EXIT_OK=0
# shellcheck disable=SC2034
readonly EXIT_NO_GPU=10              # PCI gate found no NVIDIA device
readonly EXIT_BAR1_TOO_SMALL=11      # device present but BAR1 < 32 GiB
readonly EXIT_KERNEL_BUILD_MISSING=20 # /lib/modules/$(uname -r)/build absent
readonly EXIT_MODPROBE_FAILED=30     # modprobe nvidia returned non-zero
readonly EXIT_GSP_FW_LOAD=31         # nvidia-smi reports firmware error
# shellcheck disable=SC2034
readonly EXIT_PERSISTENCE_FAILED=40  # nvidia-smi -pm 1 returned non-zero
# shellcheck disable=SC2034
readonly EXIT_DEVICE_MISSING=50      # /dev/nvidia* didn't materialise in time
readonly EXIT_DKMS_SCRUB_FAILED=60   # PC-7 scrub couldn't remove .ko.xz
readonly EXIT_UNKNOWN=99             # catch-all for not-yet-enumerated cases

log()  { printf '[nvidia-driver-injector] %s\n' "$*"; }
warn() { printf '[nvidia-driver-injector] WARN: %s\n' "$*" >&2; }

# fail() — replaces bare `exit 1` calls.
# Emits structured exit code AND writes a /dev/kmsg marker so the failure
# survives the container restart and is visible via dmesg/journalctl -k.
fail() {
    local code="$1"; shift
    local msg="$*"
    printf '[nvidia-driver-injector] FAIL (%s): %s\n' "$code" "$msg" >&2
    # /dev/kmsg is rate-limited; <3> is KERN_ERR priority.
    printf '<3>nvidia-driver-injector FAIL code=%s: %s\n' "$code" "$msg" \
        > /dev/kmsg 2>/dev/null || true
    # PC-3: record the failure in the readiness file so must-gather.sh
    # and external observers see *why* the container exited. Best-effort:
    # never let a state-file failure mask the real exit code.
    write_state "failed" "$code" "$msg" || true
    exit "$code"
}

# --- PC-3: readiness file as state machine ---
# Mirrors NVIDIA's /run/nvidia/validations/.driver-ctr-ready pattern
# (G1 audit). Consumed by the device plugin's initContainer for
# startup ordering AND by must-gather.sh for diagnostic data.
#
# Written atomically via tmp+mv. Removed in cmd_uninstall and via
# preStop hook.
readonly STATE_DIR=/run/nvidia/injector
readonly STATE_FILE="${STATE_DIR}/state"

# write_state <phase> [last_error_code] [last_error_msg]
# Phase enum: starting, scrubbing_dkms, kernel_build, modprobe,
#             materializing_devs, engaging_persistence, ready,
#             degraded, failed
write_state() {
    local phase="$1"
    local err_code="${2:-0}"
    local err_msg="${3:-}"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    mkdir -p "$STATE_DIR"
    local tmp="${STATE_FILE}.tmp.$$"
    # Driver version + PCI + BAR1 best-effort; OK to be empty in early phases.
    local driver_ver bar1_gib gpu_pci
    driver_ver=$(cat /sys/module/nvidia/version 2>/dev/null || echo "")
    gpu_pci=$(lspci -d 10de: 2>/dev/null | awk '{print $1; exit}')
    if [ -n "$gpu_pci" ]; then
        local bar1_bytes
        bar1_bytes=$(awk 'NR==2 {print strtonum("0x" $2) - strtonum("0x" $1) + 1}' \
            "/sys/bus/pci/devices/0000:${gpu_pci}/resource" 2>/dev/null || echo 0)
        bar1_gib=$((bar1_bytes / 1024 / 1024 / 1024))
    else
        bar1_gib=0
    fi
    # Build JSON with jq if available, fallback to printf.
    if command -v jq >/dev/null 2>&1; then
        jq -n \
            --arg phase "$phase" \
            --arg ts "$now" \
            --arg ver "$driver_ver" \
            --arg pci "$gpu_pci" \
            --argjson bar1 "$bar1_gib" \
            --argjson code "$err_code" \
            --arg msg "$err_msg" \
            '{phase:$phase, last_checked:$ts, driver_version:$ver,
              gpu_pci:$pci, bar1_size_gib:$bar1,
              last_error_code:$code, last_error:$msg}' > "$tmp"
    else
        printf '{"phase":"%s","last_checked":"%s","driver_version":"%s","gpu_pci":"%s","bar1_size_gib":%d,"last_error_code":%d,"last_error":"%s"}\n' \
            "$phase" "$now" "$driver_ver" "$gpu_pci" "$bar1_gib" "$err_code" "$err_msg" > "$tmp"
    fi
    mv -f "$tmp" "$STATE_FILE"
}

remove_state() {
    rm -f "$STATE_FILE"
}

# ============================================================================
# Node-label writer (k3s / Kubernetes consumer contract)
# ============================================================================
# After a successful module load, label the node so consumer Deployments can
# gate their nodeSelector on driver readiness. On graceful uninstall, remove
# both labels so consumers stop scheduling immediately.
#
# Activation:
#   - Auto-on when the pod is in-cluster (KUBERNETES_SERVICE_HOST set) AND a
#     bearer token mount exists at the SA's standard path.
#   - Hard off when INJECTOR_WRITE_NODE_LABEL=0 (operator override; useful for
#     debugging the injector standalone without touching cluster state).
#
# Labels written / removed:
#   nvidia.driver/state=ready        binary signal — "is the patched module loaded?"
#   nvidia.driver/version=<version>  richer match — read from /sys/module/nvidia/version
#
# Implementation: kubectl (baked into the image; ~50 MB on a 700+ MB base —
# rounding error). The SA + ClusterRole + ClusterRoleBinding in
# k8s/daemonset.yaml grant `get,patch` on nodes; nothing else.
node_label_should_run() {
    [[ "${INJECTOR_WRITE_NODE_LABEL:-1}" != "0" ]] || return 1
    [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]] || return 1
    [[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ]] || return 1
    command -v kubectl >/dev/null 2>&1 || {
        warn "node-label write requested but kubectl missing from image"
        return 1
    }
    [[ -n "${NODE_NAME:-}" ]] || {
        warn "NODE_NAME env not set (DaemonSet should inject it from fieldRef);
       skipping node-label write"
        return 1
    }
    return 0
}

cmd_label_node() {
    node_label_should_run || return 0
    local version="$1"   # e.g. 595.71.05-aorus.14
    log "labelling node ${NODE_NAME} (nvidia.driver/state=ready, version=${version}) ..."
    if kubectl label nodes "$NODE_NAME" \
            "nvidia.driver/state=ready" \
            "nvidia.driver/version=${version}" \
            --overwrite >/dev/null 2>&1; then
        log "node-label ✓ — consumers can now schedule against this node"
    else
        warn "kubectl label nodes ${NODE_NAME} failed — check RBAC
       (need ClusterRole granting get,patch on nodes for SA
       ${POD_NAMESPACE:-kube-system}/nvidia-driver-injector)"
    fi
}

cmd_unlabel_node() {
    node_label_should_run || return 0
    log "removing node labels on ${NODE_NAME} ..."
    # Trailing `-` deletes the label. Two separate kubectl calls so a missing
    # label on one doesn't block the other.
    kubectl label nodes "$NODE_NAME" "nvidia.driver/state-"   >/dev/null 2>&1 || true
    kubectl label nodes "$NODE_NAME" "nvidia.driver/version-" >/dev/null 2>&1 || true
    log "node-label ✓ — labels removed (consumers will stop scheduling)"
}

# ============================================================================
# Subcommand: uninstall
# ============================================================================
# Graceful host-side teardown of the nvidia kernel modules. Safe-by-default:
# refuses to proceed if anything is holding /dev/nvidia*, and bails cleanly
# when nothing is loaded.
#
# Why this is a SUBCOMMAND, not a SIGTERM trap:
#   - SIGTERM has a 10s grace before SIGKILL. rmmod on a wedged GPU can hang
#     longer than that and leave kernel state half-torn-down.
#   - Pod restart loops (kubelet OOM, scheduler eviction) would auto-rmmod on
#     every blip, hammering the close-path that Patches 0029/0030 mitigate.
#   - Module state is host state. Container lifecycle ≠ kernel state lifecycle.
# This subcommand is for explicit operator intent: driver upgrade, node
# decommission, or recovery from a wedged module.
cmd_uninstall() {
    log "=========================================="
    log "  UNINSTALL — graceful host-side teardown"
    log "=========================================="

    # First: remove the node labels so consumers stop scheduling onto this
    # node BEFORE we touch the module. Order matters — if rmmod takes a few
    # seconds and a fresh pod schedules in that window, it'll fail to open
    # /dev/nvidia*. Doing this unconditionally is safe (no-op if not in
    # cluster, no-op if labels never existed).
    cmd_unlabel_node

    # Pre-flight 1: nothing loaded at all? Nothing to do.
    local any_loaded=false
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if grep -q "^${m} " /proc/modules; then
            any_loaded=true
            break
        fi
    done
    if ! $any_loaded; then
        log "nothing to do — no nvidia* modules loaded in host kernel"
        return 0
    fi

    # Pre-flight 2: refuse if anything holds /dev/nvidia*. fuser exit 0 means
    # at least one process holds the file → EBUSY would be inevitable.
    if command -v fuser >/dev/null 2>&1; then
        local holders
        holders="$(fuser /dev/nvidia* 2>&1 || true)"
        if [[ -n "$holders" ]] && echo "$holders" | grep -qE '[0-9]+'; then
            warn "GPU has active users; refusing to rmmod:"
            echo "$holders" | sed 's/^/    /' >&2
            fail "$EXIT_UNKNOWN" "stop GPU consumers (vLLM, ollama, nvidia-persistenced, …) and retry"
        fi
    else
        # fuser not in image → fall back to checking refcount.
        local rc
        rc="$(cat /sys/module/nvidia/refcnt 2>/dev/null || echo 0)"
        if [[ "$rc" != "0" ]]; then
            fail "$EXIT_UNKNOWN" "/sys/module/nvidia/refcnt = ${rc} (≠ 0) — module in use; refusing rmmod"
        fi
    fi

    # Unload in reverse-dependency order. `rmmod -s` quiets non-existent-module
    # noise; we already gated on /proc/modules so genuine errors will surface.
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if grep -q "^${m} " /proc/modules; then
            log "rmmod ${m} ..."
            if ! rmmod "$m"; then
                fail "$EXIT_UNKNOWN" "rmmod ${m} failed — kernel state may be inconsistent.
       Check 'dmesg | tail' and 'lsof /dev/nvidia*'.
       Recovery: reboot the host, or run apply.sh from aorus-5090-egpu repo."
            fi
        fi
    done

    # Verify post-rmmod
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if grep -q "^${m} " /proc/modules; then
            fail "$EXIT_UNKNOWN" "post-rmmod verify: ${m} still loaded (refcount race?)"
        fi
    done

    log "uninstall ✓ — all nvidia* modules unloaded from host kernel"
    log "host state restored to pre-injector baseline"
    # PC-3: remove the readiness file — consumers (device plugin
    # initContainer, must-gather.sh, the startupProbe) treat absence
    # as "not ready" and will block / report accordingly.
    remove_state
    # KUBERNETES_SERVICE_HOST is set when running inside a k8s pod
    # (Path B); absent means we're on docker compose (Path A).
    if [[ -n "${KUBERNETES_SERVICE_HOST:-}" ]]; then
        log "(re-apply 'kubectl apply -f k8s/daemonset.yaml' to reload)"
    else
        log "(re-run 'docker compose up' to reload)"
    fi
    return 0
}

# ============================================================================
# Subcommand: purge
# ============================================================================
# Graceful unload PLUS removal of the on-disk patched .ko files. The
# container's load path writes nvidia.ko + nvidia-uvm.ko to
# /lib/modules/<kver>/extra/ via the bind-mount; by symmetry, this
# subcommand takes them back off. After purge, the kernel's autoload
# mechanism has nothing on disk to load — running `nvidia-smi` or any
# other nvidia-tool will NOT bring the driver back.
#
# Distinct from `uninstall`:
#   uninstall — rmmod only. The .ko stays on disk; any later nvidia-tool
#               invocation will auto-reload it (since host modprobe.d
#               guards may or may not be in place).
#   purge     — rmmod + rm. Driver truly gone until next container `load`.
#
# Distinct from `remove.sh --purge`:
#   This subcommand operates on Layer 2 (kernel module state) ONLY,
#   without rebooting and without touching Layer 1 host config. Use it
#   when you want the driver out of the kernel now — e.g., before a
#   diagnostic boot, or before deleting the DaemonSet entirely.
#   `remove.sh --purge` is the all-in-one fresh-host reset path that
#   additionally reverts kernel cmdline + restores ICDs + requires a
#   reboot.
cmd_purge() {
    log "=========================================="
    log "  PURGE — graceful unload + on-disk module removal"
    log "=========================================="

    # Step 1: graceful rmmod (delegate to cmd_uninstall — same safety
    # checks: refuse if /dev/nvidia* held; reverse-dependency order).
    # cmd_uninstall calls fail() on any error, which exits non-zero.
    cmd_uninstall

    # Step 2: remove on-disk .ko files.
    log ""
    log "removing on-disk module files ..."
    local kver
    kver="$(uname -r)"
    local extra_dir="/lib/modules/${kver}/extra"
    if [[ ! -d "$extra_dir" ]]; then
        log "purge ✓ — ${extra_dir} doesn't exist (nothing to remove)"
        return 0
    fi
    local removed=0
    for ko in "$extra_dir"/nvidia*.ko*; do
        if [[ -f "$ko" ]]; then
            if rm -f "$ko"; then
                log "  rm ${ko}"
                removed=$((removed + 1))
            else
                fail "$EXIT_UNKNOWN" "rm ${ko} failed (read-only bind-mount? need :rw on /lib/modules)"
            fi
        fi
    done
    if [[ "$removed" -gt 0 ]]; then
        log "purge ✓ — ${removed} on-disk .ko file(s) removed"
        log "host autoload of nvidia driver is now blocked (nothing on disk to load)"
    else
        log "purge ✓ — no nvidia*.ko files found at ${extra_dir}"
    fi
    return 0
}

# ============================================================================
# Subcommand dispatch
# ============================================================================
SUBCOMMAND="${1:-load}"
case "$SUBCOMMAND" in
    load|"")
        : # fall through to main bring-up flow below
        ;;
    uninstall)
        cmd_uninstall
        exit $?
        ;;
    purge)
        cmd_purge
        exit $?
        ;;
    *)
        fail "$EXIT_UNKNOWN" "unknown subcommand: '${SUBCOMMAND}' (expected: load | uninstall | purge)"
        ;;
esac

# Configurable — env var overrides for the rare custom topology.
EGPU_VENDOR_ID="${EGPU_VENDOR_ID:-0x10de}"
EGPU_DEVICE_ID="${EGPU_DEVICE_ID:-0x2b85}"
EGPU_BDF="${EGPU_BDF:-}"
EXPECTED_BAR1_BYTES="${EXPECTED_BAR1_BYTES:-34359738368}"  # 32 GiB

KVER="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"

log "host kernel: ${KVER}"
log "kernel build dir (bind-mounted from host): ${KSRC}"

# PC-3: announce we've begun the load sequence. From here on, the
# readiness file is the canonical signal of where we are.
write_state "starting"

# ============================================================================
# Step 1: PCI gate
# ============================================================================

# Auto-detect EGPU_BDF if not set: walk PCI for vendor:device match.
if [[ -z "$EGPU_BDF" ]]; then
    for d in /sys/bus/pci/devices/*; do
        [[ -r "$d/vendor" && -r "$d/device" ]] || continue
        v="$(<"$d/vendor")"
        dv="$(<"$d/device")"
        if [[ "$v" == "$EGPU_VENDOR_ID" && "$dv" == "$EGPU_DEVICE_ID" ]]; then
            EGPU_BDF="$(basename "$d")"
            break
        fi
    done
fi

if [[ -z "$EGPU_BDF" || ! -e "/sys/bus/pci/devices/${EGPU_BDF}" ]]; then
    log "no GPU matching ${EGPU_VENDOR_ID}:${EGPU_DEVICE_ID} found on PCI"
    log "exiting cleanly — pod will restart per restart policy or scheduler"
    write_state "degraded" "$EXIT_NO_GPU" "no GPU enumerated; entrypoint waiting for hot-plug"
    exec sleep infinity
fi
log "PCI gate ✓ — GPU at ${EGPU_BDF}"

# ============================================================================
# Step 1.25: PC-7 — DKMS pre-flight scrub
# ============================================================================
# Fedora's kernel-core update auto-builds vanilla nvidia*.ko.xz via DKMS.
# depmod prefers compressed over uncompressed, so a stale DKMS artifact
# would shadow our patched build and modprobe would silently load vanilla.
# Remove before our build/load sequence.
# See feedback_dkms_vanilla_vs_patched_module_collision (project memory).
write_state "scrubbing_dkms"
log "PC-7: scanning for DKMS-built vanilla nvidia artifacts"
KMOD_DIR="/lib/modules/$(uname -r)/extra"
DKMS_ARTIFACTS="$(find "$KMOD_DIR" -maxdepth 1 -name 'nvidia*.ko.xz' 2>/dev/null || true)"
if [[ -n "$DKMS_ARTIFACTS" ]]; then
    log "PC-7: scrubbing DKMS artifacts to prevent vanilla shadowing:"
    printf '%s\n' "$DKMS_ARTIFACTS" | sed 's/^/  /'
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        if ! rm -f "$f"; then
            fail "$EXIT_DKMS_SCRUB_FAILED" "could not remove DKMS artifact: $f
       (is /lib/modules bind-mounted rw? does the container have CAP_DAC_OVERRIDE?)"
        fi
    done <<< "$DKMS_ARTIFACTS"
    if ! depmod -a "$(uname -r)"; then
        fail "$EXIT_DKMS_SCRUB_FAILED" "depmod -a $(uname -r) failed after DKMS scrub
       (module index inconsistent; modprobe may load stale entries)"
    fi
    log "PC-7: scrub complete"
else
    log "PC-7: no DKMS artifacts found (clean)"
fi

# ============================================================================
# Step 1.5: Clear driver_override if blocking nvidia bind
# ============================================================================
# The companion repo's remove.sh sets driver_override to a sentinel
# ('aorus_egpu_manual') so that, while the host stack is uninstalled, no
# driver — including nvidia — can auto-bind to the GPU. The kernel honours
# this even when nvidia.ko's pci_register_driver runs at insmod time:
# probe is silently skipped and dmesg reports "NVIDIA probe routine was not
# called for 1 device(s)".
# Clear the override (only when set to a non-nvidia value) so this container
# is a self-sufficient loader after a remove.sh teardown.
override_path="/sys/bus/pci/devices/${EGPU_BDF}/driver_override"
if [[ -e "$override_path" ]]; then
    cur="$(cat "$override_path" 2>/dev/null || true)"
    case "$cur" in
        ""|"(null)"|"nvidia")
            : # nothing to do
            ;;
        *)
            log "driver_override blocking nvidia (was: '${cur}') — clearing"
            # sysfs accepts empty write to clear; trailing newline is stripped.
            if ! printf '\n' > "$override_path" 2>/dev/null; then
                warn "failed to clear driver_override at ${override_path};
       insmod will succeed but nvidia probe will not fire on ${EGPU_BDF}.
       Resolve manually:  echo > ${override_path}"
            fi
            ;;
    esac
fi

# ============================================================================
# Step 2: BAR1 verify
# ============================================================================

resource_line="$(awk 'NR==2 {print $1, $2}' "/sys/bus/pci/devices/${EGPU_BDF}/resource")"
read -r bar1_start bar1_end <<< "$resource_line"
bar1_size=$(( bar1_end - bar1_start + 1 ))

if [[ $bar1_size -lt $EXPECTED_BAR1_BYTES ]]; then
    fail "$EXIT_BAR1_TOO_SMALL" "BAR1 too small: ${bar1_size} bytes (need ≥ ${EXPECTED_BAR1_BYTES} = 32 GiB).
       Host likely missing 'thunderbolt.host_reset=false' or
       'pci=resource_alignment=35@<bridge_bdf>' kernel cmdline.
       See https://github.com/apnex/aorus-5090-egpu for host-side prerequisites."
fi
log "BAR1 verify ✓ — $((bar1_size / 1024 / 1024 / 1024)) GiB"

# ============================================================================
# Step 3: Build kernel modules against host kernel
# ============================================================================

if [[ ! -d "$KSRC" ]]; then
    fail "$EXIT_KERNEL_BUILD_MISSING" "kernel build dir absent: ${KSRC} — host needs kernel-devel installed AND /lib/modules
       bind-mounted into the container. Re-run with:
       docker run ... -v /lib/modules:/lib/modules:ro ..."
fi

write_state "kernel_build"
log "building modules against ${KSRC} ..."
cd /src/nvidia-open-gpu-kernel-modules
# IGNORE_CC_MISMATCH: kernel may have been built with a slightly different gcc
# than the container's gcc; on most distros this is fine — same major version.
# If you see ABI complaints, match the container's gcc to the host's.
make modules \
    KERNEL_UNAME="${KVER}" \
    SYSSRC="${KSRC}" \
    -j"$(nproc)" \
    IGNORE_CC_MISMATCH=1 \
    > /tmp/build.log 2>&1 || {
    warn "module build failed; tail of /tmp/build.log:"
    tail -40 /tmp/build.log >&2
    fail "$EXIT_MODPROBE_FAILED" "module build failed (see /tmp/build.log tail above)"
}
log "build ✓"

# ============================================================================
# Step 4: Load modules into host kernel
# ============================================================================
# Load via `modprobe --ignore-install` so /etc/modprobe.d/ options
# (NVreg_TbEgpuRecoverEnable=1, NVreg_DeviceFile*, etc.) apply.
# `--ignore-install` bypasses the `install ... /bin/false` guards that
# the host's nvidia-driver-injector.conf installs to block accidental
# auto-load — a clean separation: host posture is "nothing auto-loads",
# container posture is "we know what we're doing, here's the patched
# build with production options".
#
# The newly-built .ko has to be on the modules.dep search path. We
# install it under /lib/modules/<kver>/extra/ (which is bind-mounted
# from host) and run depmod so modprobe can find it.
#
# Falls back to insmod if modprobe isn't available or modprobe.d isn't
# bind-mounted (e.g. legacy compose without /etc/modprobe.d:ro mount).

# Module paths after build — open-gpu-kernel-modules layout has them under
# kernel-open/.
KO_NVIDIA="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia.ko"
KO_UVM="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-uvm.ko"
KO_MODESET="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-modeset.ko"
KO_DRM="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-drm.ko"

[[ -f "$KO_NVIDIA" ]] || fail "$EXIT_MODPROBE_FAILED" "expected ${KO_NVIDIA} not found after build"

# ----------------------------------------------------------------------------
# Firmware path — re-supply + symlink.
#
# The kernel's request_firmware() looks for GSP firmware at
#   /lib/firmware/nvidia/<NV_VERSION_STRING>/gsp_ga10x.bin
# where <NV_VERSION_STRING> is whatever -DNV_VERSION_STRING the module was
# built with (e.g. "595.71.05-aorus.13"). Upstream ships the firmware at the
# unmodified "595.71.05" path, so any project version bump needs a symlink:
#   /lib/firmware/nvidia/<our-version> → 595.71.05
#
# Two steps, both idempotent:
#   (a) ensure the upstream firmware base dir is populated — re-supply the
#       GSP blobs baked into this image (/opt/nvidia-firmware) if the host
#       lost them. The kernel reads firmware from the *host* /lib/firmware
#       (bind-mounted rw), so the blobs must physically be on the host.
#       This is the durability fix for the 2026-05-22 nvidia-kmod-common
#       incident — removing that RPM deleted /lib/firmware/nvidia/595.71.05.
#   (b) extract the version from the just-built .ko (single source of truth)
#       and ensure the per-version symlink exists.
fw_version=$(modinfo "$KO_NVIDIA" 2>/dev/null | awk '/^version:/ {print $2; exit}')
if [[ -n "$fw_version" ]]; then
    fw_base="/lib/firmware/nvidia"
    fw_target="$fw_base/595.71.05"
    fw_link="$fw_base/$fw_version"
    fw_stash="/opt/nvidia-firmware"   # GSP blobs baked into this image

    # (a) re-supply any missing GSP blob from the in-image copy.
    for fw in gsp_ga10x.bin gsp_tu10x.bin; do
        if [[ ! -s "$fw_target/$fw" && -s "$fw_stash/$fw" ]]; then
            mkdir -p "$fw_target"
            if install -m 0644 "$fw_stash/$fw" "$fw_target/$fw" 2>/dev/null; then
                log "firmware ✓ — re-supplied $fw to ${fw_target} from image"
            else
                warn "could not install $fw to ${fw_target} (is /lib/firmware bind-mounted rw?)"
            fi
        fi
    done

    # (b) per-version symlink.
    if [[ "$fw_version" == "595.71.05" ]]; then
        : # vanilla version — no symlink needed
    elif [[ ! -d "$fw_target" ]]; then
        warn "firmware base ${fw_target} missing and no in-image copy — GSP load will fail."
    elif [[ -L "$fw_link" || -d "$fw_link" ]]; then
        log "firmware symlink ✓ — ${fw_link} present"
    else
        if ln -sfn "595.71.05" "$fw_link" 2>/dev/null; then
            log "firmware symlink ✓ — created ${fw_link} → 595.71.05"
        else
            warn "could not create ${fw_link} (is /lib/firmware bind-mounted rw?)
       GSP load will fail with -ENOENT until this symlink exists."
        fi
    fi

    # (c) gate — verify every GSP blob this image ships resolves through
    #     $fw_link before the module loads. The kernel's request_firmware()
    #     reads nvidia/$fw_version/<blob> at device init; a missing blob or
    #     broken symlink there surfaces only as a cryptic "Direct firmware
    #     load ... failed with error -2" followed by RmInitAdapter failure
    #     — and the module load itself still "succeeds", so the GPU is left
    #     silently dead. Fail loudly here instead, naming the real cause.
    for fw in gsp_ga10x.bin gsp_tu10x.bin; do
        [[ -s "$fw_stash/$fw" ]] || continue   # not carried in this image
        if [[ ! -s "$fw_link/$fw" ]]; then
            fail "$EXIT_GSP_FW_LOAD" "GSP firmware not in place: ${fw_link}/${fw} does not resolve.
       The kernel will request nvidia/${fw_version}/${fw} at device init and
       fail with -ENOENT. Verify /lib/firmware is bind-mounted rw and that
       step (a) above re-supplied the blob from ${fw_stash}."
        fi
    done
    log "firmware gate ✓ — ${fw_version} GSP blobs resolve under ${fw_link}"
fi
# ----------------------------------------------------------------------------

# Detect whether the host's modprobe.d is bind-mounted (architecture
# expects /etc/modprobe.d to be mounted from host, ro).
HAS_HOST_MODPROBE_D=0
if [[ -f "/etc/modprobe.d/nvidia-driver-injector.conf" ]]; then
    HAS_HOST_MODPROBE_D=1
    log "host modprobe.d detected — production NVreg options will apply"
else
    warn "host /etc/modprobe.d not bind-mounted; falling back to insmod with no NVreg options.
       For production reliability, mount the host's modprobe.d into the container
       (see docker-compose.yml) and run apply.sh first."
fi

load_module() {
    local mod_short="$1"           # e.g. "nvidia"
    local ko_path="$2"

    if grep -q "^${mod_short} " /proc/modules; then
        log "${mod_short} already loaded — skipping"
        return 0
    fi

    if [[ "$HAS_HOST_MODPROBE_D" -eq 1 ]] && command -v modprobe >/dev/null 2>&1; then
        # Install the freshly-built .ko under /lib/modules/<kver>/extra/
        # so modprobe can find it. /lib/modules is bind-mounted writable
        # from host.
        local extra_dir="/lib/modules/${KVER}/extra"
        mkdir -p "$extra_dir"
        cp -u "$ko_path" "${extra_dir}/$(basename "$ko_path")"
        depmod -a "${KVER}" 2>/dev/null || true

        log "modprobe --ignore-install ${mod_short} ..."
        if modprobe --ignore-install "$mod_short"; then
            return 0
        fi
        warn "modprobe ${mod_short} failed; falling back to insmod"
    fi

    log "insmod ${ko_path} ..."
    insmod "$ko_path" || fail "$EXIT_MODPROBE_FAILED" "insmod ${ko_path} failed"
}

write_state "modprobe"
load_module "nvidia"     "$KO_NVIDIA"
load_module "nvidia_uvm" "$KO_UVM"

# Verify the patched build is loaded (project markers visible in modinfo).
loaded_version="$(cat /sys/module/nvidia/version 2>/dev/null || echo unknown)"
log "load ✓ — nvidia version: ${loaded_version}"

# Confirm the production-posture knob actually took effect.
recover_enable_path="/sys/module/nvidia/parameters/NVreg_TbEgpuRecoverEnable"
if [[ -r "$recover_enable_path" ]]; then
    re_val="$(cat "$recover_enable_path")"
    if [[ "$re_val" == "1" ]]; then
        log "tb_egpu recover ✓ — NVreg_TbEgpuRecoverEnable=1"
    else
        warn "NVreg_TbEgpuRecoverEnable=${re_val} (expected 1).
       Production posture not applied; the recovery state machine is OFF.
       Check that /etc/modprobe.d/nvidia-driver-injector.conf is bind-mounted
       and that apply.sh has been run on the host."
    fi
fi

# Verify GPU bound to nvidia. Wait briefly for kernel + udev to finish
# binding the device — bind-time creates /dev/nvidia0 and /dev/nvidiactl
# via devtmpfs, which the perms step below depends on.
for _ in 1 2 3 4 5; do
    if [[ -e "/sys/bus/pci/devices/${EGPU_BDF}/driver" ]]; then break; fi
    sleep 1
done
if [[ -e "/sys/bus/pci/devices/${EGPU_BDF}/driver" ]]; then
    bound_drv="$(basename "$(readlink "/sys/bus/pci/devices/${EGPU_BDF}/driver")")"
    if [[ "$bound_drv" == "nvidia" ]]; then
        log "bind ✓ — ${EGPU_BDF} bound to nvidia"
    else
        warn "${EGPU_BDF} bound to '${bound_drv}' (expected 'nvidia') — check driver_override on host"
    fi
fi

# ============================================================================
# Step 5: UVM device files (nvidia-modprobe -u -c 0)
# ============================================================================
# Materialises /dev/nvidia-uvm and /dev/nvidia-uvm-tools. Avoids first-cuInit
# trying to invoke nvidia-modprobe and racing.

write_state "materializing_devs"
if command -v nvidia-modprobe >/dev/null 2>&1; then
    log "nvidia-modprobe -u -c 0 ..."
    nvidia-modprobe -u -c 0 || warn "nvidia-modprobe -u -c 0 failed (non-fatal)"
else
    warn "nvidia-modprobe not in container PATH — /dev/nvidia-uvm-tools may be missing"
fi

# ============================================================================
# Step 6: /dev/nvidia* permissions (Gap #4)
# ============================================================================
# Done AFTER nvidia-modprobe so all four canonical devices exist:
#   - /dev/nvidia0, /dev/nvidiactl   (created by nvidia.ko at bind time)
#   - /dev/nvidia-uvm, -uvm-tools    (created by nvidia-modprobe -u -c 0)
#
# NVreg_DeviceFileMode/UID/GID in /etc/modprobe.d already sets perms on
# /dev/nvidia0 and /dev/nvidiactl at module-load time — chgrp/chmod here
# is belt-and-suspenders. The nvidia_uvm submodule has no NVreg
# equivalent, so this is the ONLY place /dev/nvidia-uvm gets group
# permissions tightened.
#
# udevadm settle synchronises with host udev so we don't race the
# rule's GROUP="gpu" MODE="0660" assignments. Bounded to 5s.
if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=5 2>/dev/null || true
fi

if getent group gpu >/dev/null 2>&1; then
    for dev in /dev/nvidia0 /dev/nvidiactl /dev/nvidia-uvm /dev/nvidia-uvm-tools; do
        if [[ -e "$dev" ]]; then
            if chgrp gpu "$dev" 2>/dev/null && chmod 0660 "$dev" 2>/dev/null; then
                log "perms ✓ — ${dev}: 0660 root:gpu"
            else
                warn "could not chgrp/chmod ${dev} — host udev may have it locked"
            fi
        else
            warn "${dev} not present after nvidia-modprobe — perms skipped"
        fi
    done
else
    warn "gpu group not present on host — leaving /dev/nvidia* perms at NVreg defaults
       (run apply.sh on the host to create the group + udev rule)"
fi

ls -la /dev/nvidia* 2>/dev/null | sed 's/^/  /' || true

# ============================================================================
# Step 7: Engage GPU — persistence mode + full hardware bringup
# ============================================================================
# `nvidia-smi -pm 1` opens /dev/nvidia0 once (first-client trigger → GSP load,
# PMU init, AORUS waterblock thermal subsystem engagement) AND sets the
# driver's runtime persistence-mode flag so the engagement survives the
# nvidia-smi process exit. Without this, the GPU sits in lazy-init state:
# cooler at floor RPM, idle power ~63 W instead of ~22 W proper P8
# (measured 2026-05-12).
#
# This is NOT the retired nvidia-persistenced daemon. -pm 1 sets a driver
# sysfs-style flag; no userspace process is kept alive. Same flag survives
# until module unload or explicit -pm 0.
#
# Tolerate failure: lazy state is functional, just thermally suboptimal.

write_state "engaging_persistence"
if command -v nvidia-smi >/dev/null 2>&1; then
    log "engaging GPU (nvidia-smi -pm 1) ..."
    pre=$(nvidia-smi --query-gpu=persistence_mode,power.draw --format=csv,noheader 2>/dev/null || echo "unknown")
    if nvidia-smi -pm 1 >/dev/null 2>&1; then
        post=$(nvidia-smi --query-gpu=persistence_mode,power.draw --format=csv,noheader 2>/dev/null || echo "unknown")
        log "engage ✓ — persistence_mode + thermal subsystem engaged"
        log "  before: ${pre}"
        log "  after:  ${post}"
    else
        warn "nvidia-smi -pm 1 failed — GPU may stay in lazy state (higher idle power until first client open)"
    fi
else
    warn "nvidia-smi missing from image — skipping persistence engagement (GPU will stay lazy)"
fi

# ============================================================================
# Step 8: Publish node readiness (k3s consumer contract)
# ============================================================================
# Now that the full bring-up (load + bind + perms + persistence-engage) is
# complete, publish the node label that consumer Deployments (vLLM etc.) gate
# their nodeSelector on. See docs/consumer-contract.md.

cmd_label_node "${loaded_version:-unknown}"

# ============================================================================
# Done — write ready state + enter active heartbeat
# ============================================================================
log "=========================================="
log "  nvidia driver loaded successfully"
log "  patches applied: $(/src/tools/compose-patchset.sh --patches-dir /src/patches 2>/dev/null | wc -l)"
log "  upstream tag:    ${NVIDIA_OPEN_TAG:-(image build-time pinned)}"
log "=========================================="

write_state "ready"
log "PC-3: state=ready written to $STATE_FILE"

# --- PC-3 active heartbeat (composite design) ---
# Re-verify driver state every HEARTBEAT_INTERVAL seconds. Update file
# timestamp + write phase=degraded if anything's wrong. This is more
# active than NVIDIA's "sleep infinity" pattern — appropriate for our
# eGPU/TB reality where GPUs can disappear at runtime.
readonly HEARTBEAT_INTERVAL="${HEARTBEAT_INTERVAL:-30}"
log "PC-3: entering active heartbeat loop (interval=${HEARTBEAT_INTERVAL}s)"
while :; do
    sleep "$HEARTBEAT_INTERVAL"
    if [ ! -f /sys/module/nvidia/version ]; then
        write_state "degraded" 30 "nvidia module unloaded mid-run"
        continue
    fi
    if [ ! -e /dev/nvidia0 ]; then
        write_state "degraded" 50 "/dev/nvidia0 disappeared"
        continue
    fi
    # All checks pass; refresh ready state (updates last_checked timestamp)
    write_state "ready"
done
