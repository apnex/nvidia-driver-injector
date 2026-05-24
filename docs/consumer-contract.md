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

The injector exposes the GPU to k3s consumers via a **node-label gate**. After
a successful module load, the injector pod labels its node
`nvidia.driver/state=ready` (+ `nvidia.driver/version=<version>`). Consumer
Deployments target that label with `spec.nodeSelector` and pick the `nvidia`
runtime class — no device plugin, no `nvidia.com/gpu` resource requests, no
scheduler-side accounting. One GPU, one consumer at a time (vLLM); other pods
talk to vLLM's HTTP API and never touch the GPU directly.

## Contract — the producer's promise

The injector DaemonSet guarantees the following, on every node where its pod
is `Running` and `Ready`:

| Property | Promise |
|---|---|
| Module loaded | `nvidia` + `nvidia_uvm` present in `/proc/modules`; `cat /sys/module/nvidia/version` returns the build's version string (e.g. `595.71.05-aorus.14`). |
| Device files | `/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`, `/dev/nvidia-uvm-tools` exist, mode `0660`, group `gpu`. |
| Persistence | `nvidia-smi -pm 1` has run; GSP loaded, thermal subsystem engaged, GPU at proper P8 idle. |
| Node label | `nvidia.driver/state=ready` |
| Version label | `nvidia.driver/version=<version>` (matches `/sys/module/nvidia/version`) |
| Runtime class | A cluster-scope `RuntimeClass nvidia` exists (handler `nvidia`), pointing at containerd's nvidia handler — configured by `scripts/apply.sh` step 10. |

On graceful uninstall (`kubectl delete daemonset/nvidia-driver-injector`, or
the operator running `uninstall` against a docker-compose deployment), the
entrypoint **removes both labels first** before touching the module — so
consumers stop scheduling onto the node immediately.

If the injector pod is `NotReady`, the label state is the last thing the
entrypoint wrote — kubectl does not auto-revert it on pod crash. Consumers
should not rely on the label flipping back on its own; rely on the
[failure modes](#failure-modes) section below.

## Consumer requirements

A minimum-viable GPU consumer Deployment sets four things:

```yaml
spec:
  template:
    spec:
      nodeSelector:
        nvidia.driver/state: ready          # gate on driver readiness
      runtimeClassName: nvidia              # use the nvidia containerd runtime
      containers:
        - name: workload
          image: <your-image>
          env:
            - name: NVIDIA_VISIBLE_DEVICES
              value: "all"                  # all GPUs on the node (we run 1)
            - name: NVIDIA_DRIVER_CAPABILITIES
              value: "compute,utility"      # CUDA + nvidia-smi
          # NO `resources: limits: nvidia.com/gpu: 1` — we don't run a device
          # plugin. NVIDIA_VISIBLE_DEVICES=all is what gates exposure.
```

Optional but recommended:

- `spec.containers[].securityContext.capabilities.drop: [ALL]` — the
  nvidia-container-runtime handles the device mounts; the consumer itself
  doesn't need privileges.
- Pin to a specific driver: replace
  `nvidia.driver/state: ready` with `nvidia.driver/version: 595.71.05-aorus.14`
  if your workload depends on a known-good driver build (e.g. vLLM tested
  against that specific patch set).

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
      nodeSelector:
        nvidia.driver/state: ready
      runtimeClassName: nvidia
      containers:
        - name: vllm
          image: vllm/vllm-openai:latest
          env:
            - { name: NVIDIA_VISIBLE_DEVICES,     value: "all" }
            - { name: NVIDIA_DRIVER_CAPABILITIES, value: "compute,utility" }
          ports:
            - containerPort: 8000
          volumeMounts:
            - { name: models, mountPath: /models }
      volumes:
        - name: models
          hostPath:                       # vLLM owns its model layout
            path: /srv/models
```

This is illustrative; the real vLLM Deployment lives in the `vllm` repo and
owns its own tuning, model paths, and Service.

## Failure modes

When producer + consumer disagree, here's what to expect:

| Symptom | Cause | Fix |
|---|---|---|
| Consumer pod stuck `Pending` with `0/1 nodes match node selector` | Injector pod hasn't labelled the node yet (cold-build phase, ~60-90s) or has failed | `kubectl logs -n kube-system daemonset/nvidia-driver-injector` to see where the entrypoint stopped |
| Consumer pod `Running` but `nvidia-smi` says `command not found` | `NVIDIA_DRIVER_CAPABILITIES` missing `utility` | Add `utility` to the comma list |
| Consumer pod `Running` but `cuInit` returns `CUDA_ERROR_UNKNOWN` | `NVIDIA_DRIVER_CAPABILITIES` missing `compute` | Add `compute` to the comma list |
| Consumer pod `Running` but no `/dev/nvidia*` inside | `runtimeClassName: nvidia` missing OR containerd's nvidia handler not configured | Re-run `sudo scripts/apply.sh` on the node (its k3s step is idempotent); confirm `kubectl get runtimeclass nvidia` exists |
| Consumer pod `CrashLoopBackOff` with `failed to create containerd task: ...: nvidia-container-cli: ...` | nvidia-container-toolkit installed but containerd config drift | Re-run `sudo nvidia-ctk runtime configure --runtime=containerd` + `sudo systemctl restart k3s` (or `containerd`) |
| Pod scheduled to node but driver got unloaded out-of-band | Label is stale (the producer no longer holds the contract) | `kubectl label nodes <node> nvidia.driver/state-` to evict consumers, then restart the injector pod |

## What this contract does NOT promise

Out of scope, by deliberate YAGNI call:

- **No multi-GPU sharing model.** One GPU, one consumer (vLLM). Other pods
  talk to vLLM's HTTP API.
- **No `nvidia.com/gpu` scheduling.** We do not run `nvidia-device-plugin`.
  Single GPU + single consumer + no fair-share quotas needed; the node-label
  gate is sufficient.
- **No MIG.** The 5090 doesn't do MIG anyway, and we wouldn't ship the
  plumbing for it.
- **No DCGM exporter / metrics.** Use vLLM's own `/metrics` endpoint or
  scrape `nvidia-smi` from the injector pod via `kubectl exec`.
- **No cross-cluster pinning.** Both labels are node-local; the contract has
  no opinion on multi-cluster federation.

If any of these grow into requirements, that's a contract revision — not
something a consumer should work around with extra annotations.
