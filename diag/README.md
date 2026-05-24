# nvidia-driver-diag

Companion **diagnostic** container for `nvidia-driver-injector` — bundles
[`nvbandwidth`](https://github.com/NVIDIA/nvbandwidth) and `deviceQuery`
(from [`cuda-samples`](https://github.com/NVIDIA/cuda-samples)) in a
distro-neutral CUDA image so the **injector container stays
single-purpose** (kernel-module load) and **host-installed CUDA binaries
never break** across distro updates.

## Purpose

What this container is **for**:

- Quick health check of a Thunderbolt-tunneled eGPU's effective
  bandwidth ceiling — `H2D` (upload), `D2H` (download), and
  full-duplex `H2D-bidirectional` (the realistic worst-case under
  simultaneous inference traffic).
- Reporting GPU capabilities (SM count, compute capability, BAR sizes,
  theoretical bandwidth) for documentation + regression tracking.
- Capturing a known-good baseline reading immediately after a host
  reboot, kernel upgrade, or injector image bump.

What this container is **not for**:

- Soak monitoring — that's the injector's job (Q-watchdog kthread, AER
  counters, sysfs telemetry).
- Model serving perf — that lives in a separate vLLM-side repo per
  project scope.
- GPU stress / burn-in — different tool, different lifecycle (a future
  `diag-stress` companion could carry `gpu-burn` if needed).

## Quick start

```bash
# 1. Build (one-off, ~3-5 min — pulls cuda:13.0.0-devel, compiles both tools)
sudo docker compose -f diag/docker-compose.yml build

# 2. Canonical baseline — H2D + D2H + D2D + deviceQuery summary (eyeball check)
sudo docker compose -f diag/docker-compose.yml run --rm diag suite

# 3. Capture to file (commit for posterity / regression tracking)
sudo docker compose -f diag/docker-compose.yml run --rm diag suite \
    > diag/baseline-$(date +%F)-$(cat /sys/module/nvidia/version 2>/dev/null || echo unknown).txt
```

Other invocations:

```bash
# List all nvbandwidth tests (D2D-read, multinode, latency variants, …)
sudo docker compose -f diag/docker-compose.yml run --rm diag nvbandwidth -l

# Run a specific test
sudo docker compose -f diag/docker-compose.yml run --rm diag \
    nvbandwidth -t device_to_device_memcpy_read_ce

# Just deviceQuery
sudo docker compose -f diag/docker-compose.yml run --rm diag deviceq

# JSON output for telemetry (parses cleanly — nvbandwidth's
# only structured-output mode; `suite-csv` accepted as an alias)
sudo docker compose -f diag/docker-compose.yml run --rm diag suite-json

# Bundled tool versions + image build date
sudo docker compose -f diag/docker-compose.yml run --rm diag version
```

## Bundled tools

| Tool | Upstream | Pinned at | Purpose |
|---|---|---|---|
| `nvbandwidth` | [NVIDIA/nvbandwidth](https://github.com/NVIDIA/nvbandwidth) | `v0.9` | Canonical PCIe / NVLink bandwidth benchmark — the TB4 throughput-ceiling measurement tool. |
| `deviceQuery` | [NVIDIA/cuda-samples](https://github.com/NVIDIA/cuda-samples) | `v13.0` | GPU capabilities report — SM count, compute cap, BAR sizes, theoretical bandwidth. |
| `nvidia-smi` | Runtime-injected by NVIDIA Container Toolkit | host driver version | Sanity / `pstate` / link gen+width reporting. |

Bumping any pinned tag requires re-building the image **and** re-capturing
a baseline reading on known-good hardware.

## Why isolated

The injector container's duty is to load the patched `nvidia.ko` and
keep it loaded — its `restart: unless-stopped` posture means a container
crash triggers a re-load, and a re-load of a wedged GPU is dangerous.
That container therefore stays minimal (debian:13-slim, no CUDA toolkit,
no boost-devel) so its blast radius is small and its build surface
narrow.

The diagnostic tools, by contrast, want the full CUDA devel toolchain at
build time and pull in ~1 GB of boost-devel + runtime libraries. Folding
them into the injector image would bloat a 723 MB image to >1.5 GB for
binaries the runtime never invokes. Worse, a CUDA-toolkit ABI break (we
have already lived through `boost 1.83 → 1.90`) would force an injector
rebuild for a non-load-bearing reason.

Two containers, two lifecycles, two failure domains. Same repo so they
stay version-aligned; same `docker compose` UX so operators do not have
to learn a new invocation.

## Building locally

```bash
cd /root/nvidia-driver-injector
sudo docker compose -f diag/docker-compose.yml build
```

Or with raw docker:

```bash
sudo docker build -t apnex/nvidia-driver-diag:1.0 diag/
```

Target runtime image size: **< 800 MB**.

## Versioning

The diag container has **independent semver** (`1.0`, `1.1`, …), NOT
the injector's `595.71.05-aorus.<N>` scheme. The two evolve separately:
a new injector tag does not invalidate the diag image, and vice versa.

## Adding a future tool

Pattern (e.g. to add `p2pBandwidthLatencyTest` when a second GPU
arrives):

1. Add the `git clone` + `cmake --build` step in the **Stage 1** builder
   block of `Dockerfile`, pinning the upstream tag with a `Stage 1`
   `ARG`.
2. Copy the binary in **Stage 2** via `COPY --from=builder ...`.
3. Add a dispatcher subcommand in `entrypoint.sh` with a `cmd_<name>`
   function + a `case` arm. Reuse `require_gpu` for the GPU-access
   pre-flight.
4. Document the new subcommand in this README's **Bundled tools** table
   and in the dispatcher's `cmd_help` heredoc.
5. Bump the image tag to `1.<N>` and re-capture a baseline reading.

Each tool stays a pure addition — no existing subcommand changes.
