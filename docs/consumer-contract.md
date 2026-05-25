# Consumer contract

Public contract between the `nvidia-driver-injector` DaemonSet (the
**producer**) and any GPU consumer pod (the **consumer**) running on the same
k3s / Kubernetes cluster. Read this once before deploying vLLM, kate, or any
new GPU workload.

For install / teardown of the producer itself, see
[`install-workflow.md`](install-workflow.md) and
[`teardown-workflow.md`](teardown-workflow.md). For the architectural shape,
see [`architecture.md`](architecture.md).

## Summary

The injector exposes the GPU to k3s consumers via the **canonical NVIDIA
device-plugin path**. After a successful module load, the injector writes a
PC-3 readiness file (`/run/nvidia/injector/state`); the NVIDIA
`k8s-device-plugin` DaemonSet (v0.17.4) waits on that file, then probes NVML
and advertises `nvidia.com/gpu: N` to kubelet. Consumer Deployments request
`resources.limits[nvidia.com/gpu]: 1` and pick the `nvidia` runtime class.
One GPU, one consumer at a time (vLLM); other pods talk to vLLM's HTTP API
and never touch the GPU directly.

The producer remains the source of truth for *driver readiness*. The device
plugin is the source of truth for *resource advertisement*. The scheduling
gate is the advertised resource — not a custom label.

## Contract — the producer's promise

The injector DaemonSet guarantees the following, on every node where its pod
is `Running` and `Ready`:

| Property | Promise |
|---|---|
| Module loaded | `nvidia` + `nvidia_uvm` present in `/proc/modules`; `cat /sys/module/nvidia/version` returns the build's version string (e.g. `595.71.05-aorus.14`). |
| Device files | `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools` exist, mode `0660`, group `gpu`. |
| Persistence | `nvidia-smi -pm 1` has run; GSP loaded, thermal subsystem engaged, GPU at proper P8 idle. |
| PC-3 readiness | `/run/nvidia/injector/state` exists with `"phase":"ready"` JSON; heartbeat refreshed on each successful health tick. **This is the contract surface between the injector and the device plugin's initContainer** — consumers do not read it directly. |
| Version label | `nvidia.driver/version=<version>` (matches `/sys/module/nvidia/version`) — informational; useful for `kubectl get nodes -L nvidia.driver/version` but not on the scheduling path. |
| Runtime class | A cluster-scope `RuntimeClass nvidia` exists (handler `nvidia`), pointing at containerd's nvidia handler — configured by `scripts/apply.sh` step 10. |

The legacy `nvidia.driver/state=ready` node label is **retired**. The
device plugin's live NVML probe replaces it: if NVML returns 0 GPUs, the
plugin advertises 0, and the scheduler stops scheduling consumers onto the
node. This eliminates the D-1 stale-label class of bug by design.

On graceful uninstall (`kubectl delete daemonset/nvidia-driver-injector`, or
the operator running `uninstall` against a docker-compose deployment), the
entrypoint **clears the PC-3 file first** before touching the module — so
the device plugin notices on its next probe and the advertised
`nvidia.com/gpu` count drops to 0.

## Consumer requirements

A minimum-viable GPU consumer Deployment sets three things:

```yaml
spec:
  template:
    spec:
      runtimeClassName: nvidia              # use the nvidia containerd runtime
      containers:
        - name: workload
          image: <your-image>
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"                  # device injection scope
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "compute,utility"      # CUDA + nvidia-smi
          resources:
            limits:
              nvidia.com/gpu: 1             # scheduling gate
            requests:
              nvidia.com/gpu: 1             # paired; kubelet rejects mismatch
```

Three things, in order of which problem each solves:

1. `resources.limits[nvidia.com/gpu]: 1` (paired with `requests`) — the
   **scheduling gate**. The scheduler will only place the pod on a node where
   the device plugin currently advertises ≥1 of the resource. This is the
   migration target of sub-cycle 5 (was `nodeSelector: nvidia.driver/state:
   ready`).
2. `runtimeClassName: nvidia` — selects the `nvidia` handler in containerd
   so `nvidia-container-cli` injects `/dev/nvidia*` into the pod's mount
   namespace. **Still required**; the migration only moved the scheduling
   primitive, not the device-injection mechanism.
