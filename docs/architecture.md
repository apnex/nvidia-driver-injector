# nvidia-driver-injector — architecture

> **Status:** current as of 2026-05-12.
> Most target-architecture gaps have been closed (see "Gaps vs the target architecture" at the end).
> Layer 1 surface: 1 systemd service + 1 modprobe.d + 2 udev rules + kernel cmdline + ICD disable.
> Layer 2: 1 container (`nvidia-driver-injector`), folds GPU engagement into its entrypoint.
> Layer 3: workload (vLLM / OpenCode / etc.), independent compose stack.

## TL;DR

The injector container is **one of three layers**, not the whole
deployment.
A correctly-deployed system on this hardware has:

- **Layer 1 — Host bring-up.**
  Set once at install time;
  must be in place before docker starts.
  Owns kernel cmdline,
  the H17 bridge LnkCtl2 cap (must run before nvidia binds),
  modprobe.d production options,
  and the Vulkan/EGL/OpenCL loader disable.
- **Layer 2 — Driver injector container.**
  This repo.
  Builds the patched `nvidia.ko` against host kernel-devel,
  loads it via `modprobe` so production modprobe.d options apply,
  fixes `/dev/nvidia*` permissions,
  runs `nvidia-smi -pm 1` to engage GPU
  (GSP load, PMU init, AORUS waterblock thermal subsystem)
  and set the driver's persistence-mode flag.
- **Layer 3 — Workload container.**
  vLLM, OpenCode, Triton, …
  Pure userspace, depends on `/dev/nvidia*` working.

