# Engineering Notes

This document contains detailed architectural decisions, engineering notes, and historical context that is less critical for operators but helpful for maintainers and contributors.

## Dreamcast Engineering Notes

### Forked Images

Getting the GPU-accelerated game streaming stack working end-to-end required forking the Games on Whales operator (`[shrinedogg/fenrir](https://github.com/shrinedogg/fenrir)`) plus several cluster-specific config decisions. Images are built locally and published to Docker Hub with semver tags.

| Image | Tag | Reason |
| ----- | --- | ------ |
| `docker.io/shrinedogg/direwolf-operator` | `v0.1.0` | Retries stream reconciliation (upstream stalls the session until the 1-minute reaper kills it whenever the agent isn't up on the first try) and prunes stale `trackedSessions` entries that spam logs. |
| `docker.io/shrinedogg/moonlight-proxy` | `v0.1.1` | Raises the `/launch` wait from 25s to 120s; a cold start (image pull + Wolf boot + agent readiness) exceeds 25s, so upstream returned 500 and the client cancelled the session. |
| `docker.io/shrinedogg/wolf-agent` | `v0.1.0` | Implements Wolf's `fake-udev` mechanism in Go: on device hotplug it writes `/run/udev/data` entries and broadcasts synthetic libudev netlink events in the pod netns so SDL/Steam detect controllers. |
| `docker.io/shrinedogg/wolf` | `v0.1.0` | Overlay on `wolf:stable` with a patched `gst-wayland-display` ([shrinedogg/gst-wayland-display](https://github.com/shrinedogg/gst-wayland-display), branch `fix/optional-wl-drm`): skips the legacy `wl_drm` global when dmabuf v4 feedback is active, fixing the wlroots/Sway nested-compositor abort. |
| `docker.io/shrinedogg/gpu-arbiter-operator` | `v0.1.1` | Go/controller-runtime port of the original bash `gpu-arbiter`; scales `vllm` to 0 during sessions and lifts the VRAM scheduling gate. v0.1.x fixed scaling to use the `deployments/scale` subresource (a backwards merge patch had emitted `replicas:null`, defaulting back to 1) and switched status writes to a full `Status().Update()` so zero-valued fields clear. |

### Defined Apps Detail

**Firebase** (reference app)
- Validates the GPU/video path end-to-end with a real browser workload.

**Test Ball** (synthetic testing)
- A `videotestsrc` pattern with no app container.
- Isolates the Wolf/NVENC encode path from actual app rendering.
- Useful for diagnosing video pipeline issues without needing a full desktop app.

**Steam** (gaming)
- Big Picture mode via Sway (lightweight Wayland compositor).
- Persistent 250Gi `host-path` PVC at `/home/retro` survives session restarts, storing login, library, and installed games.
- DLSS support under Proton (via NVIDIA wine NGX bridge DLLs restored in a separate 4Gi `nvngx-cache` PVC).

### GPU Time-Slicing & vLLM

The single RTX 5090 (32 GB) is sliced into **4 `nvidia.com/gpu` replicas**:
1. One held by `nvidia-gpu-tuning` DaemonSet (caps boost clock to mitigate Xid 109 errors).
2. One reserved for vLLM when idle (consuming ~31 GB, leaving only ~1 GB free).
3. Two for the session's Wolf sidecar + game container.

When a gaming pod spins up, the `gpu-arbiter-operator` scales vLLM to 0, freeing its slice so the session has two slices available (up to 8 GB per game pod).

### DCGM Metrics & Gate Lifting

The `gpu-arbiter-operator` removes the `gpu.biggs.dog/await-vram` scheduling gate via a three-condition precedent:

1. **vLLM down** (~1–2s latency) — the primary signal.
2. **Free VRAM threshold** (`DCGM_FI_DEV_FB_FREE` via VictoriaMetrics, ~30s lag) — the secondary signal.
3. **Safety timeout** (`spec.timeoutSeconds`, default 45s) — fallback if metrics are stale or missing.

If any condition holds, the gate lifts and the pod can schedule. This degrades gracefully: even if DCGM exporter stalls or metrics lag, the session won't hang indefinitely.

## Core Components Detail

### Networking Stack

The cluster uses:
- **Cilium** as the CNI (replaces kube-proxy), with BGP for LoadBalancer IP advertisement.
- **k8s-gateway** for split-horizon DNS: `*.biggs.dog` resolves to the internal gateway LB (`192.168.2.7`) in-cluster and to the external gateway LB (`192.168.2.6`) for LAN clients.
- **CoreDNS** patched (via Talos `inlineManifests`) to conditionally forward `biggs.dog` queries to k8s-gateway instead of Cloudflare, keeping pod traffic in-cluster.
- **Gateway API** with **AgentGateway** (OCI HelmRelease) as the ingress controller.

### Storage Layers

- **Rook-Ceph** — distributed block/object storage backed by 3 nodes.
- **OpenEBS** — local container-attached storage (ZFS and local disk).
- **Volsync** — bidirectional backup and replication of PVs (e.g., game data, media libraries).
- **NFS CSI** — NFS provisioner for shared namespaces.
- **ZFS** — volume management on nodes with ZFS pools.

### Database & Caching

- **CNPG** — PostgreSQL operator managing the Postgres cluster (used by Pocket ID, kagent, and others).
- **Barman Cloud** — CNPG plugin for backup/recovery to object storage.
- **Dragonfly** — Redis-compatible in-memory store (used by OAuth2 Proxy for session storage and other services).

### Security Model

Secrets follow a three-tier model:

1. **SOPS + age** — Git-encrypted secrets (for config that can be committed, e.g., Cilium policies, app defaults).
2. **External Secrets + 1Password** — Runtime secrets synced from 1Password vaults (for API keys, credentials).
3. **cert-manager** — Automatic certificate issuance and renewal (ACME Let's Encrypt, CA issuer for self-signed).

### Network Policies

The cluster enforces least-privilege **CiliumNetworkPolicy** across all namespaces. Policies are split into two independent Flux Kustomizations:

- **`network-policies-apps`** — lower-risk application namespaces (affine, auth, biggs, dragonfly, games, jitsi, manticore, matrix, media, renovate). Can be updated with confidence.
- **`network-policies-infra`** — higher-risk infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, kube-system). Can be suspended independently with `flux suspend kustomization network-policies-infra` if edge or control plane regresses.

This two-tier approach allows staged rollouts and rapid rollback without affecting application policies.

### Identity & SSO Details

**Pocket ID** (`id.biggs.dog`):
- Passkey-first OIDC provider (FIDO2 WebAuthn).
- Postgres backend via CNPG (user database, secret storage).
- File uploads stored in the same database.

**OAuth2 Proxy** (`auth.biggs.dog`):
- OIDC client to Pocket ID.
- Provides forward-auth for browser apps (agentgateway `AgentgatewayPolicy` with `traffic.extAuth`).
- Uses **Dragonfly (Redis)** for session storage (small session ticket instead of large cookie).
- Protected apps attach a `ReferenceGrant` to reach the OAuth2 Proxy service in the `auth` namespace.

**Protected apps:**
- Rook-Ceph dashboard
- Bookboss
- kagent UI

**Native OIDC apps:**
- Grafana (direct Pocket ID client, no forward-auth needed)

### Observability Stack

- **VictoriaMetrics** — metrics storage (time-series database optimized for Prometheus protocol).
- **Victoria Logs** — log aggregation and storage.
- **Grafana Operator** — Grafana deployment and dashboard management (dashboards stored as CRDs).

The DCGM exporter (NVIDIA GPU metrics) feeds into VictoriaMetrics, and the `gpu-arbiter-operator` queries it via the VictoriaMetrics HTTP API.

### System & Hardware

- **NFD** (Node Feature Discovery) — detects hardware capabilities (GPU models, CPU flags, etc.) and labels nodes.
- **Intel GPU Plugin** — enables Intel iGPU device plugin for media transcoding on worker nodes.
- **NVIDIA GPU Operator** — device plugin with time-slicing (driver/toolkit provided by Talos system extensions, not by the operator).

### Automation

- **Renovate** — automated dependency updates for HelmRelease chart versions and container images referenced in Kubernetes manifests. Configured in `renovate.json`.

## AI & Agents Architecture

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack. The vLLM and kagent infrastructure is shared; agent-specific configs are in `.rules`.

### vLLM Deployment

- **Model**: `nvidia/Qwen3.6-35B-A3B-NVFP4` (35B MoE, ~3B active parameters, **262K context** with Mamba-hybrid attention).
- **Quant**: NVIDIA **NVFP4** (native Blackwell FP4 tensor core support, ~19B on disk).
- **GPU**: One of the RTX 5090's 4 time-slices (~8 GB per slice, vLLM pins ~31 GB, one per session games at ~1–2 GB).
- **Scaling**: Idle = 1 replica; gaming session = 0 replicas (managed by `gpu-arbiter-operator`).
- **API**: OpenAI-compatible (`/v1/chat/completions`, etc.) at `http://vllm.ai-system.svc:8000`.

### kagent Agents

**Available agents** (`kubectl get agents -n ai-system`):
- `k8s-agent` — general Kubernetes inspection/troubleshooting.
- `observability-agent` — metrics, dashboards, alerting.
- `promql-agent` — PromQL query generation.
- `helm-agent` — Helm release management.
- `flux-agent` — Flux GitOps inspection (custom, read-only, defined in `apps/ai-system/flux-mcp/`).
- `vm-agent` — VictoriaMetrics query + TSDB analysis (custom, defined in `apps/ai-system/victoria-metrics-mcp/`).
- `cilium-manager-agent` — Cilium install/config/upgrade.
- `cilium-debug-agent` — Cilium diagnosis.
- `cilium-policy-agent` — Cilium policy authoring.

Disabled agents (chart toggles): `argo-rollouts-agent`, `istio-agent`, `kgateway-agent`.

Agent selection is documented in [`.rules`](.rules); each agent has a specific domain and preferred MCP server.

### Agent Sandbox

The cluster runs **SIG-Apps `Sandbox`** CRD + controller (`agents.x-k8s.io`, pinned to `v0.4.6` with `controller.extensions: true`), which provides isolated, stateful single-pod runtimes for agents that opt into `executeCodeBlocks`. All agents are configured with this enabled.

### Long-Term Memory

kagent is configured with vectorized memory (long-term, cross-session) backed by CNPG Postgres + pgvector. The 131K context window easily absorbs tool schemas + memory + conversation (~20% KV cache peak under load).

### MCP Servers

- **Flux Operator MCP** (`flux-agent`) — read-only inspection of `FluxInstance`, sources, Kustomizations, HelmReleases, ResourceSets.
- **VictoriaMetrics MCP** (`vm-agent`) — PromQL/MetricsQL queries, alerting rules, TSDB cardinality analysis, embedded VM docs.
- **Kubernetes API** (all agents) — native k8s API via controller-runtime client.

## Cluster Bootstrapping

The cluster bootstraps via **Flux Operator** syncing from `https://github.com/shrinedogg/biggs.dog.git` (main branch). Flux automatically reconciles the cluster state based on manifests in `clusters/cluster0/`:

1. **FluxInstance** (Flux system components).
2. **Sources** (GitRepository, HelmRepository, OCIRepository).
3. **Kustomizations** and **HelmReleases** (ordered via `dependsOn`).

Secrets are decrypted by SOPS (age key) before Flux applies them.

## Dependency Update Workflow

Renovate scans the repo for:
- `HelmRelease` chart versions (with source URLs).
- Container image tags referenced in Kubernetes manifests.
- `renovate.json` config (grouping, scheduling, etc.).

On a match, Renovate opens a PR with updated versions. CI validates the changes, and once merged, Flux reconciles automatically.

## Common Pitfalls & Lessons Learned

### GPU Scaling

- **Don't use JSON merge patch for zero-valued fields** — `omitempty` drops zero values, so status fields like `gamePods: 0` won't persist. Use `Status().Update()` for authoritative writes.
- **Use the `deployments/scale` subresource** — cleaner than a full deployment patch, matches RBAC grants, and avoids null-value bugs.
- **vLLM Deployment intentionally omits `spec.replicas`** — defaults to 1, so Flux doesn't fight the arbiter over the count.

### Fenrir/Games on Whales

- **Labels on pod templates don't survive** — Fenrir strips `metadata.labels` from the App CR templates. Live pods get labels from Fenrir's generated selectors, not the CR.
- **Cold start latency** — image pulls + Wolf boot + agent readiness can exceed 25s, so moonlight-proxy timeout needed to be raised to 120s.
- **Controller retries** — the direwolf-operator was stalling on reconcile retries; the fork adds automatic retries and prunes stale session entries.

### Networking

- **CoreDNS patching for split-horizon DNS** — hairpinning traffic out through the external gateway wastes bandwidth. Patching CoreDNS to forward `biggs.dog` queries to k8s-gateway keeps pods in-cluster.
- **CiliumNetworkPolicy learning curve** — start with permissive policies and tighten incrementally. Two-tier (apps + infra) allows staged rollouts.

### Observability

- **DCGM metrics lag** — free VRAM reports ~30s behind actual consumption. The `gpu-arbiter-operator` gates on vLLM down first, then VRAM as a secondary signal.
- **Victoria Metrics cardinality** — high cardinality metrics (e.g., per-pod ephemeral metrics) can blow up storage and query times. Use recording rules and aggregation.

### Secrets

- **Don't hardcode secrets** — use SOPS + age for Git-stored secrets, and External Secrets + 1Password for runtime-only secrets.
- **Session storage** — OAuth2 Proxy's session cookie can exceed 4 KB and get chunked, breaking ext-authz subrequests. Use Dragonfly (Redis) to store the session server-side and reduce the cookie to a small ticket.

## Future Improvements

- **Cilium Egress Gateway** — route outbound traffic through a dedicated node to stabilize external IPs (useful for services that block by IP).
- **Distributed Tracing** — add Jaeger or Tempo for end-to-end tracing across kafka, game streaming, and agent operations.
- **GPU Metrics Dashboard** — Grafana dashboard for DCGM metrics, game session lifecycle, vLLM scaling events.
- **Multi-cluster Flux** — expand to manage additional clusters (e.g., edge nodes) from a central repo.
