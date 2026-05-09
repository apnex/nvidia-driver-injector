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
#
# Invocation:
#   docker compose up -d                                  # load (default)
#   docker compose run --rm driver-injector uninstall     # graceful unload
#   docker run --rm --privileged --pid=host \
#     -v /sys:/sys -v /dev:/dev -v /lib/modules:/lib/modules \
#     apnex/nvidia-driver-injector:<tag> uninstall

set -euo pipefail

log()  { printf '[nvidia-driver-injector] %s\n' "$*"; }
warn() { printf '[nvidia-driver-injector] WARN: %s\n' "$*" >&2; }
fail() { printf '[nvidia-driver-injector] FAIL: %s\n' "$*" >&2; exit 1; }

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
            fail "stop GPU consumers (vLLM, ollama, nvidia-persistenced, …) and retry"
        fi
    else
        # fuser not in image → fall back to checking refcount.
        local rc
        rc="$(cat /sys/module/nvidia/refcnt 2>/dev/null || echo 0)"
        if [[ "$rc" != "0" ]]; then
            fail "/sys/module/nvidia/refcnt = ${rc} (≠ 0) — module in use; refusing rmmod"
        fi
    fi

    # Unload in reverse-dependency order. `rmmod -s` quiets non-existent-module
    # noise; we already gated on /proc/modules so genuine errors will surface.
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if grep -q "^${m} " /proc/modules; then
            log "rmmod ${m} ..."
            if ! rmmod "$m"; then
                fail "rmmod ${m} failed — kernel state may be inconsistent.
       Check 'dmesg | tail' and 'lsof /dev/nvidia*'.
       Recovery: reboot the host, or run apply.sh from aorus-5090-egpu repo."
            fi
        fi
    done

    # Verify post-rmmod
    for m in nvidia_uvm nvidia_drm nvidia_modeset nvidia; do
        if grep -q "^${m} " /proc/modules; then
            fail "post-rmmod verify: ${m} still loaded (refcount race?)"
        fi
    done

    log "uninstall ✓ — all nvidia* modules unloaded from host kernel"
    log "host state restored to pre-injector baseline"
    log "(re-run 'docker compose up' to reload)"
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
    *)
        fail "unknown subcommand: '${SUBCOMMAND}' (expected: load | uninstall)"
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
    exec sleep infinity
fi
log "PCI gate ✓ — GPU at ${EGPU_BDF}"

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
    fail "BAR1 too small: ${bar1_size} bytes (need ≥ ${EXPECTED_BAR1_BYTES} = 32 GiB).
       Host likely missing 'thunderbolt.host_reset=false' or
       'pci=resource_alignment=35@<bridge_bdf>' kernel cmdline.
       See https://github.com/apnex/aorus-5090-egpu for host-side prerequisites."
fi
log "BAR1 verify ✓ — $((bar1_size / 1024 / 1024 / 1024)) GiB"

# ============================================================================
# Step 3: Build kernel modules against host kernel
# ============================================================================

if [[ ! -d "$KSRC" ]]; then
    fail "${KSRC} not found — host needs kernel-devel installed AND /lib/modules
       bind-mounted into the container. Re-run with:
       docker run ... -v /lib/modules:/lib/modules:ro ..."
fi

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
    fail "build failed"
}
log "build ✓"

# ============================================================================
# Step 4: Load modules into host kernel
# ============================================================================
# Why insmod direct, not modprobe:
#   - Host's /etc/modprobe.d/aorus-egpu-compute-only.conf has
#     'install nvidia /bin/false' to block accidental modprobe on host.
#   - modprobe inside the container would see the host's modprobe.d via
#     /etc/modprobe.d bind-mount (if present) and refuse the install.
#   - insmod operates on the .ko file directly — no modprobe.d consulted.
#   - This matches the semantics that the host service achieves with
#     `modprobe --ignore-install nvidia`.

# Module paths after build — open-gpu-kernel-modules layout has them under
# kernel-open/.
KO_NVIDIA="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia.ko"
KO_UVM="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-uvm.ko"
KO_MODESET="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-modeset.ko"
KO_DRM="/src/nvidia-open-gpu-kernel-modules/kernel-open/nvidia-drm.ko"

[[ -f "$KO_NVIDIA" ]] || fail "expected ${KO_NVIDIA} not found after build"

# Already loaded? skip — idempotent on repeated pod starts (k8s-friendly).
if grep -q '^nvidia ' /proc/modules; then
    log "nvidia already loaded — skipping insmod"
else
    log "insmod nvidia.ko ..."
    insmod "$KO_NVIDIA" || fail "insmod nvidia.ko failed"
fi

if grep -q '^nvidia_uvm ' /proc/modules; then
    log "nvidia_uvm already loaded — skipping insmod"
else
    log "insmod nvidia-uvm.ko ..."
    insmod "$KO_UVM" || warn "insmod nvidia-uvm.ko failed (non-fatal)"
fi

# Verify the patched build is loaded (project markers visible in modinfo).
loaded_version="$(cat /sys/module/nvidia/version 2>/dev/null || echo unknown)"
log "load ✓ — nvidia version: ${loaded_version}"

# Verify GPU bound to nvidia
sleep 1
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

if command -v nvidia-modprobe >/dev/null 2>&1; then
    log "nvidia-modprobe -u -c 0 ..."
    nvidia-modprobe -u -c 0 || warn "nvidia-modprobe -u -c 0 failed (non-fatal)"
else
    warn "nvidia-modprobe not in container PATH — /dev/nvidia-uvm-tools may be missing"
fi

ls -la /dev/nvidia* 2>/dev/null | sed 's/^/  /' || true

# ============================================================================
# Done — sleep as container of intent
# ============================================================================
log "=========================================="
log "  nvidia driver loaded successfully"
log "  patches applied: $(ls /src/patches/*.patch | wc -l)"
log "  upstream tag:    ${NVIDIA_OPEN_TAG:-(image build-time pinned)}"
log "=========================================="
log "sleeping as container of intent — exit triggers restart policy"

exec sleep infinity
