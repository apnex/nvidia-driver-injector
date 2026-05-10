# nvidia-driver-injector — target architecture

> **Status:** design doc, 2026-05-10.
> Captures the layering the project is moving toward.
> Current code (entrypoint.sh as of this commit) **does not yet match
> all of this** — see "Gaps the current implementation has" at the end.

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
  optionally runs `nvidia-persistenced`.
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
│   - Sets /dev/nvidia* permissions (chown ollama, chmod 660)     │
│   - Runs nvidia-persistenced (optional, warmup-latency)         │
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
│       options nvidia NVreg_TbEgpuLeverMRecoverEnable=1          │
│       options nvidia NVreg_DeviceFileMode=0660                  │
│       blacklist nouveau                                         │
│       install nvidia-drm /bin/false   ← GNOME-freeze guard      │
│   - bridge-link-cap.service (Before=docker.service):            │
│       caps bridge LnkCtl2 max-target-speed to Gen1 at boot      │
│   - Vulkan/EGL/OpenCL loader disable (rename → .disabled)       │
│   - udev rule for /dev/nvidia* group                            │
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
| udev rule for `/dev/nvidia*` group | Layer 1 | Owned by host udev |
| **nvidia.ko build + load** | **Layer 2 (this container)** | The whole point of the injector |
| **`/dev/nvidia*` perms post-load** | **Layer 2** | Trivial chmod after modprobe |
| **`nvidia-persistenced`** | **Layer 2 (optional)** | Can run inside the injector pod |
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
  #   - re-enables Vulkan/EGL/OpenCL ICDs
  # Does NOT revert kernel cmdline by default
  # (use --revert-cmdline if desired; reboot needed after).
  # Leaves the ollama UNIX group + kernel-devel package alone
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
 ├─ aorus-egpu-bridge-link-cap.service (Layer 1)
 │     ordered Before=docker.service
 │     caps bridge LnkCtl2 max-target=Gen1
 ├─ docker.service starts
 │   ├─ driver-injector container (restart: unless-stopped)
 │   │   ├─ build nvidia.ko (cached if kernel unchanged)
 │   │   ├─ modprobe nvidia
 │   │   │     reads /etc/modprobe.d/ →
 │   │   │     RecoverEnable=1, DeviceFileMode=0660, …
 │   │   ├─ chown /dev/nvidia* root:ollama && chmod 0660
 │   │   ├─ start nvidia-persistenced (optional)
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
| 1 | Container uses `insmod nvidia.ko` directly, bypassing `/etc/modprobe.d/` | Production NVreg options not applied (e.g. `RecoverEnable=0` instead of `1`) — Lever M-recover doesn't fire on AER | **CLOSED** — entrypoint switched to `modprobe --ignore-install nvidia` with `/etc/modprobe.d` bind-mounted from host. Falls back to insmod if mount missing. Verifies `NVreg_TbEgpuLeverMRecoverEnable=1` post-load and warns if not. |
| 2 | No host-side install script | Operator has to manually do Layer 1 setup | **CLOSED** — `scripts/apply.sh` + `scripts/remove.sh` shipped. |
| 3 | No bridge-link-cap.service shipped with this repo | Must rely on a separate apply.sh from aorus-5090-egpu, OR live link comes up at whatever speed it happens to | **CLOSED** — cleanroom `nvidia-driver-injector-bridge-link-cap` binary + systemd unit shipped under `scripts/host-files/`, installed via Layer 1. |
| 4 | No `chown` / `chmod` of `/dev/nvidia*` post-load | Permissions are 0666 root:root (works but wide open) | **CLOSED** — entrypoint chgrps to `ollama` and chmods 0660 if the group exists on host. |
| 5 | No nvidia-persistenced inside container | Warmup-latency optimization not active | OPEN (low priority — close-path bug class already mitigated) |
| 6 | No `depends_on` healthcheck linking workload → injector | Workload can crash-loop while injector still warming up | OPEN — to be documented in workload-side compose examples |

Gaps 1-4 closed in commits leading up to and including the
"hardened install/remove workflow" series.
Gaps 5-6 are lower-priority follow-ups.

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
