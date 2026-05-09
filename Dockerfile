# nvidia-driver-injector — Approach B (distro-neutral host bind-mount)
#
# Builds the patched NVIDIA open kernel module against the host's running
# kernel by mounting /lib/modules from the host at runtime. One image works
# on any distro that has kernel-devel installed on the host (which is true
# for most non-immutable Linux server distros).
#
# Image-build time:
#   - Fetches NVIDIA/open-gpu-kernel-modules at the pinned tag
#   - Vendors the project patches (29 patches, applied at runtime build)
#
# Runtime (per pod start):
#   1. Detect host kernel ($(uname -r) — pod sees host's kernel via /proc)
#   2. Apply patches against the upstream tree
#   3. Build modules against /lib/modules/$(uname -r)/build (host bind-mount)
#   4. Load modules into host kernel via insmod (host's /lib/modules
#      bind-mounted writable)
#   5. Run nvidia-modprobe -u -c 0 to materialise UVM device files
#   6. Sleep infinity as a "container of intent"
#
# See README.md for the run command + bind-mount requirements.

FROM debian:12-slim

# Pinned upstream tag — the patches were authored against this exact version.
# Bumping the tag requires re-validating the patches apply cleanly.
ARG NVIDIA_OPEN_TAG=595.71.05
ENV NVIDIA_OPEN_TAG=${NVIDIA_OPEN_TAG}

# Install build toolchain + kmod (modprobe/insmod) + curl + git for upstream fetch.
# No kernel-devel here — the host's /lib/modules/$(uname -r)/build is bind-mounted
# at runtime and provides the canonical kernel build dir.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        kmod \
        git \
        ca-certificates \
        curl \
        xz-utils \
        pciutils \
        nvidia-modprobe && \
    rm -rf /var/lib/apt/lists/*

# Fetch upstream NVIDIA open driver source at image-build time.
WORKDIR /src
RUN git clone --depth 1 -b ${NVIDIA_OPEN_TAG} \
        https://github.com/NVIDIA/open-gpu-kernel-modules.git \
        nvidia-open-gpu-kernel-modules

# Vendor project patches.
COPY patches/ /src/patches/

# Validate patches apply cleanly at image-build time (early failure beats
# discovering the problem on every pod start).
RUN cd /src/nvidia-open-gpu-kernel-modules && \
    for p in $(ls /src/patches/*.patch | sort); do \
        echo "checking $p"; \
        git apply --check "$p" || { echo "PATCH CHECK FAILED: $p"; exit 1; } ; \
        git apply "$p"; \
    done && \
    echo "all patches applied cleanly to ${NVIDIA_OPEN_TAG} source"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/apnex/nvidia-driver-injector"
LABEL org.opencontainers.image.description="Patched NVIDIA open kernel module (595.71.05-aorus.12) packaged as a kernel-injector container — Approach B (host /lib/modules bind-mount); distro-neutral."
LABEL org.opencontainers.image.licenses="GPL-2.0"

ENTRYPOINT ["/entrypoint.sh"]
