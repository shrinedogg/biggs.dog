# AGENTS.md: biggs.dog

Guidance for AI coding agents working in this repository. Tool-agnostic; the
Zed-specific orchestration lives in `.rules` (which takes precedence in Zed).

## What this repo is

Flux CD GitOps repo for a 2-cluster Kubernetes homelab. All desired cluster
state lives here as YAML; Flux reconciles it to the clusters. There is no app
source code here, only declarative infrastructure.

- `clusters/cluster0/`, `clusters/cluster1/`: per-cluster state.
  - `flux-system/`: Flux itself, `sources/` (GitRepository/HelmRepository/
    OCIRepository) and `flux-operator/` (the FluxInstance).
  - `kubernetes/apps/<namespace>/`: applications, grouped by namespace.
- `docs/`: human notes. `.scripts/`: agent/MCP test + benchmark harnesses.
- `.wip/`: scratch/in-progress debugging work (not reconciled).

## The golden rules (read before changing anything)

1. Edit YAML in Git; never mutate the cluster. Use agents/kubectl to
   *inspect* live state, but make every persistent change by editing files
   here and letting Flux converge.
2. Flux tracks `main`. Work on a feature branch if you like, but nothing
   reconciles until merged to `main`. Do not promise a fix is "live" until
   then.
3. Secrets via External Secrets + 1Password. Never hardcode credentials. Add
   an `ExternalSecret` (ClusterSecretStore `onepassword-connect`) whose
   `remoteRef` `key`/`property` match the 1Password item + field labels
   *exactly*. If an item does not exist yet, that is a prerequisite: say so.

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
  ingress/egress; a new app that talks to the network will silently fail
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

This cluster runs kagent `1.0.0-alpha11`. When a task matches a domain below,
prefer the matching agent over answering from memory.

All 12 agents are `kind: Agent` (`api.kagent.dev/v1alpha3`), all `Ready=True`.
The old `SandboxAgent` runtime split is gone: the five "substrate" agents
(`k8s`, `helm`, `promql`, `observability`, `cilium-manager`) are now plain
`Agent` CRs on the `golang-adk` Harness (`kubectl get agents -n ai-system`).
The leftover `kind: SandboxAgent` objects (`ACCEPTED=False`) are 0.10.x
orphans and can be ignored.

The `list_agents` / `invoke_agent` MCP tools were **removed in
1.0.0-alpha11**; do not call them. Reach an agent either way:

1. **A2A, per-agent (direct).** JSON-RPC 2.0 over HTTP at
   `POST http://kagent-controller.ai-system.svc:8083/agents/ai-system/<name>`
   (methods `SendMessage` with `message.role` = `ROLE_USER`, `GetTask`).
   Agent card: `GET .../agents/ai-system/<name>/.well-known/agent-card.json`.
   From a laptop, `kubectl port-forward -n ai-system svc/kagent-controller
   8083:8083`.
2. **MCP session/sandbox surface.** `https://mcp.biggs.dog/mcp` (LAN/VPN only)
   exposes *sessions* and *sandboxes*, not an agent list (`list_sessions`,
   `invoke_session`, `create_sandbox`, `get_sandbox`, ...). Auth: the
   `kagent-mcp-api-keys` `editor` key (gateway `kagent-mcp` HTTPRoute, Strict
   apiKey).

Live check (read-only): `kubectl get agents -n ai-system`, then a card fetch
or `.scripts/test-agents.py` (per-agent card + a live `SendMessage`).

The agents:

- `flux-agent`: Flux/GitOps inspection and reconciliation root-cause.
- `vm-agent`: VictoriaMetrics PromQL/MetricsQL, alerts, cardinality.
- `exa-agent`: web/code search, research (needs Exa API key).
- `cilium-debug-agent`: Cilium connectivity/Hubble; general cluster
  inspection (carries generic `k8s_*` tools).
- `cilium-policy-agent`: authors CiliumNetworkPolicies from intent.
- `codebase-agent`: structural code intelligence over indexed repos
  (biggs.dog): find symbols, trace calls/data-flow, blast-radius.
- `mindwtr-agent`: Mindwtr task management.
- `k8s-agent`: general K8s ops/inspection/troubleshooting.
- `helm-agent`: Helm release management/troubleshooting.
- `promql-agent`: PromQL query generation from natural language.
- `observability-agent`: metrics, Grafana dashboards, alerting.
- `cilium-manager-agent`: Cilium install/config/upgrade.

> **Current state (2026-10-10):** all 12 reconcile `Ready`, but a live
> `SendMessage` returns `TASK_STATE_FAILED` with `403 Forbidden` from the
> substrate egress proxy (actor-identity `k8s-credential-provider`), not
> vLLM. vLLM is healthy and the model key is correct, so the 403 is the actor
> egress path. "Ready" does not currently mean "completes a turn."

## Repo conventions

- Pin image tags (no `latest`); note patched/forked images with a comment
  linking the fork + tag (see existing apps for the style).
- ai-system pods pin to the GPU node via `nodeSelector:
  nvidia.com/gpu.present: "true"` and use `storageClassName: host-path` PVCs.
- Containers run hardened: non-root, `allowPrivilegeEscalation: false`, drop
  `ALL` capabilities, `seccompProfile: RuntimeDefault`, read-only root FS
  where the image allows.
- Keep `.rules` and this file in sync with the live agent set.
