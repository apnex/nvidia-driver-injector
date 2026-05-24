# nvidia-driver-diag — companion diagnostic container
#
# Bundles GPU bandwidth + capability measurement tools (nvbandwidth,
# deviceQuery) in a distro-neutral CUDA image so the injector container
# stays single-purpose (module load) and host-installed CUDA binaries
# never break across distro updates.
#
# Multi-stage build keeps the runtime image small:
#   Stage 1: nvidia/cuda:13.0.0-devel-ubuntu24.04 — boost-dev + cmake + nvcc
#            clones nvbandwidth at the pinned tag and cuda-samples for
#            deviceQuery; compiles both.
#   Stage 2: nvidia/cuda:13.0.0-base-ubuntu24.04  — runtime boost only; copies
#            in the two binaries + entrypoint dispatcher.
#
# Tag: apnex/nvidia-driver-diag:1.0 (independent semver, NOT injector's
#      595.71.05-aorus.<N> scheme — diag and injector evolve separately).
#
# Base choice: ubuntu24.04 over ubi9 because UBI9 ships only runtime
# boost packages (`boost-program-options`), not `boost-devel`, which
# nvbandwidth needs at compile time. EPEL is not available in UBI9
# without subscription. Ubuntu's `libboost-program-options-dev` is the
# same package the upstream nvbandwidth `debian_install.sh` installs.

# ============================================================================
# Stage 1: builder
# ============================================================================
FROM nvidia/cuda:13.0.0-devel-ubuntu24.04 AS builder

# Pinned upstream refs — bumping these requires re-validating the build
# and re-capturing a baseline reading on known-good hardware.
ARG NVBANDWIDTH_TAG=v0.9
ARG CUDA_SAMPLES_TAG=v13.0

# Build deps: libboost-program-options-dev (nvbandwidth's program_options
# dep), cmake, git for upstream fetches.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libboost-program-options-dev \
        cmake \
        git \
        ca-certificates \
        build-essential \
    && rm -rf /var/lib/apt/lists/*

# Output dir for compiled binaries — final stage COPYs from /out/.
RUN mkdir -p /out

# ---------------- nvbandwidth ----------------
# NVIDIA's official PCIe / NVLink bandwidth benchmark — the canonical
# tool for measuring TB4-tunneled throughput on eGPU setups.
# CMAKE_CUDA_ARCHITECTURES set to the supported set so the build does
# not try to JIT-detect against a /dev/nvidia* that does not exist in
# the build sandbox.
RUN git clone --depth 1 -b ${NVBANDWIDTH_TAG} \
        https://github.com/NVIDIA/nvbandwidth.git /tmp/nvbandwidth \
    && cd /tmp/nvbandwidth \
    && cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90;100" \
    && cmake --build build -j"$(nproc)" \
    && install -m 0755 build/nvbandwidth /out/nvbandwidth

# ---------------- deviceQuery ----------------
# CUDA samples ship deviceQuery as source; build the single sample we
# need. Pinned to v13.0 to match the CUDA toolkit version.
RUN git clone --depth 1 -b ${CUDA_SAMPLES_TAG} \
        https://github.com/NVIDIA/cuda-samples.git /tmp/cuda-samples \
    && cd /tmp/cuda-samples/Samples/1_Utilities/deviceQuery \
    && cmake -B build -DCMAKE_CUDA_ARCHITECTURES="75;80;86;89;90;100" \
    && cmake --build build -j"$(nproc)" \
    && install -m 0755 build/deviceQuery /out/deviceQuery

# ============================================================================
# Stage 2: runtime
# ============================================================================
FROM nvidia/cuda:13.0.0-base-ubuntu24.04

# Runtime boost (program_options only — what nvbandwidth links against)
# and pciutils for lspci output in the suite report.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        libboost-program-options1.83.0 \
        pciutils \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/nvbandwidth /usr/local/bin/nvbandwidth
COPY --from=builder /out/deviceQuery /usr/local/bin/deviceQuery

# Capture the version metadata at image build time so `diag version`
# can report it without needing the upstream repos present at runtime.
ARG NVBANDWIDTH_TAG=v0.9
ARG CUDA_SAMPLES_TAG=v13.0
ENV NVBANDWIDTH_TAG=${NVBANDWIDTH_TAG} \
    CUDA_SAMPLES_TAG=${CUDA_SAMPLES_TAG} \
    DIAG_IMAGE_VERSION=1.0
RUN date -u +%Y-%m-%dT%H:%M:%SZ > /etc/diag-build-date

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/apnex/nvidia-driver-injector"
LABEL org.opencontainers.image.description="GPU bandwidth + capability diagnostic container (nvbandwidth, deviceQuery). Companion to nvidia-driver-injector; intentionally isolated from the load-bearing injector container so failure of one does not cascade to the other."
LABEL org.opencontainers.image.licenses="Apache-2.0"

ENTRYPOINT ["/entrypoint.sh"]
CMD ["help"]
