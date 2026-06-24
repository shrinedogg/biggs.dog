# gpu-arbiter-operator (Flux deployment)

GitOps deployment of the [`gpu-arbiter-operator`](https://github.com/shrinedogg/gpu-arbiter-operator)
— a controller-runtime operator that arbitrates the single RTX 5090 (`nv-01`)
between the **vLLM** inference Deployment (`ai-system/vllm`) and transient
**gaming-session** pods created by Fenrir/Direwolf in the `dreamcast` namespace.

It replaces the original hand-rolled bash `gpu-arbiter` Deployment.

## What it does

The operator reconciles a single cluster-scoped `GPUArbiter` custom resource
(`cluster0`) and, on every poll (`spec.intervalSeconds`, default 2s):

1. **Scales vLLM.** Lists gaming pods by label selector
   (`app In [alex-steam, direwolf-worker]`) in `dreamcast`. If ≥1 active gaming
   pod exists it scales `ai-system/vllm` to `0` (releasing GPU VRAM); when idle
   it scales back to `1`.
2. **Removes the scheduling gate.** Gaming pods start gated with
   `gpu.biggs.dog/await-vram`. The operator removes the gate once vLLM is down
   (`status.replicas == 0`), or free VRAM (`DCGM_FI_DEV_FB_FREE` via
   VictoriaMetrics) ≥ `spec.freeMiB`, or a safety `spec.timeoutSeconds` elapses.

`kubectl get gpuarbiter cluster0` surfaces the live decision
(`GAMEPODS`, `VLLMREPLICAS`, `FREEVRAM`, and a `message`).

## Directory layout

```
gpu-arbiter-operator/
├── ks.yaml                      # 3 Flux Kustomizations (ordered, see below)
├── crds/
│   └── crds.yaml                # GPUArbiter CRD (cluster-scoped, gpu.biggs.dog/v1alpha1)
├── ai-system-rbac/              # Role + RoleBinding in ai-system to scale vllm
│   ├── kustomization.yaml
│   └── rbac.yaml
└── app/
    └── operator.yaml            # SA, ClusterRole/Binding, leader-election Role/Binding, Deployment
```

The `GPUArbiter` **instance** (the CR itself) lives next door in
[`../gpu-arbiter-instance`](../gpu-arbiter-instance), so the operator and its
configuration reconcile as independent Flux Kustomizations.

## Reconciliation order

`ks.yaml` defines three Flux Kustomizations with explicit `dependsOn` ordering:

1. `gpu-arbiter-operator-crds` — installs the CRD first (`wait: false`).
2. `gpu-arbiter-ai-system-rbac` — the cross-namespace Role/RoleBinding that lets
   the `dreamcast` service account patch `deployments`/`deployments/scale` in
   `ai-system`. Must exist before the manager starts reconciling.
3. `gpu-arbiter-operator` — the manager Deployment + cluster-scoped RBAC.
   `dependsOn` both of the above.

`gpu-arbiter-instance` (separate dir) `dependsOn` `gpu-arbiter-operator`.

## RBAC model

The operator runs as `dreamcast/gpu-arbiter-controller-manager` and needs to
act across two namespaces:

- **Cluster-scoped** (`app/operator.yaml`): get/list/watch `pods`; manage
  `deployments` + `deployments/scale`; full control of `gpuarbiters` (+ status,
  finalizers). Leader election (`leases`, `configmaps`, `events`) is a
  namespaced Role in `dreamcast`.
- **ai-system** (`ai-system-rbac/rbac.yaml`): a namespaced Role granting
  get/list/watch/patch on `deployments` and get/patch/update on
  `deployments/scale`, RoleBound to the `dreamcast` service account — this is
  what lets it scale `ai-system/vllm`.

## Image

`shrinedogg/gpu-arbiter-operator:v0.1.1` (`linux/amd64`). The tag is pinned via
the `images:` block in `app`'s Flux Kustomization. Tags are **immutable**
semver, so `imagePullPolicy` is the default `IfNotPresent` — a new release means
a new tag, never an in-place overwrite.

Cut a new release (bump the version in both `app/operator.yaml` and `ks.yaml`):

```bash
docker buildx build --platform linux/amd64 \
  -t shrinedogg/gpu-arbiter-operator:v0.1.1 --push .
git tag -a v0.1.1 -m "v0.1.1" && git push origin v0.1.1   # in the operator repo
```

## vLLM coupling

`ai-system/vllm`'s Deployment intentionally **omits** `spec.replicas` so Flux
does not fight the arbiter over the replica count (an unmanaged Deployment
defaults to 1, which is the correct idle state). See the comment block in
`clusters/cluster0/kubernetes/apps/ai-system/vllm/app/deployment.yaml`.

## Testing without a Moonlight session

Create a dummy pod with a matching label and the scheduling gate; the operator
will scale vLLM to 0 and ungate it, then restore vLLM to 1 on delete:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: gpu-arbiter-test-dummy
  namespace: dreamcast
  labels:
    app: direwolf-worker
spec:
  schedulingGates:
    - name: gpu.biggs.dog/await-vram
  restartPolicy: Never
  containers:
    - name: pause
      image: registry.k8s.io/pause:3.10
EOF

kubectl get gpuarbiter cluster0           # GAMEPODS 1, VLLMREPLICAS 0
kubectl delete pod gpu-arbiter-test-dummy -n dreamcast
kubectl get gpuarbiter cluster0           # GAMEPODS 0, VLLMREPLICAS 1
```

> Note: scaling vLLM to 0 takes the in-cluster kagent inference backend offline
> while the "session" is active — that is the intended behavior.
