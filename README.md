# 🐕 biggs.dog

> Biggs was my dog. He was the best boy and when I found out I could buy a domain with `.dog` as the extension, I migrated my homelab services to biggs.dog to honor him.

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes cluster, following Infrastructure as Code (IaC) and GitOps practices using [Flux](https://fluxcd.io/).

## 🏗️ Architecture

### GitOps with Flux

The cluster is managed by [Flux Operator](https://fluxcd.controlplane.io/operator/) syncing from the `main` branch of this repository. Flux components include:

- Source Controller
- Kustomize Controller
- Helm Controller
- Notification Controller

### Repository Structure

```
clusters/
└── cluster0/
    ├── flux-system/          # Flux instance and Helm/OCI sources
    │   ├── flux-instance.yaml
    │   └── sources/          # HelmRepository and OCIRepository definitions
    └── kubernetes/
        └── apps/             # Application deployments
            ├── affine/
            ├── ai-system/         # Local LLM (vLLM) + kagent agents + Flux MCP
            ├── auth/              # SSO stack (Pocket ID + OAuth2 Proxy)
            ├── biggs/
            ├── cert-manager/
            ├── cnpg/
            ├── dragonfly/
            ├── dreamcast/         # GPU game streaming (Fenrir/Wolf + NVIDIA GPU Operator)
            ├── external-secrets/
            ├── games/             # Dedicated game servers (Windrose)
            ├── jitsi/
            ├── kube-system/
            ├── manticore/
            ├── matrix/
            ├── media/
            ├── network-policies/    # Tiered Cilium NetworkPolicies (apps + infra)
            ├── networking/
            ├── observability/
            ├── openebs/
            ├── renovate/
            └── rook-ceph/
```

## 🖥️ Cluster Nodes

Six bare-metal nodes managed via [Omni](https://omni.siderolabs.io/), all running **Talos Linux v1.13.5** with Kubernetes **v1.36.2**.

| Hostname     | Role          | CPU                                          | RAM    | GPU                                                                          |
| ------------ | ------------- | -------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `control-01` | control-plane | AMD EPYC 4564P (16C / 32T)                   | 128 GB | AMD Radeon iGPU (Raphael, `1002:164e`, unused)                               |
| `nv-01`      | worker        | AMD Ryzen 7 7800X3D (8C / 16T)              | 64 GB  | **NVIDIA GeForce RTX 5090** dGPU (32 GB, `10de:2b85`, time-sliced ×4) + AMD Radeon iGPU |
| `worker-01`  | worker        | Intel Core Ultra 5 225H (Arrow Lake-H, 14T) | 32 GB  | Intel Arc Graphics iGPU (`8086:7d51`)                                        |
| `worker-02`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-03`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-04`  | worker        | Intel Core Ultra 5 125H (Meteor Lake, 18T)  | 32 GB  | Intel Arc Graphics iGPU (`8086:7d55`)                                        |

> **GPU notes:** The Intel iGPUs are exposed to workloads via the Intel GPU device plugin for media transcoding. `nv-01`'s RTX 5090 is time-sliced into 4 `nvidia.com/gpu` replicas. vLLM (the in-cluster LLM, see [AI & Agents](#-ai--agents)) and the [Dreamcast game-streaming stack](#-dreamcast-game-streaming-stack) can't coexist on the 32 GB card (vLLM alone pins ~31 GB), so the [GPU Arbiter](#gpu-arbiter) scales vLLM to 0 for the duration of any gaming session and restores it after; the time-slices then serve the session's Wolf sidecar + game container plus an always-on GPU-tuning DaemonSet. The AMD integrated graphics on the two AMD nodes are present but unused (nodes run headless).

## 🔧 Core Components

### Networking


| Component                                                | Description                                                  |
| -------------------------------------------------------- | ------------------------------------------------------------ |
| [Cilium](https://cilium.io/)                             | CNI (kube-proxy replacement) with BGP for LoadBalancer IPs   |
| [k8s-gateway](https://github.com/ori-edge/k8s_gateway)   | Split-horizon DNS authoritative for `*.biggs.dog` (LB `192.168.2.6`) |
| [Gateway API](https://gateway-api.sigs.k8s.io/)          | Kubernetes ingress using Gateway API                         |
| [AgentGateway](https://github.com/kgateway-dev/kgateway) | Gateway API implementation installed from OCI charts         |

The UDM router conditionally forwards `biggs.dog` to k8s-gateway for LAN clients. In-cluster, **CoreDNS** is patched (via Talos `inlineManifests`) to conditionally forward `biggs.dog` to k8s-gateway as well, so pods resolve `*.biggs.dog` to the internal gateway LB (`192.168.2.7`) and stay in-cluster instead of hairpinning out through Cloudflare.


### Storage


| Component                                                                     | Description                                  |
| ----------------------------------------------------------------------------- | -------------------------------------------- |
| [Rook-Ceph](https://rook.io/)                                                 | Distributed storage cluster                  |
| [OpenEBS](https://openebs.io/)                                                | Container attached storage                   |
| [Volsync](https://volsync.readthedocs.io/)                                    | Backup and replication of persistent volumes |
| [Snapshot Controller](https://github.com/kubernetes-csi/external-snapshotter) | CSI volume snapshots                         |
| NFS CSI Driver                                                                | NFS storage provisioner                      |
| ZFS                                                                           | ZFS volume management                        |


### Database


| Component                                   | Description                                    |
| ------------------------------------------- | ---------------------------------------------- |
| [CloudNativePG](https://cloudnative-pg.io/) | PostgreSQL operator for in-cluster databases   |
| [Barman Cloud](https://pgbarman.org/)       | CNPG plugin for PostgreSQL backup and recovery |
| [Dragonfly](https://www.dragonflydb.io/)    | Redis-compatible in-memory datastore           |


### Security & Secrets


| Component                                                          | Description                                     |
| ------------------------------------------------------------------ | ----------------------------------------------- |
| [cert-manager](https://cert-manager.io/)                           | Certificate management with CA and ACME issuers |
| [External Secrets](https://external-secrets.io/)                   | Sync secrets from external providers            |
| [1Password Connect](https://developer.1password.com/docs/connect/) | Secret backend for External Secrets             |
| [SOPS](https://github.com/getsops/sops)                            | Encrypted secrets (age key)                     |


### Network Policies

The cluster runs a least-privilege [CiliumNetworkPolicy](https://docs.cilium.io/en/stable/security/policy/) posture. Policies live centrally in `apps/network-policies/policies/` and are wired through **two independent Flux Kustomizations** so the rollout can be staged and rolled back per-tier:

- **`network-policies-apps`** (`policies/apps/`) — lower-risk application namespaces (affine, auth, biggs, dragonfly, games, jitsi, manticore, matrix, media, renovate).
- **`network-policies-infra`** (`policies/infra/`) — higher-risk infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, plus a scoped `kube-system` policy covering only the Hubble relay/UI pods). Suspend independently with `flux suspend kustomization network-policies-infra` if the edge or control plane regresses.

### Identity & SSO

The `auth` namespace provides single sign-on for the cluster. [Pocket ID](https://github.com/pocket-id/pocket-id) is a passkey-first OIDC provider, and [OAuth2 Proxy](https://github.com/oauth2-proxy/oauth2-proxy) acts as its OIDC client to gate browser apps.


| Component                                                       | Description                                                                                                  |
| -------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| [Pocket ID](https://github.com/pocket-id/pocket-id)            | Passkey-based OIDC provider at `id.biggs.dog` (Postgres via CNPG, uploads stored in the database)            |
| [OAuth2 Proxy](https://github.com/oauth2-proxy/oauth2-proxy)   | OIDC client at `auth.biggs.dog`; provides forward-auth for apps with a shared `.biggs.dog` session cookie    |

Protected apps attach an agentgateway `AgentgatewayPolicy` with `traffic.extAuth` that calls OAuth2 Proxy's `/oauth2/auth` endpoint (Envoy ext-authz compatible) and redirects unauthenticated users to the Pocket ID sign-in. A cross-namespace `ReferenceGrant` lets each app's policy reach the OAuth2 Proxy service in the `auth` namespace.

OAuth2 Proxy uses **Dragonfly (Redis) for session storage** so the browser cookie stays a small session ticket. A cookie-based session carrying the access/id/refresh tokens grows past 4 KB and gets chunked, and that large cookie didn't survive the ext-authz subrequest to `/oauth2/auth` — causing a forward-auth redirect loop. A NetworkPolicy authorizes the `auth` namespace to reach `dragonfly-db:6379`.

- **Forward-auth (via OAuth2 Proxy):** Rook-Ceph dashboard, Bookboss, kagent UI
- **Native OIDC (direct Pocket ID client):** Grafana


### Observability


| Component                                                       | Description                                 |
| --------------------------------------------------------------- | ------------------------------------------- |
| [Victoria Metrics](https://victoriametrics.com/)                | Metrics storage and monitoring              |
| [Victoria Logs](https://docs.victoriametrics.com/victorialogs/) | Log aggregation                             |
| [Grafana Operator](https://grafana.github.io/grafana-operator/) | Grafana deployment and dashboard management |


### System


| Component                                                                           | Description                                                                                     |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [Node Feature Discovery](https://kubernetes-sigs.github.io/node-feature-discovery/) | Hardware feature detection                                                                      |
| Intel GPU Plugin                                                                    | Intel GPU device plugin for hardware acceleration                                               |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator)                       | NVIDIA device plugin with GPU time-slicing (driver/toolkit provided by Talos system extensions) |


### Automation


| Component                                 | Description                                                                  |
| ----------------------------------------- | ---------------------------------------------------------------------------- |
| [Renovate](https://docs.renovatebot.com/) | Automated dependency updates (HelmRelease chart versions + container images) |


## 📺 Applications

| Category | Applications | Notes |
| -------- | ------------ | ----- |
| **Authentication** | Pocket ID, OAuth2 Proxy | Passkey-first OIDC SSO for all apps |
| **Media** | Emby, Bookboss, Ersatz, Nsyncd | Content & book management |
| **Communication** | Jitsi Meet, Continuwuity (Matrix) | Video conferencing & messaging |
| **Productivity** | AFFiNE, Manticore Search | Collaborative workspace + full-text search |
| **Game Streaming** | Fenrir / Wolf | GPU-accelerated Moonlight streaming (see [Dreamcast](#-dreamcast-game-streaming-stack)) |
| **Game Servers** | Windrose Online | Persistent MMO on Wine backend |
| **Other** | biggs | Tribute |

Detailed app deployment configs are in `clusters/cluster0/kubernetes/apps/<namespace>/`.

## 🎮 Dreamcast Game Streaming Stack

The `dreamcast` namespace is the newest addition to the cluster: an on-demand, GPU-accelerated game-streaming platform built on [Games on Whales](https://games-on-whales.github.io/) Fenrir/Wolf. A [Moonlight](https://moonlight-stream.org/) client pairs with an in-cluster `moonlight-proxy`, and the `direwolf-operator` spins up a per-session pod (Wolf compositor + the app) on the NVIDIA node, encodes the desktop with NVENC, and streams it back over RTSP/RTP.

### Components


| Component | Description |
| --------- | ----------- |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) | `gpu-operator` Helm chart with `driver` and `toolkit` **disabled** — on Talos the driver ships via the `nonfree-kmod-nvidia` system extension and the container toolkit via a system extension + machine config, so the operator only runs NFD + device plugin. The single physical GPU is **time-sliced into 4 `nvidia.com/gpu` replicas**: one is held by the `nvidia-gpu-tuning` DaemonSet (below), the rest serve a session's Wolf sidecar + game container. vLLM consumes one when idle but is scaled to 0 during sessions (see [GPU Arbiter](#gpu-arbiter)). |
| [Fenrir / direwolf-operator](https://github.com/games-on-whales/fenrir) | Operator (installed from an OCI HelmRelease) that reconciles `App`/`User`/`Session`/`Pairing` CRDs and creates session pods. Fronted by `moonlight-proxy`. |
| [Wolf](https://games-on-whales.github.io/wolf/) | Per-session streaming sidecar: Wayland compositor, GStreamer + NVENC video pipeline, PulseAudio capture, and virtual input. |
| [gpu-arbiter-operator](https://github.com/shrinedogg/gpu-arbiter-operator) (custom) | controller-runtime operator that reconciles a cluster-scoped `GPUArbiter` CR: scales the `vllm` Deployment to 0 whenever an `alex-steam`/`direwolf-worker` session pod appears in `dreamcast`, and back to 1 when idle, then lifts the `gpu.biggs.dog/await-vram` scheduling gate once VRAM is free (vLLM down, DCGM free-VRAM above threshold, or a safety timeout). Replaces the original `alpine/k8s` bash loop. Without it the session and vLLM would both claim the 32 GB card and OOM. See [GPU Arbiter](#gpu-arbiter). |
| `nvidia-gpu-tuning` (DaemonSet) | Privileged DaemonSet pinned to `nv-01` running `nvidia-smi -pm 1 -lgc 0,2800` to cap the RTX 5090's boost clock (stock max 3105 MHz), mitigating recurring Xid 109 (CTX SWITCH TIMEOUT) errors under gaming load; re-asserted every 5 min. Consumes one of the 4 GPU time-slices to trigger CDI injection of `nvidia-smi`. |


### GPU Arbiter

The single 32 GB RTX 5090 can't host vLLM and a gaming session at once. The [`gpu-arbiter-operator`](https://github.com/shrinedogg/gpu-arbiter-operator) reconciles a cluster-scoped `GPUArbiter` CR (`cluster0`) and:

1. **Scales vLLM** to 0 when gaming pods appear, back to 1 when idle.
2. **Lifts the scheduling gate** (`gpu.biggs.dog/await-vram`) once VRAM is freed.

**Deployment:** `apps/dreamcast/gpu-arbiter-{operator,instance}`. Image: `shrinedogg/gpu-arbiter-operator:v0.1.1`. Query status with `kubectl get gpuarbiter cluster0`.


### Defined Apps

Three gaming apps under `fenrir/app/apps.yaml`: **Firefox** (reference), **Test Ball** (synthetic videotestsrc), **Steam** (Big Picture + persistent `/home/retro` PVC + DLSS). See [NOTES.md](NOTES.md#dreamcast-engineering-notes) for details.

### Forked Images

See [NOTES.md](NOTES.md#forked-images) for the list of patched Dreamcast images (direwolf-operator, moonlight-proxy, wolf-agent, wolf, gpu-arbiter-operator) and why they diverge from upstream.


## 🤖 AI & Agents

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack: an OpenAI-compatible LLM served in-cluster by [vLLM](https://github.com/vllm-project/vllm), and [kagent](https://kagent.dev/) agents that use it to inspect and troubleshoot the cluster over MCP. No inference leaves the cluster. Per-task agent routing for this repo is documented in [`.rules`](.rules).

### Components

| Component | Description |
| --------- | ----------- |
| [vLLM](https://github.com/vllm-project/vllm) | OpenAI-compatible inference server pinned to `nv-01`, consuming one of the RTX 5090's 4 `nvidia.com/gpu` time-slices (v0.23.0). Scaled to 0 during [Dreamcast](#-dreamcast-game-streaming-stack) gaming sessions by the [GPU Arbiter](#gpu-arbiter) (the 32 GB card can't fit vLLM and a session at once) and back to 1 when idle. Serves [`nvidia/Qwen3.6-35B-A3B-NVFP4`](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4) — NVIDIA's ModelOpt **NVFP4** quant of Qwen3.6-35B-A3B: a 35B MoE (~3B active), ~19B on disk, **131K context** (native max 262K) with Mamba-hybrid attention, running on the 5090's native Blackwell FP4 tensor cores. |
| [kagent](https://kagent.dev/) | Agent framework + controller. Renders a default `ModelConfig` pointing at the local vLLM, runs the built-in agents, and exposes an MCP server over a LAN-only Cilium LoadBalancer (`kagent-mcp-lan` at `http://192.168.2.13:8083/mcp`, pinned via `io.cilium/lb-ipam-ips` -- the gateway path was abandoned after it mangled the `/mcp` Streamable-HTTP path) plus a UI (`kagent.biggs.dog`) behind OAuth2 Proxy forward-auth. Backed by CNPG Postgres with pgvector for long-term (cross-session) vector memory. Embedding model: `BAAI/bge-m3` (via the `embeddings` service, CPU-only Infinity deployment). |
| flux-mcp / `flux-agent` | A custom (non-chart) **read-only** kagent `Agent` wired to the Flux Operator MCP server, for GitOps inspection and reconciliation root-cause analysis. Defined in `apps/ai-system/flux-mcp/`. Per-agent memory disabled to avoid exceeding the 131K context window with large tool schemas. |
| victoria-metrics-mcp / `vm-agent` | A custom kagent `Agent` backed by the [VictoriaMetrics MCP server](https://github.com/VictoriaMetrics/mcp-victoriametrics) (`v1.20.2`), providing direct PromQL/MetricsQL query access, alerting rule inspection, TSDB cardinality analysis, and embedded VM documentation search. Defined in `apps/ai-system/victoria-metrics-mcp/`. |
| [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | SIG-Apps `Sandbox` CRD + controller (`agents.x-k8s.io`, pinned to upstream `v0.4.6`, installed with `controller.extensions: true` so `SandboxTemplate`/`SandboxClaim`/`SandboxWarmPool` are also registered). Provides isolated, stateful single-pod runtimes for agents that opt into `executeCodeBlocks` (code execution). Enabled on all built-in agents. Defined in `apps/ai-system/agent-sandbox/`. |
| embeddings | CPU-only Infinity embedding server serving `BAAI/bge-m3` model for kagent's long-term vector memory. Intentionally CPU-only to avoid contending with the GPU-constrained vLLM during gaming. Defined in `apps/ai-system/embeddings/`. |

**Available agents** (`kubectl get agents -n ai-system`):
- **Chart-managed**: `k8s-agent`, `observability-agent`, `promql-agent`, `helm-agent`, `cilium-manager-agent`.
- **Custom (non-chart)**: `flux-agent`, `vm-agent`, `cilium-debug-agent`, `cilium-policy-agent`.
- **Disabled chart agents**: `argo-rollouts-agent`, `istio-agent`, `kgateway-agent`.

See [`.rules`](.rules) for agent selection by task domain.

## 🌐 Networking Configuration

### BGP Peering

The cluster uses Cilium BGP to peer with the UDM router (ASN 64563, 192.168.1.1) from Cilium's ASN 64564, advertising LoadBalancer IPs from the pool `192.168.2.6–254`. This allows in-cluster services to reach external networks and vice versa. See [NOTES.md](NOTES.md#networking-stack) for details on the full networking stack (Cilium, k8s-gateway, CoreDNS, Gateway API).

## 🔐 Secret Management

Secrets follow a three-tier model:

1. **SOPS with age encryption** — Git-committed secrets (Cilium policies, app defaults).
2. **External Secrets + 1Password** — Runtime secrets from 1Password vaults (API keys, credentials).
3. **cert-manager** — Automatic certificate issuance + renewal (ACME Let's Encrypt, CA issuer).

See [NOTES.md](NOTES.md#secret-model) for details.

## 🚀 Getting Started

### Prerequisites

- Kubernetes cluster
- [Flux CLI](https://fluxcd.io/flux/cmd/)
- [SOPS](https://github.com/getsops/sops) with age key for decryption
- 1Password Connect credentials

### Bootstrap

The cluster bootstraps via Flux Operator syncing from:

```
https://github.com/shrinedogg/biggs.dog.git
```

Flux will automatically reconcile the cluster state based on the manifests in `clusters/cluster0/`.

## 🔁 Dependency Updates

Dependency updates are managed by Renovate using the repository config in `renovate.json`.
It is set up to update Flux `HelmRelease` chart versions (HelmRepository and OCI-based sources) and container images referenced in Kubernetes manifests, including the media stack under `clusters/cluster0/kubernetes/apps/media/`.

## 📁 App Structure Pattern

Each application follows a consistent pattern:

```
<namespace>/
├── kustomization.yaml    # Namespace-level kustomization
├── namespace.yaml        # Namespace definition
└── <app>/
    ├── ks.yaml           # Flux Kustomization
    └── app/
        └── helmrelease.yaml (or raw manifests)
```

## 📝 License

Personal homelab configuration - feel free to use as reference.
