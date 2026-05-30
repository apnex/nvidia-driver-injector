# A9 eGPU Probe-Time Classification — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Set `nv->is_external_gpu` at PCI probe (one line) so A6/A7's bounded-wait gates read a correct flag on the first open of a bind — closing the A6-coverable first-open coverage hole — and ship it with the already-committed A8 v2.2 observability.

**Architecture:** A single line in the open driver's `nv_pci_probe` calls E1's probe-safe detector `os_pci_is_thunderbolt_attached(nv->handle)` and stores the result in the shared `nv->is_external_gpu` field, **after** `nv->handle = pci_dev;`. It is carved as a new **addon** patch `A9` (E1 stays upstream-clean); A6/A7 gates are unchanged. Monotonic (nothing writes the flag FALSE). Spec: `docs/superpowers/specs/2026-05-31-a9-egpu-probe-classify-design.md`.

**Tech Stack:** NVIDIA open-gpu-kernel-modules (kernel C); the injector patch-composition system (fork branches + `patches/manifest` + `tools/regen-base-patches.sh`); container build + k3s DaemonSet deploy.

**Two repos:** fork = `/root/open-gpu-kernel-modules` (source of truth for patches); injector = `/root/nvidia-driver-injector` (patch files + docs + deploy). "Kernel patch ≠ unit test": verification is **compile** + **source inspection** + **runtime sysfs invariant** (there is no nvidia.ko unit-test framework).

---

## Phase 1 — A9 source + patch (chip-free, compile-validated, immediately executable)

### Task 1: Create the `a9` fork branch and make the one-line change

**Files:**
- Modify (fork): `/root/open-gpu-kernel-modules/kernel-open/nvidia/nv-pci.c` (after line 2028)

- [ ] **Step 1: Branch `a9` from the `a8` tip**

```bash
cd /root/open-gpu-kernel-modules
git checkout -b a9-egpu-probe-classify a8-f40b-sysfs-observability
```
Expected: `Switched to a new branch 'a9-egpu-probe-classify'`

- [ ] **Step 2: Confirm the exact anchor line (alignment whitespace matters)**

```bash
grep -nF 'nv->handle' kernel-open/nvidia/nv-pci.c | grep -F '= pci_dev;'
```
Expected: one hit, `2028:    nv->handle             = pci_dev;` (the `=` is alignment-padded).

- [ ] **Step 3: Insert the probe-set line immediately AFTER line 2028**

