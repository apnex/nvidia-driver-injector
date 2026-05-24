# nvidia-driver-injector

A containerised kernel-injector for a **patched build of the NVIDIA open kernel
module** (`595.71.05-aorus.14`) that mitigates the silent host-freeze bug at
[NVIDIA/open-gpu-kernel-modules#979](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
— a Thunderbolt-attached Blackwell GPU (e.g. RTX 5090) hard-locking the host
under CUDA load. The patches add in-driver crash-safety, a PCIe-error recovery
state machine, and a bus-loss watchdog that detects the GPU falling off the
bus. Deployable via Docker on a single host or as a DaemonSet in Kubernetes.

**Status:** in production. Tested on Fedora 43–44, kernels 6.19–7.0.

## How it fits together

```
Layer 3  Workload  (vLLM / OpenCode / …)         — separate compose stack
Layer 2  Driver injector container               — this repo
Layer 1  Host config  (cmdline / modprobe.d / udev / bridge cap)
Layer 0  Hardware     (AORUS 5090 over TB, NUC 15 Pro+)
```

`scripts/apply.sh` (run once on the host) sets up Layer 1.
The container at this repo's root runs Layer 2: builds the patched
`nvidia.ko` against the host's `/lib/modules/$(uname -r)/build`, loads it via
`modprobe`, materialises `/dev/nvidia*`, and engages persistence mode.
Layer 3 is whatever consumes `/dev/nvidia*`.

Full layered design with component-ownership table:
[`docs/architecture.md`](docs/architecture.md).

> **`apnex/aorus-5090-egpu`** is the frozen predecessor — same patches,
> deployed via host systemd services instead of a container. Alternative
> geometries; pick one, do not stack.

## Install

```bash
sudo git clone https://github.com/apnex/nvidia-driver-injector /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh        # Layer 1; idempotent; reboot if it prompts
docker compose up -d           # Layer 2; build (~3-5 min cold) + load
```

Full step-by-step (Thunderbolt authorisation, what `apply.sh` does, flags,
migration from `aorus-5090-egpu`): [`docs/install-workflow.md`](docs/install-workflow.md).

## Use

The injector runs as `restart: unless-stopped` and outlives its own logs.
Day-to-day, you treat `/dev/nvidia*` as available and bring up your workload:

```bash
cd /path/to/your/workload      # e.g. /root/vllm
docker compose up -d
```

The injector logs are reference, not interactive:

```bash
docker compose logs -f driver-injector
```

`docker compose down` stops the container but **leaves the kernel module
loaded** — module state is host state. To gracefully unload (driver upgrade,
node decommission, wedged-module recovery), use the explicit `uninstall`
subcommand:

```bash
docker compose run --rm driver-injector uninstall
```

Driver upgrade (image tag bump) and rollback: see
[`docs/teardown-workflow.md`](docs/teardown-workflow.md) §Driver upgrade.

## Test

Three distinct things called "test":

| What | Doc | One-liner |
|---|---|---|
| **Verify install** | [`docs/install-workflow.md`](docs/install-workflow.md#step-6--verify) | Did the module load? Are the in-driver levers armed? |
| **Measure bandwidth + capability** | [`diag/README.md`](diag/README.md) | `sudo docker compose -f diag/docker-compose.yml run --rm diag suite` |
| **Repo gates (for contributors)** | [`docs/testing.md`](docs/testing.md) | `bash tests/run.sh` + `tools/validate-patchset.sh` |

The diag container is a **separate** image
(`apnex/nvidia-driver-diag:1.0`) with its own lifecycle — isolated by design
so its CUDA-devel surface cannot bloat or destabilise the injector.

## Remove

```bash
# Layer 3 first (workload), then Layer 2 (this container), then Layer 1 (host).
cd /path/to/your/workload && docker compose down

cd /root/nvidia-driver-injector
docker compose run --rm driver-injector uninstall   # rmmod nvidia*
docker compose down                                 # stop the container

sudo ./scripts/remove.sh                            # reverse Layer 1
# Add --revert-cmdline to strip kernel args; --purge for true blank-equivalent.
```

Full teardown reference (every flag, every file removed, what's left behind on
purpose): [`docs/teardown-workflow.md`](docs/teardown-workflow.md).

## Troubleshooting

### `NVRM: probe routine was not called for 1 device(s)`

`driver_override` on the GPU's PCI device is blocking auto-bind — typically
left over from a `scripts/remove.sh` run or an earlier `aorus-5090-egpu`
install. The entrypoint clears any non-`nvidia` override automatically since
commit `fe2dcc5`; upgrade your image, or manually:

```bash
echo > /sys/bus/pci/devices/0000:04:00.0/driver_override
docker compose restart
```

### `BAR1 too small`

The container exits at the BAR1-verify step with `BAR1 too small: <N> bytes
(need ≥ 34359738368 = 32 GiB)`. The kernel cmdline is missing
`thunderbolt.host_reset=false` or `pci=resource_alignment=35@<bridge_bdf>`.
BAR1 sizing happens once at boot and cannot be changed at runtime on
TB-tunneled hardware. Run `sudo ./scripts/apply.sh` and reboot.

### `gcc: error: unrecognized command-line option '-fmin-function-alignment=16'`

The container's gcc is older than the gcc the host kernel was built with.
The upstream image is on `debian:13-slim` (gcc 14.2) which covers
kernels built with gcc 13/14/15. If you forked onto an older base, bump it.

### `objtool: ... cannot open shared object file: libelf.so.1`

The container is missing `libelf1t64` / `libssl3t64` (used by the host
kernel's prebuilt `objtool`). The upstream image installs both; re-add them
if you stripped them in a fork.

### `insmod: ... Operation not permitted`

Secure Boot is rejecting the unsigned, container-built module. Disable
Secure Boot, or sign post-build with a MOK key (the injector's build path
does not sign — open follow-up).

### Container exits cleanly with `no GPU matching ... found on PCI`

The eGPU is not enumerated on the PCI bus. Check the TB cable, eGPU power,
and `boltctl list` for authorisation. The clean exit is by design — the
container is meant to be left as `restart: unless-stopped` and pick the
GPU up when it appears.

## Building the image

```bash
docker compose build           # ~3-5 min cold, ~30s with cached layers
```

No pre-built image is published yet. The image is distro-neutral — it
builds the module against the host's `/lib/modules/$(uname -r)/build`, so it
works on any Linux that has the matching `kernel-devel` / `linux-headers`
package installed. For container-optimised OSes without that package
(Talos, Bottlerocket, CoreOS), a multi-image precompiled-per-kernel variant
is a future addition.

Build inputs:

| Input | Source | When |
|---|---|---|
| NVIDIA upstream | github.com/NVIDIA/open-gpu-kernel-modules tag `595.71.05` | Image build (`git clone --depth 1`) |
| Project patches | `patches/base/` + `patches/addon/` (11 patches; `patches/legacy/` for provenance) | Image build (gated by `--check` and `make modules`) |
| Host kernel + headers | `/lib/modules/$(uname -r)/build` | Bind-mount at runtime |

Patch drift fails the image build, not the pod start.

## Kubernetes

```bash
kubectl label node <gpu-node> apnex.com.au/aorus-egpu=true
kubectl apply -f k8s/daemonset.yaml
kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-driver-injector -f
```

Full notes (node prerequisites, adjacent NVIDIA components, cleanup):
[`k8s/README.md`](k8s/README.md).

## Why this exists

NVIDIA's open kernel module, unmodified, commits a Thunderbolt-attached
Blackwell GPU to a permanent lost state on a single transient PCIe read —
and the resulting failure cascade hard-locks the host. The patched build
here mitigates it; the upstream-bound subset is being prepared as PRs (see
[`docs/upstream-plan.md`](docs/upstream-plan.md)).

Shipping the driver as a container makes its lifecycle declarative: the
image rebuilds + loads the module against whatever kernel the host is
running, so kernel upgrades don't mean a hand rebuild. Same pattern as
NVIDIA's [GPU Operator](https://github.com/NVIDIA/gpu-operator) driver
DaemonSet.

## License

GPL-2.0 (matches the NVIDIA open driver's GPL-2.0 leg of its dual MIT /
GPL-2.0 licence).
