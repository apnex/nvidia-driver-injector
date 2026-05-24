#!/usr/bin/env bash
# nvidia-driver-diag entrypoint — companion diagnostic dispatcher.
#
# Subcommands:
#   help              — usage (default; also for no-arg, --help, -h).
#   version           — bundled tool versions + image build date.
#   nvbandwidth [...] — pass through to nvbandwidth; defaults to the
#                       canonical CE baseline if no args supplied.
#   deviceq           — run deviceQuery.
#   suite             — canonical baseline: H2D + D2H + D2D + deviceQuery
#                       (plain-text output, for human reading + commit).
#   suite-json        — same baseline but JSON output (for telemetry).
#                       Note: spec asked for --csv but nvbandwidth only
#                       supports --json/-j as a structured output mode.
#
# Defensive: every GPU-touching subcommand refuses if nvidia-smi is
# missing from the container's namespace (operator forgot `--gpus all`
# / `runtime: nvidia`). Failing here surfaces the real cause instead of
# letting nvbandwidth report a cryptic CUDA-init error.

set -euo pipefail

log()  { printf '[diag] %s\n' "$*"; }
warn() { printf '[diag] WARN: %s\n' "$*" >&2; }
fail() { printf '[diag] FAIL: %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# GPU-access pre-flight. nvidia-smi presence (via libnvidia-ml.so injected
# by the container toolkit at runtime) is the cheap proxy: if it is not
# there, no CUDA call will succeed regardless of subcommand.
# ----------------------------------------------------------------------------
require_gpu() {
    if ! command -v nvidia-smi >/dev/null 2>&1; then
        fail "nvidia-smi not in container — GPU not exposed.
       Re-run with GPU access:
         docker run --rm --gpus all apnex/nvidia-driver-diag:1.0 <subcmd>
       or
         docker compose -f diag/docker-compose.yml run --rm diag <subcmd>"
    fi
    if ! nvidia-smi -L >/dev/null 2>&1; then
        fail "nvidia-smi present but reports no GPU.
       Verify the host driver is loaded:  lsmod | grep nvidia
       and that the container toolkit is installed:  nvidia-ctk --version"
    fi
}

# ----------------------------------------------------------------------------
# Canonical baseline test set — the three CE-engine memcpy paths that
# characterise a TB-tunneled eGPU's effective bandwidth ceiling on a
# single-GPU host:
#   host_to_device_memcpy_ce               — H2D, the TB4 upload path
#   device_to_host_memcpy_ce               — D2H, the TB4 download path
#   host_to_device_bidirectional_memcpy_ce — full-duplex H2D under
#                                            simultaneous D2H load
#                                            (the realistic worst case
#                                            for inference / training)
# Picked because they are the three numbers operators care about
# day-to-day on this hardware. device_to_device_* tests are SKIPPED
# (nvbandwidth waives them on single-GPU hosts — they measure
# inter-peer transfer between accessible GPUs and need ≥2 devices).
# When a second GPU arrives the D2D set + p2pBandwidthLatencyTest
# become relevant; see diag/README.md "Adding a future tool".
BASELINE_TESTS=(
    host_to_device_memcpy_ce
    device_to_host_memcpy_ce
    host_to_device_bidirectional_memcpy_ce
)

cmd_help() {
    cat <<'EOF'
nvidia-driver-diag — GPU bandwidth + capability diagnostics

Usage:
  diag <subcommand> [args...]

Subcommands:
  help              Show this message (default).
  version           Print bundled tool + image versions.
  nvbandwidth [..]  Run nvbandwidth; passes through extra args.
                    Default (no args): the canonical CE baseline set.
                    Use `nvbandwidth -l` to list all available tests.
  deviceq           Run deviceQuery — report SM count, compute cap,
                    BAR sizes, theoretical bandwidth.
  suite             Canonical plain-text baseline:
                      H2D + D2H + H2D-bidirectional + deviceQuery.
                    Use this for a quick eyeball check of TB4 health.
  suite-json        Same baseline tests but JSON output — for
                    telemetry capture / regression tracking.
                    (nvbandwidth's only structured-output mode.)

Examples:
  # Quick eyeball check after a host reboot
  docker compose -f diag/docker-compose.yml run --rm diag suite

  # One-off bandwidth-only run with a different test
  docker compose -f diag/docker-compose.yml run --rm diag \
      nvbandwidth -t device_to_device_memcpy_read_ce

  # Capture a baseline reading to a file
  docker compose -f diag/docker-compose.yml run --rm diag suite \
      > baseline-$(date +%F).txt

Notes:
  - This container is the diag companion to nvidia-driver-injector.
    The injector loads/owns the patched nvidia.ko on the host; this
    container only reads it via the NVIDIA Container Toolkit.
  - NOT a soak-monitor or model-perf rig — point measurements only.
EOF
}

cmd_version() {
    # Robust against any of: nvbandwidth missing libnvidia-ml (operator
    # forgot --gpus all), version line moving, json grep miss. Each
    # lookup is set-e-safe.
    local nvb_ver='unknown'
    if command -v nvbandwidth >/dev/null 2>&1; then
        local raw
        raw="$(nvbandwidth --version 2>&1 || true)"
        local parsed
        parsed="$(printf '%s\n' "$raw" | awk '/Version:/ {print $NF; exit}')"
        [[ -n "$parsed" ]] && nvb_ver="$parsed"
    fi

    local build_date='unknown'
    [[ -r /etc/diag-build-date ]] && build_date="$(cat /etc/diag-build-date)"

    local cuda_ver='unknown'
    if [[ -r /usr/local/cuda/version.json ]]; then
        local parsed
        parsed="$(awk -F'"' '/"version"/ {print $4; exit}' /usr/local/cuda/version.json 2>/dev/null || true)"
        [[ -n "$parsed" ]] && cuda_ver="$parsed"
    fi

    cat <<EOF
nvidia-driver-diag image version : ${DIAG_IMAGE_VERSION:-unknown}
image build date (UTC)           : ${build_date}
nvbandwidth                      : ${nvb_ver}  (upstream tag ${NVBANDWIDTH_TAG:-?})
deviceQuery                      : cuda-samples ${CUDA_SAMPLES_TAG:-?}
CUDA runtime                     : ${cuda_ver}
EOF
}

cmd_nvbandwidth() {
    require_gpu
    if [[ $# -eq 0 ]]; then
        log "no args supplied — running canonical CE baseline"
        # nvbandwidth's -t flag takes one testcase name per occurrence
        # (boost::program_options multi-value), so we expand the array
        # to repeated -t pairs.
        local args=()
        local t
        for t in "${BASELINE_TESTS[@]}"; do args+=(-t "$t"); done
        exec nvbandwidth "${args[@]}"
    fi
    exec nvbandwidth "$@"
}

cmd_deviceq() {
    require_gpu
    exec deviceQuery
}

cmd_suite() {
    require_gpu

    # Expand baseline array to repeated `-t name` pairs (boost
    # program_options multi-value).
    local nvb_args=()
    local t
    for t in "${BASELINE_TESTS[@]}"; do nvb_args+=(-t "$t"); done

    printf '============================================================\n'
    printf ' nvidia-driver-diag suite — %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '============================================================\n'
    cmd_version
    printf '\n'

    printf '%s\n' '------------------------------------------------------------'
    printf ' GPU + driver (nvidia-smi)\n'
    printf '%s\n' '------------------------------------------------------------'
    nvidia-smi --query-gpu=name,driver_version,pstate,pcie.link.gen.current,pcie.link.width.current,memory.total \
               --format=csv || true
    printf '\n'

    printf '%s\n' '------------------------------------------------------------'
    printf ' nvbandwidth — canonical CE baseline\n'
    printf '%s\n' '------------------------------------------------------------'
    nvbandwidth "${nvb_args[@]}" || true
    printf '\n'

    printf '%s\n' '------------------------------------------------------------'
    printf ' deviceQuery — capabilities\n'
    printf '%s\n' '------------------------------------------------------------'
    deviceQuery || true
}

cmd_suite_json() {
    require_gpu
    local nvb_args=()
    local t
    for t in "${BASELINE_TESTS[@]}"; do nvb_args+=(-t "$t"); done
    # nvbandwidth's machine-readable mode is --json (no --csv flag).
    exec nvbandwidth "${nvb_args[@]}" --json
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
SUBCOMMAND="${1:-help}"
shift || true

case "$SUBCOMMAND" in
    ""|help|-h|--help)
        cmd_help
        ;;
    version|--version|-V)
        cmd_version
        ;;
    nvbandwidth|nvb)
        cmd_nvbandwidth "$@"
        ;;
    deviceq|devicequery)
        cmd_deviceq
        ;;
    suite)
        cmd_suite
        ;;
    suite-json|suite-csv)
        # suite-csv accepted as alias for back-compat with the original
        # spec; both produce JSON because nvbandwidth has no CSV mode.
        cmd_suite_json
        ;;
    *)
        fail "unknown subcommand: '${SUBCOMMAND}'
       run 'diag help' for usage"
        ;;
esac
