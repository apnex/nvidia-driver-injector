# nvidia-driver-injector

A containerised kernel-injector for a **patched build of the NVIDIA open kernel
module** (`595.71.05-aorus.14`) that mitigates the silent host-freeze bug at
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
— a Thunderbolt-attached Blackwell GPU (e.g. RTX 5090) hard-locking the host
under CUDA load. The patches add in-driver crash-safety, a PCIe-error recovery
state machine, and a Q-watchdog that detects the GPU falling off the bus.
Deployable via Docker on a single host or as a DaemonSet in Kubernetes.

**Status:** in production use. Tested on Fedora 43–44, kernels 6.19–7.0.
Single-image, distro-neutral approach — the image builds the module against the
host's own `/lib/modules/$(uname -r)/build`, so it works on any distro that has
kernel headers installed.

## What it does

A privileged container that runs these steps on each pod start:

1. **PCI gate** — verify the eGPU is enumerated; exit cleanly if not.
2. **driver_override clear** — if the host had a teardown applied (e.g.
   `aorus-5090-egpu`'s `remove.sh` sets a sentinel to block auto-bind), clear it
   so nvidia can bind when the module loads.
   Skipped when override is empty or already `nvidia`.
3. **BAR1 verify** — confirm BAR1 = 32 GiB; refuse to load if smaller (catches
   missing kernel cmdline tuning).
4. **Build** — compile the patched module against the host's running kernel
   using `/lib/modules/$(uname -r)/build` bind-mounted from the host.
5. **Load** — load the patched `nvidia.ko` + `nvidia-uvm.ko` into the host
   kernel via `modprobe`, so the production `modprobe.d` NVreg options apply.
6. **UVM device files** — `nvidia-modprobe -u -c 0` materialises
   `/dev/nvidia-uvm-tools`.

Then `sleep infinity` as a "container of intent" — exit triggers the pod restart
policy.

## Architecture

This container is **Layer 2 of three**.
A correctly-deployed system has:

- **Layer 1 — Host bring-up**
  (set once at install; must be in place before docker starts):
  kernel cmdline,
  bridge LnkCtl2 cap (Lever H17, runs `Before=docker.service`),
  modprobe.d production NVreg options
  (including `NVreg_TbEgpuRecoverEnable=1`),
  Vulkan/EGL/OpenCL ICD disable.
- **Layer 2 — Driver injector container** (this repo):
  builds patched `nvidia.ko` against host kernel-devel,
  loads it via `modprobe` so production modprobe.d options apply,
  fixes `/dev/nvidia*` permissions,
  runs `nvidia-smi -pm 1` to trigger full GPU bringup
  (GSP firmware load, PMU init, AORUS waterblock thermal subsystem)
  and enable the driver's persistence-mode flag.
- **Layer 3 — Workload container**
  (vLLM, OpenCode runtime, etc.):
  pure userspace, depends on `/dev/nvidia*` working.

Layer 1 setup is automated by `sudo ./scripts/apply.sh`
(refuses to install if `apnex/aorus-5090-egpu` artifacts are present —
the two are alternative geometries, not stackable);
`sudo ./scripts/remove.sh` reverses it.

See [`docs/architecture.md`](docs/architecture.md) for the full layered diagram,
component-ownership table,
install / uninstall / reboot-survival workflows,
and the gap-status table tracking the current implementation against the target.

> **`apnex/aorus-5090-egpu` is the frozen predecessor.**
> That repo solves the same bug with host systemd services instead of a
> container. It is no longer actively developed — this repo is the current
> path — but remains a valid non-containerised alternative.
> The two are alternative geometries: pick **one**, they are not meant to
> coexist on the same host.

## Component ownership

| Concern | Layer | Owner |
|---|---|---|
| Kernel cmdline (`iommu=off`, etc.) | 1 | `scripts/apply.sh` (auto-detects bridge BDF for `pci=resource_alignment`) |
| `/etc/modprobe.d/nvidia-driver-injector.conf` (blacklists + NVreg options including NVreg_TbEgpuRecoverEnable=1) | 1 | `scripts/apply.sh` |
| Lever H17 LnkCtl2 cap (`nvidia-driver-injector-bridge-link-cap.service`, ordered `Before=docker.service`) | 1 | `scripts/apply.sh` |
| `/etc/udev/rules.d/79-nvidia-driver-injector.rules` (`/dev/nvidia*` group) | 1 | `scripts/apply.sh` |
| `/etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules` (unbind HDMI audio function) | 1 | `scripts/apply.sh` |
| Vulkan/EGL/OpenCL ICD disable | 1 | `scripts/apply.sh` |
| `kernel-devel` for `$(uname -r)` | 1 | `scripts/apply.sh` (dnf or apt) |
| **Kernel module build + load** (`modprobe --ignore-install nvidia` against the patched .ko) | **2** | **this container's entrypoint** ✓ |
| **`nvidia-modprobe -u -c 0`** (UVM device files) | **2** | **this container's entrypoint** ✓ |
| `/dev/nvidia*` chown/chmod (belt-and-suspenders to udev rule) | 2 | this container's entrypoint ✓ |
| `NVreg_TbEgpuRecoverEnable=1` post-load verification | 2 | this container's entrypoint ✓ |
| **`nvidia-smi -pm 1`** (persistence + GPU thermal engagement) | **2** | **this container's entrypoint** ✓ |
| Workload `depends_on` healthcheck | 3 | TODO (Gap #6; documented in workload-side compose) |

## Prerequisites

The container needs three things in place on the host before it can build and
load a working driver. `sudo ./scripts/apply.sh` (Layer 1) sets all of them up
for you — this section documents what they are, and how to do them by hand if
you prefer.

### 1. Kernel cmdline tuning

The Aorus 5090 eGPU on Thunderbolt requires several boot parameters to bring the
GPU up reliably and size BAR1 to 32 GiB:

```bash
sudo grubby --update-kernel=ALL --args=\
"thunderbolt.host_reset=false \
 pci=resource_alignment=35@0000:03:00.0 \
 iommu=off intel_iommu=off \
 pcie_aspm.policy=performance \
 thunderbolt.clx=0 \
 pcie_port_pm=off"
sudo reboot
```

**Your PCI addresses will differ.** The examples here use this project's
reference hardware — GPU at `0000:04:00.0`, the bridge directly above it at
`0000:03:00.0`. Find yours with:

```bash
gpu_bdf=$(lspci -Dnn | awk '/NVIDIA.*(VGA|3D)/ {print $1; exit}')
bridge_bdf=$(basename "$(readlink -f /sys/bus/pci/devices/$gpu_bdf/..)")
echo "GPU $gpu_bdf  ·  bridge $bridge_bdf"
```

`scripts/apply.sh` auto-detects both — you only need this for a hand install.

### 2. kernel-devel matching the running kernel

The container builds the module against `/lib/modules/$(uname -r)/build`,
bind-mounted from the host — so the host needs that build tree present:

| Distro | Install command |
|---|---|
| Fedora / RHEL | `sudo dnf install kernel-devel-$(uname -r)` |
| Debian / Ubuntu | `sudo apt install linux-headers-$(uname -r)` |
| Arch | `sudo pacman -S linux-headers` |

Verify with `ls /lib/modules/$(uname -r)/build/Makefile` — the file should
exist.

### 3. udev rules + access group (optional, for non-root use)

Compute workloads typically run as a non-root user. This repo ships a udev rule
that permissions `/dev/nvidia*` for a `gpu` access group:

```bash
sudo groupadd -r gpu 2>/dev/null || true
sudo install -m 0644 \
  scripts/host-files/etc/udev/rules.d/79-nvidia-driver-injector.rules \
  /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo usermod -aG gpu "$USER"   # log out + back in for this to take effect
```

`scripts/apply.sh` installs this for you. If your workloads run as root, skip
this step.

## Quick start — single-host Docker

For the full step-by-step including Thunderbolt authorization,
host-side bring-up, and the post-install verification suite,
see [`docs/install-workflow.md`](docs/install-workflow.md).
The condensed version:

```bash
# 0. Connect AORUS over TB; verify boltctl shows authorized
boltctl list                          # status: authorized
# (if status: connected but NOT authorized → sudo boltctl authorize <uuid>)

# 1. Clone + Layer 1 host bring-up
sudo git clone https://github.com/apnex/nvidia-driver-injector \
    /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh        # idempotent; refuses on aorus-5090-egpu hosts

# 2. Reboot if apply.sh prompts (kernel cmdline change)
sudo reboot

# 3. Build + start the injector container (Layer 2)
docker compose build                  # ~3-5 min cold
docker compose up -d
docker compose logs -f                # watch the entrypoint
```

After successful load:

```bash
nvidia-smi -L                            # GPU 0: NVIDIA GeForce RTX 5090
cat /sys/module/nvidia/version           # 595.71.05-aorus.14
```

To stop:

```bash
docker compose down                      # stops container; module STAYS LOADED
                                         # (kernel modules outlive containers
                                         # by design — module state is host
                                         # state, not container state)
```

To gracefully unload the module (driver upgrade, node decommission, recovery
from a wedged module), use the explicit `uninstall` subcommand:

```bash
docker compose run --rm driver-injector uninstall
```

This is **not** triggered by `docker compose down` — that asymmetry is
deliberate.
The `uninstall` path:

- Refuses if any process holds `/dev/nvidia*` (fail loud rather than rmmod with
  active users).
- `rmmod nvidia_uvm` → `nvidia_drm` → `nvidia_modeset` → `nvidia` in dependency
  order.
- Verifies all modules gone before exiting.
- Exit 0 → host restored to pre-injector baseline; re-run `docker compose up` to
  reload.

## Driver upgrade (cutover)

When a new image tag (e.g. `aorus.<N+1>`) is built and you want to swap the
running module without rebooting, use this sequence. Each step has a
known-failure mode and stops the chain on non-zero exit. Validated against
`aorus.13` → `aorus.14` on 2026-05-24.

```bash
cd /root/nvidia-driver-injector

# 1. Build the new image
sudo docker build -t apnex/nvidia-driver-injector:595.71.05-aorus.<N+1> .

# 2. Graceful Layer 2 teardown — entrypoint's safe-path rmmod
sudo docker compose run --rm driver-injector uninstall

# 3. Stop + remove the long-running container + its network
sudo docker compose down

# 4. Bump compose tag
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N>|nvidia-driver-injector:595.71.05-aorus.<N+1>|' docker-compose.yml

# 5. Start the new container (entrypoint rebuilds + modprobes new modules)
sudo docker compose up -d

# 6. Wait for entrypoint to finish (build + modprobe takes ~30-60s on rebuild)
until lsmod | grep -q '^nvidia '; do sleep 5; done

# 7. Verify
sudo modinfo -F version nvidia                       # expect: 595.71.05-aorus.<N+1>
cat /sys/module/nvidia/refcnt                        # expect: 1 (just nvidia_uvm)
sudo scripts/status.sh                               # expect: 38/2/0 or better
```

**Pre-cutover checklist:**

- No active GPU consumers — `sudo fuser /dev/nvidia*` returns empty
  (vLLM / ollama / nvidia-persistenced will block the `uninstall`
  pre-flight; stop them first).
- Previous image still on disk for rollback — `docker images
  apnex/nvidia-driver-injector` shows both `aorus.<N>` and the new
  `aorus.<N+1>` tag.

**Rollback** (if step 7 fails or you need to revert):

```bash
sudo docker compose run --rm driver-injector uninstall
sudo docker compose down
sudo sed -i 's|nvidia-driver-injector:595.71.05-aorus.<N+1>|nvidia-driver-injector:595.71.05-aorus.<N>|' docker-compose.yml
sudo docker compose up -d
```

**Notes on what NOT to use here:**

- `scripts/remove.sh` reverses Layer 1 host config (modprobe.d / systemd /
  udev). Layer 1 doesn't change in a tag bump, so re-running it is
  unnecessary churn.
- `scripts/remove.sh --purge` implies `--revert-cmdline` and requires a
  reboot — too disruptive for a tag bump within the same geometry.
- Raw `modprobe -r nvidia_uvm nvidia` skips the `uninstall` subcommand's
  active-consumer check — works but loses the safety gate.

## Verifying the install

After `docker compose up -d`, let the build finish (1-2 min on first run, ~30s
on rebuild) then verify on the host:

```bash
# 1. Module loaded
grep -E "^nvidia " /proc/modules
# nvidia          16424960  1 nvidia_uvm, Live ...

# 2. Patched build (-aorus.<n> suffix is the project marker)
cat /sys/module/nvidia/version
# 595.71.05-aorus.14

# 3. GPU bound to nvidia
ls -la /sys/bus/pci/devices/0000:04:00.0/driver
# .../bus/pci/drivers/nvidia

# 4. In-driver levers compiled in (recovery state machine + Q-watchdog)
ls /sys/module/nvidia/parameters/ | grep TbEgpu
ls /sys/bus/pci/devices/0000:04:00.0/ | grep tb_egpu_
ps -ef | grep -E "\[tb-egpu-qwd-" | grep -v grep
# the qwatchdog kthread should be present, e.g. [tb-egpu-qwd-0400]

# 5. nvidia-smi reports the GPU
nvidia-smi -L
# GPU 0: NVIDIA GeForce RTX 5090 (UUID: GPU-...)
nvidia-smi --query-gpu=name,driver_version,pcie.link.gen.current,pcie.link.width.current,memory.total --format=csv
# NVIDIA GeForce RTX 5090, 595.71.05, 3, 4, 32607 MiB
```

If all five pass, the patched module is loaded and bound, and the in-driver
recovery state machine plus Q-watchdog (Mode B detection) are armed.

## Quick start — Kubernetes

```bash
kubectl label node <gpu-node> apnex.com.au/aorus-egpu=true
kubectl apply -f k8s/daemonset.yaml
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector -f
```

See [`k8s/README.md`](k8s/README.md) for full k8s notes including:

- Adjacent deployments (NVIDIA Device Plugin, Container Toolkit)
- Node prerequisites
- Cleanup procedure

## Image variants

Build the image locally with `docker compose build` — no pre-built image is
published yet.
The image works on any Linux distro that has `kernel-devel` / `linux-headers`
installed (Ubuntu, Fedora, RHEL family, Debian).
For container-optimised OSes that lack `kernel-devel` (Talos, Bottlerocket,
CoreOS), a multi-image precompiled-per-kernel variant would be a future
addition.

## Companion: `diag/` (GPU bandwidth + capability diagnostics)

A separate diagnostic container lives at [`diag/`](diag/) — bundles
[`nvbandwidth`](https://github.com/NVIDIA/nvbandwidth) (the canonical
PCIe / TB4 bandwidth benchmark) and `deviceQuery` (GPU capability
report). Intentionally **isolated** from this injector container so the
diagnostic toolchain's much larger CUDA-devel surface (boost-devel +
nvcc + cuda-samples) does not bloat the load-bearing module-injection
image, and a diag-container failure cannot cascade to the live nvidia.ko
on the host. Same repo, same `docker compose` UX, **independent semver**
(`apnex/nvidia-driver-diag:1.0`).

```bash
# Build (one-off)
sudo docker compose -f diag/docker-compose.yml build

# Canonical baseline — H2D + D2H + H2D-bidirectional + deviceQuery
sudo docker compose -f diag/docker-compose.yml run --rm diag suite
```

See [`diag/README.md`](diag/README.md) for the full subcommand set and
the inaugural baseline reading at
[`diag/baseline-2026-05-24-aorus.14.txt`](diag/baseline-2026-05-24-aorus.14.txt)
(H2D = 2.84 GB/s, D2H = 3.29 GB/s — TB4-saturated, matches expectation).

## Troubleshooting

### `NVRM: probe routine was not called for 1 device(s)`

Container exits with `insmod nvidia.ko failed` and dmesg shows:

```
NVRM: The NVIDIA probe routine was not called for 1 device(s).
NVRM: No NVIDIA devices probed.
```

**Cause:** `driver_override` is set on the GPU's PCI device, which blocks
auto-bind even when `nvidia.ko`'s `pci_register_driver` runs at insmod time.
A teardown script — this repo's `scripts/remove.sh`, or a prior
`aorus-5090-egpu` install — deliberately sets `driver_override` to gate
auto-bind while the host stack is uninstalled.

**Fix:** the entrypoint clears any non-`nvidia` override automatically since
commit `fe2dcc5` — upgrade your image.
For older images, clear it manually:

```bash
echo > /sys/bus/pci/devices/0000:04:00.0/driver_override
docker compose restart
```

### `BAR1 too small`

Container exits at step 3 with:

```
[nvidia-driver-injector] FAIL: BAR1 too small: <N> bytes
                                (need ≥ 34359738368 = 32 GiB).
```

**Cause:** kernel cmdline missing `thunderbolt.host_reset=false` or
`pci=resource_alignment=35@<bridge_bdf>`, so the kernel allocated a smaller BAR1
at boot.

**Fix:** apply the cmdline tuning from
[Prerequisites](#1-kernel-cmdline-tuning), reboot.
BAR1 sizing happens once at boot and cannot be resized at runtime on TB-tunneled
hardware.

### `gcc: error: unrecognized command-line option '-fmin-function-alignment=16'`

Build fails with this gcc error during module compile.

**Cause:** the container's gcc is older than the gcc the host kernel was built
with (e.g. host kernel built with gcc 13+ but container ships gcc 12).

**Fix:** the upstream image runs on `debian:13-slim` (gcc 14.2), which is
sufficient for kernels built with gcc 13/14/15.
If you've forked the Dockerfile onto an older base, upgrade to `debian:13-slim`
or newer.

### `objtool: error while loading shared libraries: libelf.so.1`

Build fails when the kernel's prebuilt `objtool` (at
`/usr/src/kernels/<kver>/tools/objtool/objtool`) runs and can't find libelf.

**Cause:** the container is missing the runtime library that the host's
`objtool` was linked against.

**Fix:** the upstream image installs `libelf1t64` and `libssl3t64`.
If you've forked the Dockerfile and dropped them, re-add them.

### `insmod: ERROR: ... -1 Operation not permitted`

**Cause:** Secure Boot is enabled and module signing enforcement is rejecting
the unsigned container-built module.

**Fix:** disable Secure Boot in firmware, or sign the module post-build with a
MOK enrolled key (open follow-up — the injector's build path doesn't sign yet).

### Container exits cleanly with "no GPU matching ... found on PCI"

**Cause:** the eGPU isn't enumerated on the PCI bus — either the Thunderbolt
cable is disconnected, the eGPU is powered off, or the host hasn't completed
Thunderbolt authorisation (`boltctl list` should show it).

**Fix:** plug in / power on / authorise the eGPU, then `docker compose up -d`
again.
The container is designed to exit cleanly here so it can be left as a `restart:
unless-stopped` workload that picks up the GPU when it appears.

## Build inputs

| Input | Source | When |
|---|---|---|
| NVIDIA upstream | https://github.com/NVIDIA/open-gpu-kernel-modules tag `595.71.05` | Fetched at image-build time via `git clone --depth 1` |
| Project patches | Vendored at `patches/` (7 clusters; legacy series kept under `patches/legacy/`) | Image-build time |
| Host kernel + headers | `/lib/modules/$(uname -r)/build` on the host | Bind-mounted at runtime |

The `Dockerfile` validates that all 7 patches apply cleanly to the upstream tag
at image-build time — patch drift fails the image build, not the pod start.

## Why this exists

NVIDIA's open kernel module, unmodified, commits a Thunderbolt-attached
Blackwell GPU to a permanent lost state on a single transient PCIe read — and
the resulting failure cascade hard-locks the host. This is the bug tracked at
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979),
reproduced by multiple people on RTX 5080 / 5090 / RTX PRO 6000 eGPUs. The
patched build here (7 clusters — crash-safety, a PCIe-error recovery state
machine, a bus-loss watchdog, AER tuning) mitigates it.

Shipping the patched driver as a container makes the driver lifecycle
declarative: the image builds + loads the module against whatever kernel the
host is running, so a kernel upgrade doesn't mean a hand rebuild.

The pattern (privileged container builds + loads a kernel module) is the same
one NVIDIA's own [GPU Operator](https://github.com/NVIDIA/gpu-operator) Driver
DaemonSet uses.

The earlier `apnex/aorus-5090-egpu` repo solved the same bug with host systemd
services instead of a container; it is now frozen. This repo is the current
path.

## License

GPL-2.0 (matches the NVIDIA open driver's GPL-2.0 leg of its dual MIT/GPL-2.0
license).
