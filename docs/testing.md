# Testing

Three different things in this project are called "test". They serve
different audiences and do not overlap.

| Test type | Audience | When | One-liner |
|---|---|---|---|
| **1. Verify install** | Operator, after install or boot | "Did the module actually load with the levers armed?" | See [install-workflow.md §Verify](install-workflow.md#step-5--verify) |
| **2. Measure bandwidth + capability** | Operator, baseline / regression | "Is TB4 throughput where it should be? Did anything regress?" | `sudo docker compose -f diag/docker-compose.yml run --rm diag suite` |
| **3. Repo gates** | Contributor, before commit / PR | "Do the manifest + intent + patches still all line up?" | `bash tests/run.sh` + `tools/validate-patchset.sh` |

## 1. Verify the install

Owned by [`install-workflow.md`](install-workflow.md#step-5--verify) — see
that doc for the canonical spot checks plus the comprehensive 40-check
run via `sudo ./scripts/status.sh` (expect `38/2/0` on Path A or
`37/2/0` on Path B — the Path-A-only "docker-compose container running"
check naturally drops out under Path B).

The two standing WARNs (`/dev/nvidia-uvm` perm drift; one detection edge
case) are documented; anything else is real.

## 2. Diag container — bandwidth + capability

A separate companion image (`apnex/nvidia-driver-diag:1.0`), built and run
from its own compose file under [`diag/`](../diag/). Isolated by design so
its much larger CUDA-devel surface (boost-devel + nvcc + cuda-samples)
cannot bloat or destabilise the injector image, and a diag-container
failure cannot cascade to the live `nvidia.ko` on the host.

```bash
cd /root/nvidia-driver-injector

# Build the diag image (one-off, ~3-5 min).
sudo docker compose -f diag/docker-compose.yml build

# Canonical baseline — H2D + D2H + H2D-bidirectional + deviceQuery.
sudo docker compose -f diag/docker-compose.yml run --rm diag suite

# Capture to file for regression tracking.
sudo docker compose -f diag/docker-compose.yml run --rm diag suite \
    > diag/baseline-$(date +%F)-$(cat /sys/module/nvidia/version).txt

# Bundled tool versions + image build date.
sudo docker compose -f diag/docker-compose.yml run --rm diag version
```

On reference hardware (NUC 15 Pro+ + AORUS 5090 over TB4) expect `H2D ≈
2.84 GB/s`, `D2H ≈ 3.29 GB/s` — TB4-saturated. Inaugural baseline kept at
[`diag/baseline-2026-05-24-aorus.14.txt`](../diag/baseline-2026-05-24-aorus.14.txt).

Full subcommand set and the "Adding a future tool" pattern:
[`diag/README.md`](../diag/README.md).

The diag container is **not** a soak monitor (the injector handles that
itself: bus-loss-watchdog kthread + recovery counters under
`/sys/bus/pci/devices/<gpu>/tb_egpu_*`) and **not** a model-perf rig
(that lives in a separate vLLM-side repo per project scope).

## 3. Repo gates (contributor)

Lightweight Bash test harness for the manifest + intent + patch-rendering
machinery. Run from the repo root:

```bash
bash tests/run.sh
```

The three test files (`tests/test-compose.sh`, `tests/test-intent-lint.sh`,
`tests/test-manifest-lib.sh`) run in sequence; the harness exits non-zero
if any file does. Typical pass output ends with three `N run, 0 failed`
lines.

The patchset compile gate is a separate, heavier tool:

```bash
sudo tools/validate-patchset.sh --fork /root/open-gpu-kernel-modules
```

It checks out a clean NVIDIA `595.71.05` worktree, applies the composed
patch set, and runs `make modules` against `/lib/modules/$(uname -r)/build`.
Use this after any change to `patches/`, `Dockerfile`'s
`NVIDIA_OPEN_TAG`, or any of the tools under `tools/`.

### What each test covers

| File | Subject |
|---|---|
| `tests/test-compose.sh` | `tools/compose-patchset.sh` — manifest-driven base+addon patch rendering. |
| `tests/test-manifest-lib.sh` | `tools/lib/manifest.sh` — manifest parsing + lint (row count, duplicate ids, base/addon source-branch rules). |
| `tests/test-intent-lint.sh` | `tools/intent-lint.sh` — the patch-intent + patch-review frontmatter schema (`docs/patch-intent-schema.md`). |
| `tools/validate-patchset.sh` | End-to-end: clean checkout → compose → apply → `make modules`. |

### Running a single file

```bash
bash tests/test-intent-lint.sh        # just one file
```

Each `test-*.sh` is independently runnable and reports its own
`N run, 0 failed` summary on the last line.