**This is a different geometry from the
[`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu)
repo.**
That repo deploys the same patched driver via host systemd services
(no container).
You pick **one** of the two deployment patterns —
they are NOT meant to coexist on the same host.

## The architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 3: Workload (vLLM, OpenCode, …)                           │
│   Container, OpenAI-compat API, restart: unless-stopped         │
│   - Pure userspace, depends on /dev/nvidia* working             │
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Layer 2: Driver injector container       ← this repo            │
│   - Builds patched nvidia.ko vs host kernel-devel               │
│   - Loads via `modprobe` so /etc/modprobe.d wins                │
│   - Sets /dev/nvidia* permissions (chown gpu, chmod 660)     │
│   - `nvidia-smi -pm 1` → GSP load + PMU init + thermal engage   │
│   - Idempotent on already-loaded; explicit `uninstall` subcmd   │
│   - sleep infinity                                              │
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Layer 1: Host bring-up (immutable, set once at install)         │
│   - Kernel cmdline (grubby):                                    │
│       iommu=off, intel_iommu=off,                               │
│       thunderbolt.host_reset=false,                             │
│       pci=resource_alignment=35@<bridge_bdf>,                   │
│       pcie_aspm.policy=performance, thunderbolt.clx=0,          │
│       pcie_port_pm=off                                          │
│   - kernel-devel matching running kernel                        │
│   - /etc/modprobe.d/nvidia-driver-injector.conf:                │
│       options nvidia NVreg_TbEgpuRecoverEnable=1                │
│       options nvidia NVreg_DeviceFileMode=0660                  │
│       blacklist nouveau                                         │
│       install nvidia-drm /bin/false   ← GNOME-freeze guard      │
│   - bridge-link-cap.service (Before=docker.service):            │
│       caps bridge LnkCtl2 max-target-speed to Gen1 at boot      │
│   - Vulkan/EGL/OpenCL loader disable (rename → .disabled)       │
│   - udev: 79-...rules (/dev/nvidia* group perms) +              │
│     80-...rules (HDMI audio function unbind, compute-only)      │
└─────────────────────────────────────────────────────────────────┘
┌─────────────────────────────────────────────────────────────────┐
│ Layer 0: Hardware + firmware                                    │
│   AORUS RTX 5090 over TB4, NUC 15 Pro+, BIOS settings           │
└─────────────────────────────────────────────────────────────────┘
```

## Why this layering

**Some things have to run before the docker daemon starts.**
A container can't reach back in time.
Specifically:

- **Bridge LnkCtl2 cap (Lever H17).**
  When nvidia.ko first probes the GPU,
  the link state at that moment determines whether GSP boots cleanly.
  If the link came up at Gen3, the documented
  [host-freeze bug](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/979)
  fires.
  The cap must be applied to bridge config space
  **before** nvidia.ko binds.
  That means a systemd service ordered
  `Before=docker.service`, in Layer 1.
- **modprobe.d blacklist of stock nvidia.**
  If the system ever has
  `kmod-nvidia` / `akmod-nvidia` installed
  or anything else triggers `modprobe nvidia`,
  the stock driver loads and binds first —
  the patched module from the container then can't bind.
  The blacklist in Layer 1 prevents the race entirely.

Everything else can be containerised.

## Component ownership

| Concern | Owner | Reasoning |
|---|---|---|
| Kernel cmdline | Layer 1 (grubby) | Can't change at runtime |
| kernel-devel | Layer 1 (dnf/apt) | Container needs to build against it |
| modprobe.d production NVreg options | Layer 1 (file install) | `modprobe` reads `/etc/modprobe.d/`; container honours it via bind-mount |
| nvidia-drm autoload guard | Layer 1 (`install /bin/false`) | Compute-only posture; GNOME-freeze guard |
| nouveau blacklist | Layer 1 | Same reason |
| Bridge LnkCtl2 cap (H17) | Layer 1 (systemd service) | Must run `Before=docker.service` |
| Vulkan/EGL/OpenCL ICD disable | Layer 1 (one-shot rename) | Compute-only posture is permanent; lives in `/usr/share/vulkan/icd.d/` etc. |
| udev rules for `/dev/nvidia*` group + HDMI audio unbind | Layer 1 | Owned by host udev (79-...rules + 80-...rules) |
| **nvidia.ko build + load** | **Layer 2 (this container)** | The whole point of the injector |
| **`/dev/nvidia*` perms post-load** | **Layer 2** | Trivial chmod after modprobe |
| **`nvidia-smi -pm 1`** | **Layer 2** | Engages GPU (GSP / PMU / thermal subsystem) + sets driver persistence flag. Daemon-less successor to `nvidia-persistenced`. |
| **Module unload (uninstall)** | **Layer 2** | Explicit `uninstall` subcommand — never auto on container exit |
| Workload (vLLM etc.) | Layer 3 | Independent restart policy |

## Workflows

### Install (fresh host)

```bash
# Layer 1 — host setup (one-time, idempotent)
git clone https://github.com/apnex/nvidia-driver-injector /root/nvidia-driver-injector
cd /root/nvidia-driver-injector
sudo ./scripts/apply.sh           # use --no-act first to dry-run
  # Refuses if apnex/aorus-5090-egpu artifacts are detected
  # (override with --force-coexist; not recommended).
  # Does:
  #   - grubby --update-kernel cmdline edits (iommu=off, host_reset=false,
  #     pci=resource_alignment=35@<auto-detected bridge bdf>, etc.)
  #   - dnf/apt install kernel-devel-$(uname -r) if missing
  #   - install /etc/modprobe.d/nvidia-driver-injector.conf with production
  #     NVreg options (LeverMRecoverEnable=1, DeviceFileMode=0660, ...)
  #   - install + enable nvidia-driver-injector-bridge-link-cap.service
  #     ordered Before=docker.service
  #   - install /etc/udev/rules.d/79-nvidia-driver-injector.rules
  #     (/dev/nvidia* group perms)
  #   - install /etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules
  #     (unbind eGPU HDMI audio function — compute-only posture)
  #   - rename Vulkan/EGL/OpenCL ICDs to .nvidia-driver-injector-disabled
  #   - prompt for reboot if cmdline changed

# Layer 2 — driver injector container (persistent)
docker compose up -d

# Layer 3 — workload (this lives in your workload repo, e.g. /root/vllm)
cd /root/vllm && docker compose up -d
```

### Uninstall (full teardown)

```bash
# Layer 3 → Layer 2 → Layer 1, in reverse order
cd /root/vllm && docker compose down

cd /root/nvidia-driver-injector
docker compose run --rm driver-injector uninstall   # rmmod nvidia*
docker compose down

sudo ./scripts/remove.sh
  # Reverses apply.sh idempotently. Removes:
  #   - bridge-link-cap.service + binary
  #   - /etc/modprobe.d/nvidia-driver-injector.conf
  #   - /etc/udev/rules.d/79-nvidia-driver-injector.rules
  #   - /etc/udev/rules.d/80-nvidia-driver-injector-disable-audio.rules
  #   - re-enables Vulkan/EGL/OpenCL ICDs
  #   - legacy: cleans up any pre-fold gpu-engage host artifacts
  # Does NOT revert kernel cmdline by default
  # (use --revert-cmdline if desired; reboot needed after).
  # Leaves the gpu UNIX group + kernel-devel package alone
  # (may be in use by other things on the host).
```

### Reboot survival

The load-bearing case.
What we want to happen on every reboot:

```
boot
 ├─ kernel reads cmdline (Layer 1)
 │     iommu=off, host_reset=false, etc.
 ├─ early-boot udev applies device perms (Layer 1)
 ├─ modprobe.d blacklist holds nvidia (Layer 1)
 │     stock nvidia won't auto-load
 ├─ nvidia-driver-injector-bridge-link-cap.service (Layer 1)
 │     ordered Before=docker.service
 │     caps bridge LnkCtl2 max-target=Gen3 + bit 5 (H17)
 ├─ udev rules fire (Layer 1)
 │     79-...rules → /dev/nvidia* perms when devices appear
 │     80-...rules → unbinds HDMI audio function on PCI enumerate
 ├─ docker.service starts
 │   ├─ driver-injector container (restart: unless-stopped)
 │   │   ├─ build nvidia.ko (cached if kernel unchanged)
 │   │   ├─ modprobe nvidia
 │   │   │     reads /etc/modprobe.d/ →
 │   │   │     RecoverEnable=1, DeviceFileMode=0660, …
 │   │   ├─ nvidia-modprobe -u -c 0 (uvm device nodes)
 │   │   ├─ chown /dev/nvidia* root:gpu && chmod 0660
 │   │   ├─ nvidia-smi -pm 1  →  GSP load, PMU init, thermal engage
 │   │   └─ sleep infinity
 │   └─ workload container (restart: unless-stopped)
 │         depends_on driver-injector healthy
 └─ ready for user workload
```

If something fails mid-boot:

- **Mode B wedge during GSP boot** →
  AER fires →
  in-driver `pcie_err_handlers` engaged
  (because RecoverEnable=1 was set by modprobe.d) →
  bus reset →
  re-init → success or clean DISCONNECT.
- **Driver injector fails** →
  container restarts;
  workload container's `depends_on` keeps it from starting prematurely.
- **Workload fails** →
  restarts;
  nothing else affected.

The `depends_on: { driver-injector: { condition: service_healthy } }`
relationship is what couples workload-restart to driver-ready.

## Gaps vs the target architecture

Surfaced 2026-05-10 after a reboot incident
(boot landed on Mode B silent wedge — see commit history for details).

| # | Gap | Effect | Status |
|---|---|---|---|
| 1 | Container uses `insmod nvidia.ko` directly, bypassing `/etc/modprobe.d/` | Production NVreg options not applied (e.g. `RecoverEnable=0` instead of `1`) — recovery state machine doesn't fire on AER | **CLOSED** — entrypoint switched to `modprobe --ignore-install nvidia` with `/etc/modprobe.d` bind-mounted from host. Falls back to insmod if mount missing. Verifies `NVreg_TbEgpuRecoverEnable=1` post-load and warns if not. |
| 2 | No host-side install script | Operator has to manually do Layer 1 setup | **CLOSED** — `scripts/apply.sh` + `scripts/remove.sh` shipped. |
| 3 | No bridge-link-cap.service shipped with this repo | Must rely on a separate apply.sh from aorus-5090-egpu, OR live link comes up at whatever speed it happens to | **CLOSED** — cleanroom `nvidia-driver-injector-bridge-link-cap` binary + systemd unit shipped under `scripts/host-files/`, installed via Layer 1. |
| 4 | No `chown` / `chmod` of `/dev/nvidia*` post-load | Permissions are 0666 root:root (works but wide open) | **CLOSED** — entrypoint chgrps to `gpu` and chmods 0660 if the group exists on host. |
| 5 | No GPU engagement inside container — lazy state wastes 41 W idle | Cooler at floor RPM, GSP not loaded, idle power ~63 W vs ~22 W proper P8 (measured 2026-05-12 on this stack) | **CLOSED 2026-05-12** — Dockerfile extracts `nvidia-smi` + `libnvidia-ml.so` from NVIDIA's 595.71.05 tarball (+4 MB image); entrypoint runs `nvidia-smi -pm 1` after bind. Daemon-less successor to `nvidia-persistenced`. |
| 6 | HDMI audio function binds to `snd_hda_intel`, sits in D0 with no purpose | Continuous power draw + potential ASPM/PM perturbation on the eGPU PCI tree | **CLOSED 2026-05-12** — new udev rule `80-nvidia-driver-injector-disable-audio.rules` sets `driver_override="nvidia-driver-injector-disabled"` on the audio function (`10de:22e8`) and unbinds it. |
| 7 | No `depends_on` healthcheck linking workload → injector | Workload can crash-loop while injector still warming up | OPEN — to be documented in workload-side compose examples |
| 8 | `/dev/nvidia-uvm*` perm drift to 666 root:root | Wider-than-intended access (still constrained by ICD disable + gpu group on `/dev/nvidia0`) | OPEN — `nvidia-modprobe -u -c 0` mknod creates with default perms; udev rule fires too late. Worked-around by container's chmod/chgrp at startup. |

Gaps 1-6 closed; Gap 7 is the remaining workload-side polish;
Gap 8 is a perm-drift edge case worth chasing in a future session.

## Out-of-scope for this repo

Things that look related but live elsewhere:

- **Lever M-recover, Q-watchdog, H17 cap-as-quirk, close-path mitigations**
  — those are kernel-module patches.
  They live in `patches/` and ship as part of the image build.
  Their **defaults** are wrong without modprobe.d (gap #1 above);
  their **code** is correct.
- **Workload-side perf tuning** —
  see your workload repo
  (e.g. `docs/perf-hypothesis-ledger.md` in the vllm repo).
- **The non-container deployment** —
  see [`apnex/aorus-5090-egpu`](https://github.com/apnex/aorus-5090-egpu).
  Different geometry; same underlying patches.
