# nvidia-driver-injector — Approach B (distro-neutral host bind-mount)
#
# Builds the patched NVIDIA open kernel module against the host's running
# kernel by mounting /lib/modules from the host at runtime. One image works
# on any distro that has kernel-devel installed on the host (which is true
# for most non-immutable Linux server distros).
#
# Image-build time:
#   - Fetches NVIDIA/open-gpu-kernel-modules at the pinned tag
#   - Vendors + applies the composed patch set (patches/base + manifest) —
#     patch drift fails the image build, not the pod start
#
# Runtime (per pod start):
#   1. Detect host kernel ($(uname -r) — pod sees host's kernel via /proc)
#   2. Build modules against /lib/modules/$(uname -r)/build (host bind-mount)
#   3. Load modules into the host kernel via modprobe (host's /lib/modules
#      bind-mounted writable)
#   4. Run nvidia-modprobe -u -c 0 to materialise UVM device files
#   5. Sleep infinity as a "container of intent"
#
# See README.md for the run command + bind-mount requirements.

FROM debian:13-slim

# Pinned upstream tag — the patches were authored against this exact version.
# Bumping the tag requires re-validating the patches apply cleanly.
ARG NVIDIA_OPEN_TAG=595.71.05
ENV NVIDIA_OPEN_TAG=${NVIDIA_OPEN_TAG}

