# AGENTS.md — biggs.dog

Guidance for AI coding agents working in this repository. Tool-agnostic; the
Zed-specific orchestration lives in `.rules` (which takes precedence in Zed).

## What this repo is

Flux CD **GitOps** repo for a 2-cluster Kubernetes homelab. All desired cluster
state lives here as YAML; Flux reconciles it to the clusters. There is no app
source code here — this is pure declarative infrastructure.

- `clusters/cluster0/`, `clusters/cluster1/` — per-cluster state.
  - `flux-system/` — Flux itself: `sources/` (GitRepository/HelmRepository/
    OCIRepository) and `flux-operator/` (the FluxInstance).
  - `kubernetes/apps/<namespace>/` — applications, grouped by namespace.
- `docs/` — human notes. `.scripts/` — agent/MCP test + benchmark harnesses.
- `.wip/` — scratch/in-progress debugging work (not reconciled).

## The golden rules (read before changing anything)

1. **Edit YAML in Git; never mutate the cluster.** Use agents/kubectl to
   *inspect* live state, but make every persistent change by editing files here
   and letting Flux converge.
2. **Flux tracks `main`.** Work on a feature branch if you like, but nothing
   reconciles until merged to `main`. Don't promise a fix is "live" until then.
3. **Secrets via External Secrets + 1Password.** Never hardcode credentials.
   Add an `ExternalSecret` (ClusterSecretStore `onepassword-connect`) whose
   `remoteRef` `key`/`property` match the 1Password item + field labels
   *exactly*. If an item doesn't exist yet, that's a prerequisite — say so.

## App layout convention

Each app is a Flux `Kustomization` pointing at raw manifests:

```
kubernetes/apps/<ns>/<app>/
  ks.yaml        # Flux Kustomization (dependsOn, commonMetadata labels, path)
  app/           # raw manifests (Deployment, Service, ExternalSecret, ...)
```

- `ks.yaml` sets `path: ./clusters/<cluster>/kubernetes/apps/<ns>/<app>/app`
  and `commonMetadata.labels.app.kubernetes.io/name: <app>`.
- The `<ns>/kustomization.yaml` lists each app's `ks.yaml`; add new apps there.
- Namespaces with Cilium default-deny (e.g. `ai-system`) need an explicit
  `CiliumNetworkPolicy` in `network-policies/policies/` for any new pod's
  ingress/egress — a new app that talks to the network will silently fail
  without one.

## Validation

There is no CI build. Validate before pushing:

```sh
# Render a kustomize root (catches YAML + reference errors)
kubectl kustomize clusters/cluster1/kubernetes/apps/<ns>
kubectl kustomize clusters/cluster1/kubernetes/apps/network-policies

# Parse a single manifest set
python3 -c "import yaml,glob; [list(yaml.safe_load_all(open(f))) for f in glob.glob('path/*.yaml')]"

# Live state
kubectl get kustomizations -A
flux get sources all
```

## kagent agent routing (use the cluster's own agents)

This cluster runs a **kagent MCP server** (`https://mcp.biggs.dog/mcp`,
LAN/VPN only) exposing specialized agents. When a task matches a domain below,
prefer `invoke_agent ai-system/<name>` over answering from memory. Call
`list_agents` first — the invocable set changes mid-migration.

- ✅ `flux-agent` — Flux/GitOps inspection & reconciliation root-cause.
- ✅ `vm-agent` — VictoriaMetrics: PromQL/MetricsQL, alerts, cardinality.
- ✅ `exa-agent` — Web/code search, research (needs Exa API key).
- ✅ `cilium-debug-agent` — Cilium connectivity/Hubble diagnostics; also
  general cluster inspection (has `k8s_*` tools).
- ✅ `cilium-policy-agent` — Author CiliumNetworkPolicies from intent.
- ✅ `codebase-agent` — Structural code intelligence over indexed repos
  (biggs.dog): find symbols, trace calls/data-flow, architecture, blast-radius.
- ⚠️ `k8s-agent`, `helm-agent`, `promql-agent`, `observability-agent`,
  `cilium-manager-agent` — Substrate SandboxAgents; READY but absent from MCP
  `list_agents` (upstream kagent limitation). Use the ✅ fallbacks or
  `kubectl`.

Read-only fallback for the MCP endpoint:
`kubectl port-forward -n ai-system svc/kagent-controller 8083:8083`, then
`.scripts/test-agents.py`.

## Repo conventions

- Pin image tags (no `latest`); note patched/forked images with a comment
  linking the fork + tag (see existing apps for the style).
- ai-system pods pin to the GPU node via `nodeSelector:
  nvidia.com/gpu.present: "true"` and use `storageClassName: host-path` PVCs.
- Containers run hardened: non-root, `allowPrivilegeEscalation: false`, drop
  `ALL` capabilities, `seccompProfile: RuntimeDefault`, read-only root FS where
  the image allows.
- Keep `.rules` and this file in sync with the live agent set.