Use Edit with this exact `old_string` (copy the real whitespace from Step 2's line) → `new_string`:

old:
```c
    nv->handle             = pci_dev;
```
new:
```c
    nv->handle             = pci_dev;

    /*
     * tb_egpu (addon A9): classify the external GPU at PROBE so the A6 open-path
     * and A7 shutdown-path bounded-wait gates read a correct nv->is_external_gpu
     * on the FIRST open of a bind. The blob otherwise sets this flag lazily
     * inside the first open's RmInitAdapter (osinit.c), leaving the first open
     * unguarded -> host wedge on a userspace-recovered chip (forensics:
     * OA-reset-ladder-wedge-2026-05-31). os_pci_is_thunderbolt_attached() is
     * E1's pure-PCI-topology detector: probe-safe (no chip MMIO, no GPU lock),
     * and byte-identical to the value the blob sets. MUST be after the
     * nv->handle assignment above (before it, handle is NULL -> NV_FALSE, a
     * silent no-op that re-wedges). Monotonic: nothing writes this field FALSE.
     */
    nv->is_external_gpu    = os_pci_is_thunderbolt_attached(nv->handle);
```

- [ ] **Step 4: Verify the line landed strictly after the handle assignment**

```bash
grep -n -A14 'nv->handle             = pci_dev;' kernel-open/nvidia/nv-pci.c | grep -nF 'is_external_gpu'
```
Expected: the `nv->is_external_gpu = os_pci_is_thunderbolt_attached(nv->handle);` line appears within the 14 lines after the anchor.

- [ ] **Step 5: Commit to the `a9` branch**

```bash
git add kernel-open/nvidia/nv-pci.c
git commit -m "tb-egpu: probe-time eGPU classification (A9) — set is_external_gpu in nv_pci_probe

A6/A7 gate on nv->is_external_gpu, which the blob sets lazily during the first
open's RmInitAdapter (osinit.c:1301) -> the first open of a bind is unguarded.
Set it at probe via E1's os_pci_is_thunderbolt_attached(nv->handle) so the gate
reads a correct flag on the first open. Byte-identical to the blob's value,
monotonic (no FALSE-writer). Closes the A6-coverable H-OA1 first-open hole."
git rev-parse --short HEAD
```
Expected: a commit SHA printed.

---

### Task 2: Register A9 in the patch manifest

**Files:**
- Modify (injector): `/root/nvidia-driver-injector/patches/manifest` (after line 26, the A8 row)

- [ ] **Step 1: Add the A9 row after A8**

Edit `patches/manifest`:

old:
```
  A8-f40b-sysfs-observability addon -              fork:a8-f40b-sysfs-observability
```
new:
```
  A8-f40b-sysfs-observability addon -              fork:a8-f40b-sysfs-observability
  A9-egpu-probe-classify     addon  -              fork:a9-egpu-probe-classify
```

- [ ] **Step 2: Verify the row parses (id / layer / upstreamed_in / source)**

```bash
cd /root/nvidia-driver-injector
grep -nF 'A9-egpu-probe-classify' patches/manifest
```
Expected: one hit, columns `A9-egpu-probe-classify  addon  -  fork:a9-egpu-probe-classify`.

---

### Task 3: Regenerate the A9 patch file (and preserve the addon prose-header convention)

**Files:**
- Create (injector): `patches/addon/A9-egpu-probe-classify.patch`
- Transient: `regen` also rewrites A6/A7/A8 headers + `.regen-state` — those are reverted (the project keeps prose headers on A6–A9).

- [ ] **Step 1: Run regen (also compile-validates the composed set = Gate 1)**

```bash
cd /root/nvidia-driver-injector
tools/regen-base-patches.sh 2>&1 | tail -5
```
Expected: ends with `validate: OK -- composed patch set compiles against kernel <kver>`. (If it fails to compile, STOP — fix the source in Task 1 before proceeding; `git apply --check` is NOT a substitute for this compile.)

- [ ] **Step 2: Preserve prose headers — save A9 body, revert the header churn on A6/A7/A8/.regen-state**

```bash
A9=patches/addon/A9-egpu-probe-classify.patch
sed -n '/^diff --git/,$p' "$A9" > /tmp/a9-body.diff   # save regen's validated A9 body
git checkout patches/addon/A6-f40b-bounded-wait-open.patch \
             patches/addon/A7-f40b-bounded-wait-shutdown.patch \
             patches/addon/A8-f40b-sysfs-observability.patch \
             patches/base/.regen-state 2>/dev/null || true
git status --short patches/ | grep -c '^'   # expect just the new A9 file (untracked) — A6/A7/A8/.regen-state clean
```
Expected: A6/A7/A8/.regen-state show no diff; `A9-...patch` is the only change.

- [ ] **Step 3: Write A9's prose header + attach the validated body**

Replace the regen-generated header on `$A9` with a prose header (mirror A8's style), keeping the diff body:

```bash
cat > /tmp/a9-header.txt <<'EOF'
# A9-egpu-probe-classify — probe-time eGPU classification for the A6/A7 bounded-wait gates.
#
# A6 (open) and A7 (shutdown) bounded-wait wrappers gate on nv->is_external_gpu.
# The blob sets that flag lazily inside the first open's RmInitAdapter
# (osinit.c:1301), so it is FALSE on the FIRST open of any bind -> A6/A7 fall
# through to the synchronous path -> on a userspace-recovered chip the first open
# wedges the host (forensics: OA-reset-ladder-wedge-forensics-2026-05-31).
#
# A9 sets nv->is_external_gpu at PROBE, in nv_pci_probe, immediately after
# `nv->handle = pci_dev;`, via E1's probe-safe detector
# os_pci_is_thunderbolt_attached(nv->handle). Pure PCI topology (no chip MMIO,
# no GPU lock); byte-identical to the blob's value (E1 made RmCheckForExternalGpu
# that one call). Monotonic: nothing writes the flag FALSE, so probe-set can only
# ADD arming; the blob's redundant TRUE-only set at osinit.c:1301 is self-healing.
#
# Carved in the ADDON layer (E1 stays upstream-clean — set-TIMING is a project
# workaround, not the detector). A6/A7 gates are UNCHANGED. Scope: closes the
# A6-coverable H-OA1 first-open hole only (NOT the H-OA2 pre-nv_open_device site;
# NOT NVreg_GpuInitOnProbe=1). RmForceExternalGpu is retired (zero tree refs).
EOF
cat /tmp/a9-header.txt /tmp/a9-body.diff > "$A9"
grep -c 'is_external_gpu' "$A9"   # expect >= 1 (the diff body) ; header present
head -1 "$A9"                      # expect the prose header line
```
Expected: `head -1` shows the prose header; `is_external_gpu` present in the body.

---

### Task 4: Write the A9 patch-intent doc

**Files:**
- Create (injector): `docs/patch-intents/A9-egpu-probe-classify.md`

- [ ] **Step 1: Create the intent doc (mirror A6/A8 style + the lint schema)**

Write `docs/patch-intents/A9-egpu-probe-classify.md` with frontmatter `status: needs-review` and these requirements (GIVEN/WHEN/THEN where the lint requires):
- **SHALL classify at probe:** in `nv_pci_probe`, after `nv->handle = pci_dev;`, set `nv->is_external_gpu = os_pci_is_thunderbolt_attached(nv->handle)`.
- **Monotonicity invariant (load-bearing):** no code SHALL write `nv->is_external_gpu = FALSE`; the only writers are A9's probe-set and the blob's TRUE-only set at `osinit.c:1301`. A future FALSE-writer would silently disarm A6/A7.
- **Placement invariant:** MUST be after the `nv->handle` assignment (before it, `handle` is NULL → `NV_FALSE` → silent no-op that re-wedges).
- **Scope boundary:** closes the A6-coverable **H-OA1** first-open hole; does NOT fix the **H-OA2** pre-`nv_open_device` site; does NOT cover `NVreg_GpuInitOnProbe=1`. `RmForceExternalGpu` retired.
- **Deferred:** the A6 leaked-worker hardening (UAF = F42 + lock-held) is a coupled follow-up (v5), not A9.
- Cross-ref the spec + forensics + F42.

- [ ] **Step 2: Lint the intent doc**

```bash
cd /root/nvidia-driver-injector
tools/intent-lint.sh docs/patch-intents/A9-egpu-probe-classify.md && echo "intent-lint: PASS"
```
Expected: `intent-lint: PASS` (exit 0). If it fails, fix the flagged rule inline.

---

### Task 5: Record A9 in the patch indices

**Files:**
- Modify (injector): `docs/patches.md`, `docs/upstream-plan.md`

- [ ] **Step 1: Add A9 as an Addon (project-local) row in `docs/patches.md`**

Add an A9 entry mirroring the A8 row: A9 = addon, "probe-time eGPU classification; closes the A6-coverable first-open hole." Note E1 stays upstream-clean.

- [ ] **Step 2: Note A9 in `docs/upstream-plan.md`**

Under the Addon `A` section, add A9: project-local, NOT upstream-bound (the set-timing workaround); E1 (the detector) remains the upstream-bound piece.

- [ ] **Step 3: Verify both reference A9**

```bash
grep -lF 'A9' docs/patches.md docs/upstream-plan.md
```
Expected: both files listed.

---

### Task 6: Compile + source data-flow validation (Gates 1–2)

- [ ] **Step 1: Standalone compile of the composed module (Gate 1 re-confirm)**

```bash
cd /root/open-gpu-kernel-modules
make modules SYSSRC=/lib/modules/$(uname -r)/build -j"$(nproc)" IGNORE_CC_MISMATCH=1 >/tmp/a9-build.log 2>&1; echo "rc=$?"
grep -ciE 'error:' /tmp/a9-build.log
ls -la kernel-open/nvidia.ko
```
Expected: `rc=0`; zero `error:`; `nvidia.ko` present. (The `a9` working tree carries the change.)

- [ ] **Step 2: Source data-flow review in the composed tree (Gate 2)**

```bash
grep -n -B1 -A1 'is_external_gpu    = os_pci_is_thunderbolt_attached' kernel-open/nvidia/nv-pci.c
grep -rnF 'is_external_gpu = NV_FALSE' kernel-open src || echo "no FALSE-writer (monotonic OK)"
```
Expected: the probe-set line is on the line *after* `nv->handle = pci_dev;`; and no `is_external_gpu = NV_FALSE` writer anywhere (monotonicity holds). If the set is not after the handle assignment, STOP and re-do Task 1 Step 3.

---

### Task 7: Commit the injector-repo A9 artifacts

- [ ] **Step 1: Stage + commit (only A9 artifacts)**

```bash
cd /root/nvidia-driver-injector
git add patches/addon/A9-egpu-probe-classify.patch patches/manifest \
        docs/patch-intents/A9-egpu-probe-classify.md docs/patches.md docs/upstream-plan.md
git diff --cached --name-only   # confirm: exactly these 5, no A6/A7/A8/.regen-state churn
git commit -m "A9: probe-time eGPU classification — close the A6/A7 first-open coverage hole

One-line probe-set of nv->is_external_gpu via E1's os_pci_is_thunderbolt_attached,
after nv->handle=pci_dev in nv_pci_probe. New addon patch (E1 upstream-clean);
A6/A7 gates unchanged; monotonic. Compile-validated (composed set compiles).
Source: fork a9 tip (local; NOT pushed). Closes the A6-coverable H-OA1 first-open
hole — NOT the open-arm wedge (H-OA2 untouched). Spec: docs/superpowers/specs/
2026-05-31-a9-egpu-probe-classify-design.md. Tasks #287 + (bundled) #288."
git log --oneline -1
```
Expected: exactly the 5 files staged; commit SHA printed.

**END OF PHASE 1.** Phase 1 is chip-free and complete: A9 source + patch + intent + compile-validated, committed locally. Fork push + deploy are gated.

---

## Phase 2 — Deploy `apnex.24` (A9 + A8 v2.2) — GATED (user go + GPU-free window; disruptive)

> Do NOT start Phase 2 without the user's go AND a GPU-free window. It tears down the running driver and rebuilds the image. Tasks are exact but gated.

### Task 8: Version bump to `apnex.24`
- [ ] On the fork `a5` branch, bump `version.mk` `NVIDIA_VERSION = 595.71.05-apnex.24`; commit (amend a5 under the force-push carve-out if a5 was pushed); `tools/regen-base-patches.sh`; revert the A6–A9 prose-header churn as in Task 3 Step 2; commit the regenerated A5 patch.

### Task 9: Build + import the image
- [ ] `docker build -t apnex/nvidia-driver-injector:595.71.05-apnex.24 .` ; `docker save apnex/nvidia-driver-injector:595.71.05-apnex.24 | sudo k3s ctr images import -`.

### Task 10: Roll the DaemonSet
- [ ] Update `k8s/daemonset.yaml` image tag → `595.71.05-apnex.24`; `kubectl apply -f k8s/daemonset.yaml`; `kubectl delete pod -n kube-system <injector-pod>` (OnDelete strategy → DS recreates → loads apnex.24). Watch `kubectl logs` for a clean `state=ready`.

### Task 11: Healthy-deploy verification (Gate 3 — non-destructive)
- [ ] **Before any chip-touching open**, read the invariant that was FALSE at the wedge:
```bash
cat /sys/bus/pci/devices/0000:04:00.0/tb_egpu_is_external   # MUST be 1 (old build: 0 until first open)
```
- [ ] First open emits the bounded-worker line:
```bash
sudo timeout 10 nvidia-smi -L; dmesg | grep -F 'tb_egpu [F40b]: open scheduled to bounded worker' | tail -1
```
Expected: the `open scheduled to bounded worker` line present (old build: synchronous, absent).
- [ ] Across an unbind→rebind, `tb_egpu_is_external` stays `1` (the exact invariant whose violation caused the 2026-05-31 wedge). Use `tools/oa-harness/lib.sh` helpers; BAR1-first; reboot-ready.

---

## Phase 3 — Destructive validation — FOLLOW-UP, GATED (before any "survivable" claim)

### Task 12: First-open-on-bad-chip destructive test (Lane-3 Rung-8 class)
- [ ] Establish the F40 precondition, then trigger the **first open of a fresh bind on the bad chip** with A9 present. Confirm: A6 engages (bounded-worker line), returns `-EIO`, **host survives**. This is the only path that proves "first-open-on-bad-chip now bounded instead of wedged." Until it passes, the claim is scoped to "closes the hole; compile- + healthy-sysfs-validated," NOT "wedge survived." Reboot-loop; user present. Couples to the A6 leaked-worker hardening follow-up (F42 / v5).

---

## Self-Review

**Spec coverage:** the one-line fix (Task 1), addon-not-E1 carve (Tasks 1–3), A6/A7 gates unchanged (no task touches them — correct), monotonicity invariant (Task 4 Step 1 + Task 6 Step 2), scope boundary wording (Tasks 1/4/7 commit+intent), A8 v2.2 bundled deploy (Phase 2), the 5 verification gates (Tasks 3/6/11/12), deferred A6 leaked-worker hardening (Task 4 + Task 12 note) — all covered.

**Placeholder scan:** the only prose-described (non-code-block) steps are the intent-doc body (Task 4) and the docs/patches index rows (Task 5), where exact wording is editorial; all code/commands are concrete. No TBD/TODO.

**Type/name consistency:** `nv->is_external_gpu`, `os_pci_is_thunderbolt_attached`, `nv->handle`, branch `a9-egpu-probe-classify`, patch `A9-egpu-probe-classify` used consistently throughout.