# Install build toolchain + kmod (modprobe/insmod) + curl + git for upstream fetch.
# No kernel-devel here — the host's /lib/modules/$(uname -r)/build is bind-mounted
# at runtime and provides the canonical kernel build dir.
# nvidia-modprobe is NOT in Debian repos (only in NVIDIA's CUDA repo); we build
# from upstream below.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        build-essential \
        kmod \
        git \
        ca-certificates \
        curl \
        xz-utils \
        pciutils \
        m4 \
        libelf1t64 \
        libssl3t64 \
        psmisc && \
    rm -rf /var/lib/apt/lists/*

# kubectl — used by the entrypoint to write node labels in the k3s /
# Kubernetes deployment path (Path B in docs/install-workflow.md). Off by
# default outside a cluster (entrypoint checks KUBERNETES_SERVICE_HOST).
# Pinned to a recent stable that talks to k3s v1.32+ (Kubernetes 1.29+).
# Static binary, ~50 MB — rounding error vs the rest of the image.
ARG KUBECTL_VERSION=v1.32.2
RUN curl -fsSL -o /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/$(dpkg --print-architecture)/kubectl" && \
    chmod +x /usr/local/bin/kubectl && \
    /usr/local/bin/kubectl version --client=true >/dev/null

# Build nvidia-modprobe from upstream — small C program (~200 LoC), GPL-2.0,
# pinned to the same tag as the kernel module. Used at runtime to materialise
# /dev/nvidia-uvm-tools after module load.
RUN git clone --depth 1 -b ${NVIDIA_OPEN_TAG} \
        https://github.com/NVIDIA/nvidia-modprobe.git /tmp/nvidia-modprobe && \
    cd /tmp/nvidia-modprobe && \
    make -j"$(nproc)" && \
    install -m 4755 _out/Linux_$(uname -m)/nvidia-modprobe /usr/bin/nvidia-modprobe && \
    cd / && rm -rf /tmp/nvidia-modprobe

# Extract nvidia-smi + libnvidia-ml.so from NVIDIA's proprietary 595.71.05
# tarball. We use the OPEN kernel modules (above) but the userspace tools
# (nvidia-smi, NVML library) are closed-source and come from the .run bundle.
# NVIDIA's official position is that the open kernel modules use the same
# userspace tools as the proprietary build — they share the NVML interface.
#
# Why we need nvidia-smi: the entrypoint calls `nvidia-smi -pm 1` once after
# binding nvidia.ko, which sets the driver's persistence-mode flag. Without
# this, the GPU stays in lazy-init state (~63 W idle vs ~22 W proper P8;
# cooler at floor RPM). Measured 2026-05-12.
#
# We ship the version-matched binary so there is no NVML interface skew
# between the userspace tool and the in-kernel driver.
#
# We ALSO carry the GSP firmware blobs (gsp_ga10x.bin + gsp_tu10x.bin) from
# the same .run into /opt/nvidia-firmware/. The kernel's request_firmware()
# reads GSP firmware from the *host* /lib/firmware at device init — so unlike
# nvidia-smi/libnvidia-ml (which stay in the container), the firmware must
# physically reach the host. If the host ever loses it (e.g. an nvidia RPM
# that owned /lib/firmware/nvidia is removed — see the 2026-05-22
# nvidia-kmod-common incident), the entrypoint re-supplies it from this
# baked-in copy. The image is then the single durable source for the
# patched .ko, nvidia-smi, libnvidia-ml AND GSP firmware.
#
# Strip out everything we don't need (kernel module source, libcuda, GL
# libraries, etc.) — nvidia-smi+NVML add ~5-10 MB, GSP firmware ~103 MB.
RUN curl -fsSL -o /tmp/nvidia.run \
        https://us.download.nvidia.com/XFree86/Linux-x86_64/${NVIDIA_OPEN_TAG}/NVIDIA-Linux-x86_64-${NVIDIA_OPEN_TAG}.run && \
    chmod +x /tmp/nvidia.run && \
    /tmp/nvidia.run --extract-only --target /tmp/nv-extract && \
    install -m 0755 /tmp/nv-extract/nvidia-smi /usr/bin/nvidia-smi && \
    install -m 0644 /tmp/nv-extract/libnvidia-ml.so.${NVIDIA_OPEN_TAG} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_OPEN_TAG} && \
    ln -sf libnvidia-ml.so.${NVIDIA_OPEN_TAG} /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 && \
    ldconfig && \
    install -d /opt/nvidia-firmware && \
    install -m 0644 /tmp/nv-extract/firmware/gsp_ga10x.bin \
                    /tmp/nv-extract/firmware/gsp_tu10x.bin \
                    /opt/nvidia-firmware/ && \
    rm -rf /tmp/nvidia.run /tmp/nv-extract

# Fetch upstream NVIDIA open driver source at image-build time.
WORKDIR /src
RUN git clone --depth 1 -b ${NVIDIA_OPEN_TAG} \
        https://github.com/NVIDIA/open-gpu-kernel-modules.git \
        nvidia-open-gpu-kernel-modules

# Vendor project patches + the composition tools.
COPY patches/ /src/patches/
COPY tools/   /src/tools/

# Compose and apply the patch set at image-build time. compose-patchset.sh
# verifies patches/ against patches/manifest and emits the ordered apply
# list; drift fails the image build, not the pod start.
RUN cd /src/nvidia-open-gpu-kernel-modules && \
    /src/tools/compose-patchset.sh --patches-dir /src/patches > /tmp/apply-list && \
    while read -r p; do \
        [ -n "$p" ] || continue; \
        echo "applying ${p##*/}"; \
        git apply --check "$p" && git apply "$p" || { echo "FAILED to apply $p (upstream-tag drift? run tools/regen-base-patches.sh)" >&2; exit 1; }; \
    done < /tmp/apply-list && \
    echo "composed patch set applied cleanly to ${NVIDIA_OPEN_TAG} source" && \
    rm -f /tmp/apply-list

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

LABEL org.opencontainers.image.source="https://github.com/apnex/nvidia-driver-injector"
LABEL org.opencontainers.image.description="Patched NVIDIA open kernel module packaged as a kernel-injector container — Approach B (host /lib/modules bind-mount); distro-neutral. Module version is read from upstream version.mk at build time (see kernel-open/Kbuild)."
LABEL org.opencontainers.image.licenses="GPL-2.0"

ENTRYPOINT ["/entrypoint.sh"]