3. `NVIDIA_VISIBLE_DEVICES=all` + `NVIDIA_DRIVER_CAPABILITIES=compute,utility`
   — the env-var protocol `nvidia-container-cli` reads to decide *which*
   devices and *which* libraries (CUDA, NVML, …) get mounted in. **Still
   required**; mirror the device plugin's own values.

Optional but recommended:

- `spec.containers[].securityContext.capabilities.drop: [ALL]` — the
  nvidia-container-runtime handles the device mounts; the consumer itself
  doesn't need privileges.
- Pin to a specific driver via `nodeSelector: nvidia.driver/version:
  595.71.05-aorus.14` if your workload was validated against a known-good
  build (e.g. vLLM tested against that specific patch set). This is in
  addition to the `nvidia.com/gpu` gate, not a replacement.

## Worked example — minimum-viable vLLM-shape consumer

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: vllm }
  template:
    metadata:
      labels: { app: vllm }
    spec:
      runtimeClassName: nvidia
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          env:
            - { name: NVIDIA_VISIBLE_DEVICES,     value: "all" }
            - { name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility" }
          resources:
            limits:    { nvidia.com/gpu: 1 }
            requests:  { nvidia.com/gpu: 1 }
          ports:
            - containerPort: 8000
          volumeMounts:
            - { name: models, mountPath: /models }
      volumes:
        - name: models
          hostPath:                       # vLLM owns its model layout
            path: /srv/models
```

This is illustrative; the real vLLM Deployment lives in the
[`apnex/k8s-vllm`](https://github.com/apnex/k8s-vllm) repo and owns its own
tuning, model paths, and Service.

## Failure modes

When producer + consumer disagree, here's what to expect:

| Symptom | Cause | Fix |
|---|---|---|
| Consumer pod stuck `Pending` with `0/1 nodes available: 1 Insufficient nvidia.com/gpu` | Device plugin not advertising the resource — either the plugin pod isn't `Running` or the injector hasn't reached PC-3 `phase=ready` (cold-build phase, ~60-90s) | `kubectl describe node \| grep -A1 'nvidia.com/gpu'` (Allocatable should show ≥1); then `kubectl get pods -n kube-system -l name=nvidia-device-plugin-ds`; then `cat /run/nvidia/injector/state` on the node |
| Consumer pod `Running` but `nvidia-smi` says `command not found` | `NVIDIA_DRIVER_CAPABILITIES` missing `utility` | Add `utility` to the comma list |
| Consumer pod `Running` but `cuInit` returns `CUDA_ERROR_UNKNOWN` | `NVIDIA_DRIVER_CAPABILITIES` missing `compute` | Add `compute` to the comma list |
| Consumer pod `Running` but no `/dev/nvidia*` inside | `runtimeClassName: nvidia` missing OR containerd's nvidia handler not configured | Re-run `sudo scripts/apply.sh` on the node (its k3s step is idempotent); confirm `kubectl get runtimeclass nvidia` exists |
| Consumer pod `CrashLoopBackOff` with `failed to create containerd task: ...: nvidia-container-cli: ...` | nvidia-container-toolkit installed but containerd config drift | Re-run `sudo nvidia-ctk runtime configure --runtime=containerd` + `sudo systemctl restart k3s` (or `containerd`) |
| Pod scheduled to node but driver got unloaded out-of-band | Device plugin hasn't re-probed yet (small race window) | Delete the device-plugin pod to force a re-probe: `kubectl -n kube-system delete pod -l name=nvidia-device-plugin-ds` |

## What this contract does NOT promise

Out of scope, by deliberate YAGNI call:

- **No multi-GPU sharing model.** One GPU, one consumer (vLLM). Other pods
  talk to vLLM's HTTP API.
- **No MIG / fractional GPU / time-slicing config.** The device plugin
  defaults to whole-device exclusive — one `nvidia.com/gpu` per consumer pod.
  The 5090 doesn't do MIG anyway, and we don't ship a `ConfigMap` to enable
  time-slicing.
- **No DCGM exporter / metrics.** Use vLLM's own `/metrics` endpoint or
  scrape `nvidia-smi` from the injector pod via `kubectl exec`.
- **No cross-cluster pinning.** The contract is node-local; it has no
  opinion on multi-cluster federation.

If any of these grow into requirements, that's a contract revision — not
something a consumer should work around with extra annotations.
