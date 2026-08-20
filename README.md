# 🐕 biggs.dog

> Biggs was my dog. He was the best boy and when I found out I could buy a domain with `.dog` as the extension, I migrated my homelab services to biggs.dog to honor him.

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes clusters, following Infrastructure as Code (IaC) and GitOps practices using [Flux](https://fluxcd.io/). Desired state lives in Git; Flux reconciles it into the clusters.

The homelab is split across **two clusters** (an in-progress migration — see [Architecture](#-architecture)):

- **`cluster0`** — a single-node cloud cluster on [UpCloud](https://upcloud.com/) (public WAN IP `87.58.147.51`) acting as the **edge / management plane**: public ingress, identity (Dex), VPN (NetBird), and the Talos management plane (Omni).
- **`cluster1`** — the **on-prem bare-metal workload cluster** (the original 6-node homelab): all applications, storage, GPU/AI workloads, and observability.

## 🏗️ Architecture

### GitOps with Flux

Each cluster runs its own [Flux Operator](https://fluxcd.controlplane.io/operator/) instance syncing a dedicated path on the `main` branch of this repository:

| Cluster  | Sync path            | Flux distribution | Contents                                                                 |
| -------- | -------------------- | ----------------- | ------------------------------------------------------------------------ |
| `cluster0` | `clusters/cluster0`  | Flux `2.9.0`      | Edge/mgmt: Dex, NetBird, Omni, Image Factory, cert-manager, external-secrets, Cilium, network policies |
| `cluster1` | `clusters/cluster1`  | Flux `2.9.0`      | All workloads: apps, storage, database, AI/agents, observability, etc.   |

Flux components on each cluster: Source Controller, Kustomize Controller, Helm Controller, Notification Controller.

### Repository Structure

```
clusters/
├── cluster0/                      # ⛅ UpCloud cloud edge/mgmt cluster (single node)
│   ├── flux-system/               # FluxInstance + HelmRepository/OCIRepository sources
│   └── kubernetes/apps/
│       ├── auth/dex/              # Dex OIDC IdP (root identity for edge apps)
│       ├── cert-manager/          # Certificate issuance (ACME + CA issuers)
│       ├── external-secrets/      # External Secrets + 1Password Connect
│       ├── kube-system/cilium/    # Cilium CNI (L2 announcement, single WAN IP)
│       ├── netbird/               # NetBird WireGuard VPN (road-warrior access)
│       ├── network-policies/      # CiliumNetworkPolicies (two-tier: apps + infra)
│       ├── networking/            # agentgateway (public ingress) + Cilium LB/L2
│       └── omni/
│           ├── omni/              # Sidero Omni (in-cluster Talos management plane)
│           └── image-factory/     # Talos image factory
└── cluster1/                      # 🏠 On-prem bare-metal workload cluster (6 nodes)
    ├── flux-system/               # FluxInstance + sources
    └── kubernetes/apps/
        ├── ai-system/             # vLLM + kagent agents + substrate runtime + Flux/VM/Exa MCP
        ├── auth/                  # SSO stack (Pocket ID + OAuth2 Proxy)
        ├── biggs/                 # Tribute
        ├── cert-manager/          # Certificate issuance (ACME + CA issuers)
        ├── cnpg/                  # CloudNativePG databases
        ├── dragonfly/             # Redis-compatible cache
        ├── dreamcast/             # GPU game streaming (Fenrir/Wolf + NVIDIA GPU Operator)
        ├── external-secrets/      # External Secrets + 1Password Connect
        ├── games/                 # Dedicated game servers (Windrose)
        ├── livekit/             # LiveKit SFU (WebRTC media server for MatrixRTC)
        ├── kube-system/           # Cilium (BGP), CoreDNS, NFD, GPU plugins, storage
        ├── liquidctl/             # NZXT Kraken Elite AIO fan/pump control (nv-01)
        ├── matrix/                # Continuwuity (Matrix)
        ├── media/                 # Emby, Bookboss, Ersatz, Nsyncd
        ├── mindwtr/               # Mindwtr notes PWA + self-hosted sync server
        ├── network-policies/      # Tiered CiliumNetworkPolicies (apps + infra)
        ├── networking/            # k8s-gateway, lan-dns, agentgateway (LAN + public)
        ├── observability/         # VictoriaMetrics/Logs, Grafana Operator
        ├── openebs/               # Container-attached storage
        ├── renovate/              # Automated dependency updates
        └── rook-ceph/             # Distributed storage
```

## 🖥️ Cluster Nodes

### `cluster1` — on-prem bare metal

Six bare-metal nodes managed via [Omni](https://omni.siderolabs.io/) (now run in-cluster on `cluster0` — see [Core Components](#-core-components)), all running **Talos Linux v1.13.5** with Kubernetes **v1.36.2**. This is where all workloads (and the GPU) live.

| Hostname     | Role          | CPU                                          | RAM    | GPU                                                                          |
| ------------ | ------------- | -------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `control-01` | control-plane | AMD EPYC 4564P (16C / 32T)                   | 128 GB | AMD Radeon iGPU (Raphael, `1002:164e`, unused)                               |
| `nv-01`      | worker        | AMD Ryzen 7 7800X3D (8C / 16T)              | 64 GB  | **NVIDIA GeForce RTX 5090** dGPU (32 GB, `10de:2b85`, time-sliced ×4) + AMD Radeon iGPU |
| `worker-01`  | worker        | Intel Core Ultra 5 225H (Arrow Lake-H, 14T) | 32 GB  | Intel Arc Graphics iGPU (`8086:7d51`)                                        |
| `worker-02`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-03`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-04`  | worker        | Intel Core Ultra 5 125H (Meteor Lake, 18T)  | 32 GB  | Intel Arc Graphics iGPU (`8086:7d55`)                                        |

### `cluster0` — cloud edge (UpCloud)

A single-node cluster hosted on UpCloud, exposed on the public WAN IP `87.58.147.51`. It fronts the homelab (public ingress via Cloudflare → agentgateway) and runs the identity, VPN, and Talos-management planes. Node specs are cloud-VM sized and not pinned in this repo. VIP advertisement uses a Cilium L2 announcement policy with a single-IP pool (`87.58.147.51/32`); the UpCloud Managed LB only supports TCP/HTTP (no UDP), so UDP services like NetBird STUN are exposed via `externalIPs` bound on the node's NIC instead of a LoadBalancer Service.

> **GPU notes (`cluster1`):** The Intel iGPUs are exposed to workloads via the Intel GPU device plugin for media transcoding. `nv-01`'s RTX 5090 is time-sliced into 4 `nvidia.com/gpu` replicas. vLLM (the in-cluster LLM, see [AI & Agents](#-ai--agents)) and the [Dreamcast game-streaming stack](#-dreamcast-game-streaming-stack) can't coexist on the 32 GB card (vLLM alone pins ~27–31 GB), so the [GPU Arbiter](#gpu-arbiter) scales vLLM to 0 for the duration of any gaming session and restores it after; the time-slices then serve the session's Wolf sidecar + game container plus an always-on GPU-tuning DaemonSet. The AMD integrated graphics on the two AMD nodes are present but unused (nodes run headless).

## 🔧 Core Components

### Networking

| Cluster   | Component                                                | Description                                                  |
| --------- | -------------------------------------------------------- | ------------------------------------------------------------ |
| both      | [Cilium](https://cilium.io/)                             | CNI (kube-proxy replacement). `cluster0`: L2 announcement + single-IP pool (`87.58.147.51/32`). `cluster1`: BGP peering with the UDM (ASN 64564 ↔ 64563) advertising LoadBalancer IPs from `192.168.6.6–254`. |
| `cluster1` | [k8s-gateway](https://github.com/ori-edge/k8s_gateway)   | Split-horizon DNS authoritative for `*.biggs.dog` (LB `192.168.6.6`, ClusterIP `10.105.74.41`) |
| `cluster1` | lan-dns                                                  | LAN resolver (CoreDNS, LB `192.168.6.16`): forwards `biggs.dog` → k8s-gateway (split-horizon) and everything else → NextDNS over DoT (encrypted upstream). The UDM hands out `.6.16` via per-VLAN DHCP. |
| both      | [Gateway API](https://gateway-api.sigs.k8s.io/)          | Kubernetes ingress using Gateway API                         |
| both      | [AgentGateway](https://github.com/kgateway-dev/kgateway) | Gateway API implementation; OCI charts pinned to a known-good alpha build (`0.0.0-alpha.a655af15`). |

`cluster1` DNS: LAN clients resolve `biggs.dog` via **lan-dns** (`192.168.6.16`), which forwards to k8s-gateway for internal VIPs and to NextDNS over DoT for everything else. In-cluster, **CoreDNS** (kube-dns, Talos-managed) forwards `biggs.dog` to k8s-gateway's ClusterIP (`10.105.74.41`), so pods resolve `*.biggs.dog` internally instead of hairpinning through Cloudflare. Both forward targets use the ClusterIP (not the LB VIP) to avoid a Cilium same-node LB hairpin failure when a resolver pod is co-located with k8s-gateway.

`cluster0` ingress is the `cluster0-gateway` (`networking` namespace) with HTTPS listeners for the edge hostnames `omni.biggs.dog`, `dex.biggs.dog`, and `netbird.biggs.dog` (TLS terminated with per-host certs issued in the `networking` namespace via the `letsencrypt-prod` ClusterIssuer — DNS-01/Cloudflare), plus a wildcard `*.biggs.dog` HTTP listener. Omni re-encrypts to its pod's own cert (HTTPS backend).

**Service-specific gateways:**
- **ersatz** (`cluster1`, game server): LAN-only HTTPS gateway at `ersatz.biggs.dog`

### Storage  (`cluster1`)

| Component                                                                     | Description                                  |
| ----------------------------------------------------------------------------- | -------------------------------------------- |
| [Rook-Ceph](https://rook.io/)                                                 | Distributed storage cluster                  |
| [OpenEBS](https://openebs.io/)                                                | Container attached storage                   |
| [Volsync](https://volsync.readthedocs.io/)                                    | Backup and replication of persistent volumes |
| [Snapshot Controller](https://github.com/kubernetes-csi/external-snapshotter) | CSI volume snapshots                         |
| NFS CSI Driver                                                                | NFS storage provisioner                      |
| ZFS                                                                           | ZFS volume management                        |

### Database  (`cluster1`)

| Component                                   | Description                                    |
| ------------------------------------------- | ---------------------------------------------- |
| [CloudNativePG](https://cloudnative-pg.io/) | PostgreSQL operator for in-cluster databases   |
| [Barman Cloud](https://pgbarman.org/)       | CNPG plugin for PostgreSQL backup and recovery |
| [Dragonfly](https://www.dragonflydb.io/)    | Redis-compatible in-memory datastore           |

### Security & Secrets  (both)

| Component                                                          | Description                                     |
| ------------------------------------------------------------------ | ----------------------------------------------- |
| [cert-manager](https://cert-manager.io/)                           | Certificate management with CA and ACME issuers |
| [External Secrets](https://external-secrets.io/)                   | Sync secrets from external providers            |
| [1Password Connect](https://developer.1password.com/docs/connect/) | Secret backend for External Secrets. The `connect` chart (`v2.4.1`) is deployed on **both** clusters, with its `1password-credentials.json` and API `token` shipped as **SOPS-encrypted Secrets in Git** (decrypted in-cluster by Flux's `sops-age` key), not inline chart values. |
| [SOPS](https://github.com/getsops/sops)                            | Encrypted secrets (age key). The repo-wide age key was rotated on 2026-07-04; `sops.yaml` now lists the deployed key plus a pre-staged next key. |

### Network Policies  (`cluster1` and `cluster0`)

Both clusters run a least-privilege [CiliumNetworkPolicy](https://docs.cilium.io/en/stable/security/policy/) posture. Policies live centrally in `apps/network-policies/policies/` and are wired through **two independent Flux Kustomizations** so the rollout can be staged and rolled back per-tier:

- **`cluster1`** — `network-policies-apps` (`policies/apps/`) covers lower-risk application namespaces (auth, biggs, dragonfly, games, jitsi, matrix, media, renovate). `network-policies-infra` (`policies/infra/`) covers higher-risk infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, plus a scoped `kube-system` policy covering only the Hubble relay/UI pods).
- **`cluster0`** — `network-policies-apps` covers auth (Dex), netbird, and omni. `network-policies-infra` covers networking (agentgateway), cert-manager, external-secrets, flux-system, and Cilium L2 announcement. Suspend independently with `flux suspend kustomization network-policies-infra` if the edge or control plane regresses.

### Identity & SSO

The two clusters run **different identity stacks**:

**`cluster0` (edge) — Dex** (`dex.biggs.dog`):
[Dex](https://dexidp.io/) (`v2.45.1`) is the root OIDC identity provider for the edge plane, backing Omni. It runs stateless (`storage.type: memory`) with `enablePasswordDB: true` and a static admin user; clients/secrets are templated into the config from 1Password. Config lives in `apps/auth/dex/`.

| Component                                       | Description                                                                                       |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| [Dex](https://dexidp.io/) (`cluster0`)          | Root OIDC IdP for edge apps (Omni, Image Factory). Stateless, static admin user. |
| [Pocket ID](https://github.com/pocket-id/pocket-id) (`cluster1`) | Passkey-based OIDC provider at `id.biggs.dog` (Postgres via CNPG, uploads stored in the database) |
| [OAuth2 Proxy](https://github.com/oauth2-proxy/oauth2-proxy) (`cluster1`) | OIDC client at `auth.biggs.dog`; forward-auth for apps with a shared `.biggs.dog` session cookie  |

On `cluster1`, protected apps attach an agentgateway `AgentgatewayPolicy` with `traffic.extAuth` that calls OAuth2 Proxy's `/oauth2/auth` endpoint and redirects unauthenticated users to the Pocket ID sign-in. OAuth2 Proxy uses **Dragonfly (Redis) for session storage** so the browser cookie stays a small session ticket (a cookie-based session carrying tokens grows past 4 KB, gets chunked, and didn't survive the ext-authz subrequest — causing a forward-auth redirect loop).

- **Forward-auth (`cluster1`, via OAuth2 Proxy):** Rook-Ceph dashboard, Bookboss, kagent UI, Mindwtr (browser PWA only — its `/v1` sync API stays bearer-token so CLI/mobile clients can still authenticate)
- **Native OIDC (`cluster1`, direct Pocket ID client):** Grafana

> NetBird (≥ v0.65) authenticates against its **own embedded IdP**; the `cluster0` Dex is attached to that embedded IdP as an upstream OIDC connector at runtime (NetBird dashboard → Settings → Identity Provider). The dashboard never talks to Dex directly.

### Observability  (`cluster1`)

| Component                                                       | Description                                 |
| --------------------------------------------------------------- | ------------------------------------------- |
| [Victoria Metrics](https://victoriametrics.com/)                | Metrics storage and monitoring              |
| [Victoria Logs](https://docs.victoriametrics.com/victorialogs/) | Log aggregation (includes Talos kernel logs with GPU Xid alerting) |
| [Grafana Operator](https://grafana.github.io/grafana-operator/) | Grafana deployment and dashboard management |

### System  (`cluster1`)

| Component                                                                           | Description                                                                                     |
| ----------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| [Node Feature Discovery](https://kubernetes-sigs.github.io/node-feature-discovery/) | Hardware feature detection                                                                      |
| Intel GPU Plugin                                                                    | Intel GPU device plugin for hardware acceleration                                               |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator)                       | NVIDIA device plugin with GPU time-slicing (driver/toolkit provided by Talos system extensions) |

### Edge / Management Plane  (`cluster0`)

| Component                                       | Description                                                                                          |
| ----------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| [NetBird](https://netbird.io/)                  | Zero-config WireGuard VPN for road-warrior access to the homelab. Combined server (mgmt + signal + relay + STUN + embedded IdP) at `netbird.biggs.dog` (`0.74.2`) plus a dashboard. SQLite store on a 1Gi PVC (`Recreate`). STUN/UDP 3478 exposed via `externalIPs` (`87.58.147.51`) because the UpCloud Managed LB has no UDP mode. gRPC routes use an `AgentgatewayPolicy` to force HTTP/2 backend protocol. |
|[Omni](https://omni.siderolabs.io/) (Sidero)    | In-cluster Talos management plane at `omni.biggs.dog` (`v1.10.0`): UI, machine API, Siderolink (WireGuard `:50180`), and Kubernetes-in-Kubernetes proxy. Manages the on-prem `cluster1` nodes (which phone home over Siderolink). Runs privileged with `/dev/net/tun`; double-TLS via `BackendTLSPolicy` (gateway re-encrypts to the pod's own Let's Encrypt cert using System CA trust). |
| [Talos Image Factory](https://www.talos.dev/latest/learnmore/image-factory/) | Builds and signs custom Talos Linux images with cosign. Stateless HTTP service (`ghcr.io/siderolabs/image-factory:v1.4.0`) behind an `oauth2-proxy` authenticated against Dex at `factory.biggs.dog`. |
| [Dex](https://dexidp.io/)                       | See [Identity & SSO](#identity--sso).                                                                |

### Automation

| Component                                 | Description                                                                  |
| ----------------------------------------- | ---------------------------------------------------------------------------- |
| [Renovate](https://docs.renovatebot.com/) (`cluster1`) | Automated dependency updates (HelmRelease chart versions + container images) |


## 📺 Applications  (`cluster1`)

| Category | Applications | Notes |
| -------- | ------------ | ----- |
| **Authentication** | Pocket ID, OAuth2 Proxy | Passkey-first OIDC SSO for all apps |
| **Media** | Emby, Bookboss, Ersatz, Nsyncd | Content & book management |
| **Communication** | LiveKit SFU, Continuwuity (Matrix) | WebRTC media server for MatrixRTC & messaging |
| **Task Management** | Mindwtr, mindwtr-agent | Offline PWA + self-hosted sync server; GTD agent with MCP tools |
| **Game Streaming** | Fenrir / Wolf | GPU-accelerated Moonlight streaming (see [Dreamcast](#-dreamcast-game-streaming-stack)) |
| **Game Servers** | Windrose Online | Persistent MMO on Wine backend |
| **Hardware** | liquidctl | NZXT Kraken Elite AIO fan/pump curves on `nv-01` (privileged, raw USB HID) |
| **Other** | biggs | Tribute |

Detailed app deployment configs are in `clusters/cluster1/kubernetes/apps/<namespace>/`.

## 🎮 Dreamcast Game Streaming Stack  (`cluster1`)

The `dreamcast` namespace is an on-demand, GPU-accelerated game-streaming platform built on [Games on Whales](https://games-on-whales.github.io/) Fenrir/Wolf. A [Moonlight](https://moonlight-stream.org/) client pairs with an in-cluster `moonlight-proxy`, and the `direwolf-operator` spins up a per-session pod (Wolf compositor + the app) on the NVIDIA node, encodes the desktop with NVENC, and streams it back over RTSP/RTP.

### Components

| Component | Description |
| --------- | ----------- |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) | `gpu-operator` Helm chart with `driver` and `toolkit` **disabled** — on Talos the driver ships via the `nonfree-kmod-nvidia` system extension and the container toolkit via a system extension + machine config, so the operator only runs NFD + device plugin. The single physical GPU is **time-sliced into 4 `nvidia.com/gpu` replicas**: one is held by the `nvidia-gpu-tuning` DaemonSet (below), the rest serve a session's Wolf sidecar + game container. vLLM consumes one when idle but is scaled to 0 during sessions (see [GPU Arbiter](#gpu-arbiter)). |
| [Fenrir / direwolf-operator](https://github.com/games-on-whales/fenrir) | Operator (installed from an OCI HelmRelease) that reconciles `App`/`User`/`Session`/`Pairing` CRDs and creates session pods. Fronted by `moonlight-proxy`. |
| [Wolf](https://games-on-whales.github.io/wolf/) | Per-session streaming sidecar: Wayland compositor, GStreamer + NVENC video pipeline, PulseAudio capture, and virtual input. |
| [gpu-arbiter-operator](https://github.com/shrinedogg/gpu-arbiter-operator) (custom) | controller-runtime operator that reconciles a cluster-scoped `GPUArbiter` CR: scales the `vllm` Deployment to 0 whenever an `alex-steam`/`direwolf-worker` session pod appears in `dreamcast`, and back to 1 when idle, then lifts the `gpu.biggs.dog/await-vram` scheduling gate once VRAM is free (vLLM down, DCGM free-VRAM above threshold, or a safety timeout). Replaces the original `alpine/k8s` bash loop. Without it the session and vLLM would both claim the 32 GB card and OOM. See [GPU Arbiter](#gpu-arbiter). |
| `nvidia-gpu-tuning` (DaemonSet) | Privileged DaemonSet pinned to `nv-01` running `nvidia-smi -pm 1 -lgc 0,2800 -pl 550` to cap the RTX 5090's boost clock (stock max 3105 MHz; Xid 109 CTX SWITCH TIMEOUT mitigation) and board power (stock TDP 600 W → 550 W cap); re-asserted every 5 min. Consumes one of the 4 GPU time-slices to trigger CDI injection of `nvidia-smi`. |

### GPU Arbiter

The single 32 GB RTX 5090 can't host vLLM and a gaming session at once. The [`gpu-arbiter-operator`](https://github.com/shrinedogg/gpu-arbiter-operator) reconciles a cluster-scoped `GPUArbiter` CR (`cluster1`) and:

1. **Scales vLLM** to 0 when gaming pods appear, back to 1 when idle.
2. **Lifts the scheduling gate** (`gpu.biggs.dog/await-vram`) once VRAM is freed.

**Deployment:** `apps/dreamcast/gpu-arbiter-{operator,instance}`. Image: `shrinedogg/gpu-arbiter-operator:v0.1.1`. Query status with `kubectl get gpuarbiter cluster1`.

### Defined Apps

Three gaming apps under `fenrir/app/apps.yaml`: **Firefox** (reference), **Test Ball** (synthetic videotestsrc), **Steam** (Big Picture + persistent `/home/retro` PVC + DLSS). See [NOTES.md](docs/NOTES.md#dreamcast-engineering-notes) for details.

### Forked Images

See [NOTES.md](docs/NOTES.md#forked-images) for the list of patched Dreamcast images (direwolf-operator, moonlight-proxy, wolf-agent, wolf, gpu-arbiter-operator) and why they diverge from upstream.

## 🤖 AI & Agents  (`cluster1`)

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack: an OpenAI-compatible LLM served in-cluster by [vLLM](https://github.com/vllm-project/vllm), and [kagent](https://kagent.dev/) agents that use it to inspect and troubleshoot the cluster over MCP. No inference leaves the cluster. Per-task agent routing for this repo is documented in [`.rules`](.rules).

### Components

| Component | Description |
| --------- | ----------- |
|[vLLM](https://github.com/vllm-project/vllm) | OpenAI-compatible inference server (`v0.26.0`, CUDA 12.9 for Blackwell) pinned to `nv-01`, consuming one of the RTX 5090's 4 `nvidia.com/gpu` time-slices. Scaled to 0 during [Dreamcast](#-dreamcast-game-streaming-stack) gaming sessions by the [GPU Arbiter](#gpu-arbiter) and back to 1 when idle. Serves [`rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm`](https://huggingface.co/rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm) (served as `qwen36-local`) — a **27B dense** model with a Gated-DeltaNet / gated-attention hybrid (only 16 of 64 layers keep paged KV), NVFP4 via compressed-tensors (~18 GiB resident on the 32 GB card), **192K context** (`--max-model-len=196608`; native max 262K). fp8 KV cache, `--max-num-seqs 16`, `--max-num-batched-tokens 8192`, `--gpu-memory-utilization 0.95`, `--tool-call-parser qwen3_coder` + `--reasoning-parser qwen3`, `--language-model-only` (skips the vision encoder), prefix caching enabled. The 192K cap (raised from 131K) was driven by `exa-agent` search results (~38 KB each) overflowing 131K session windows. |
| [kagent](https://kagent.dev/) | Agent framework + controller. Renders a `ModelConfig` (`qwen36-local` → local vLLM) and exposes an MCP server over a LAN-only HTTPRoute (`kagent-mcp` at `https://mcp.biggs.dog/mcp` on the internal LAN-only gateway `internal-biggs-dog`, VIP 192.168.6.15, TLS via the wildcard cert) plus a UI (`kagent.biggs.dog`) behind OAuth2 Proxy forward-auth. Backed by CNPG Postgres with pgvector for long-term (cross-session) vector memory. Embedding model: `BAAI/bge-m3` (via the `embeddings` service, CPU-only Infinity deployment). |
| **Substrate runtime** (kagent ATE / actor runtime) | A control plane for **sandboxed agent code execution via gVisor**, deployed in `ai-system` (upstream hard-codes `ate-system`, so several namespace overrides are patched in). Components: `ate-controller`, `ate-api-server` (runs a forked image `shrinedogg/ateapi` carrying a JWT-JWKS-url patch), `atelet` worker DaemonSet, and `atenet-router`. gVisor `runsc` (`20260622.0`) is staged in the rustfs `ate-snapshots` bucket and pre-cached per node via a `runsc-cache` DaemonSet (the atelet's S3 client doesn't honor `AWS_ENDPOINT_URL`, so it can't pull from rustfs directly). A `WorkerPool` (`kagent-default`, `sandboxClass: gvisor`, `ateom-gvisor:v0.0.10`) is created by the kagent chart. The controller/atenet/atelet/ateom images are at upstream `v0.0.10`; the `ate-api-server` fork must track the same base (`v0.0.10-jwksurl`, pinned by digest) — a version skew silently breaks the golden-actor wire protocol (e.g. a v0.0.7 fork makes `CreateAtespace` return `Unimplemented`; a v0.0.9 fork vs a v0.0.10 ateom surfaces as a cryptic `"string field contains invalid UTF-8"` unmarshal error), pinning the 5 SandboxAgents at `Ready=ActorTemplateNotReady`. The old atelet-namespace patch is no longer needed: v0.0.9 upstreamed it as `installdefaults.NamespaceFromPodEnv()` (reads `POD_NAMESPACE`). Defined in `apps/ai-system/substrate/` + `substrate-crds/`. |
| flux-mcp / `flux-agent` | A custom (non-chart) **read-only** kagent `Agent` wired to the Flux Operator MCP server, for GitOps inspection and reconciliation root-cause analysis. Defined in `apps/ai-system/flux-mcp/`. Per-agent memory disabled to avoid saturating the context window with large tool schemas. |
| victoria-metrics-mcp / `vm-agent` | A custom kagent `Agent` backed by the [VictoriaMetrics MCP server](https://github.com/VictoriaMetrics/mcp-victoriametrics) (`v1.20.2`): PromQL/MetricsQL query access, alerting rule inspection, TSDB cardinality analysis, embedded VM docs. Defined in `apps/ai-system/victoria-metrics-mcp/`. |
| exa-mcp / `exa-agent` | A custom kagent `Agent` backed by the [Exa MCP server](https://github.com/shrinedogg/exa-mcp-server) (`3.2.1`): web search, code discovery, company research (`web_search_exa`, `web_fetch_exa`, `web_search_advanced_exa`). Defined in `apps/ai-system/exa-mcp/`. Requires an Exa API key. Long-term memory **enabled** (with context compaction at 80K tokens); the 192K vLLM cap is what keeps large Exa result sets from overflowing. |
| codebase-memory-mcp / `codebase-agent` | A custom kagent `Agent` backed by a [codebase-memory-mcp](https://github.com/DeusData/codebase-memory-mcp) server (`v0.9.0`): structural code intelligence (tree-sitter → SQLite knowledge graph + bundled semantic search) over indexed repos — currently the **biggs.dog** repo itself, auto-synced from `main` via a git-sync native sidecar. The upstream image is stdio-only, so the pod wraps it in an `mcp-proxy` stdio→streamable-HTTP bridge (glibc binary staged into the musl bridge image via an initContainer). Defined in `apps/ai-system/codebase-memory-mcp/`. |
| mindwtr-mcp / `mindwtr-agent` | A custom kagent `Declarative` Agent backed by the Mindwtr MCP server (`mindwtr-mcp`): GTD task management with full CRUD access to the Mindwtr SQLite database. Tools include task creation, inbox processing (2-minute rule), project management, weekly reviews, and focus checks. Runs with `executeCodeBlocks` enabled for Python runtime, 30-day vector memory, and context compaction at 80K tokens. Defined in `apps/ai-system/mindwtr-mcp/`. |
| [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | SIG-Apps `Sandbox` CRD + controller (`agents.x-k8s.io`, pinned to upstream `v0.5.0`, `controller.extensions: true`). Provides isolated, stateful single-pod runtimes for classic `kind: Agent` CRs that opt into `executeCodeBlocks` (code execution). Defined in `apps/ai-system/agent-sandbox/`. |
| embeddings | CPU-only Infinity embedding server serving `BAAI/bge-m3` for kagent's long-term vector memory. Intentionally CPU-only to avoid contending with the GPU-constrained vLLM. Defined in `apps/ai-system/embeddings/`. |

**Available agents** (`kubectl get agents,sandboxagents -n ai-system`):

The 11 agents split across **two deployment patterns**:

- **Classic `kind: Agent` CRs** (invocable now via MCP): `flux-agent`, `vm-agent`, `exa-agent`, `cilium-debug-agent`, `cilium-policy-agent`, `codebase-agent`, `mindwtr-agent`. The two cilium agents are re-defined statically in `apps/ai-system/kagent/cilium-agents/` (disabled in the chart) so they carry generic `k8s_*` tools alongside Cilium tools; `codebase-agent` lives with its server in `apps/ai-system/codebase-memory-mcp/`.
- **`kind: SandboxAgent` CRs on the substrate runtime** (`apps/ai-system/kagent/substrate-agents/`): `k8s-agent`, `helm-agent`, `promql-agent`, `observability-agent`, `cilium-manager-agent`. These are `READY=True` with golden actors built, but are **not yet invocable via the MCP server** — an upstream kagent limitation (`MCPHandler.listReadyAgents` lists only `v1alpha2.Agent` and hard-codes reason `DeploymentReady`, while substrate agents report `WorkloadReady`). Use the fallbacks in [`.rules`](.rules) / direct `kubectl` until kagent wires `SandboxAgent` → A2A.
- **Disabled chart agents**: `argo-rollouts-agent`, `istio-agent`, `kgateway-agent` (plus the 5 substrate agents and 2 cilium agents are disabled in the chart so they don't double-render as classic `Agent` CRs).

See [`.rules`](.rules) for agent selection by task domain and the live invocability status.

## 🌐 Networking Configuration

### BGP Peering  (`cluster1`)

`cluster1` uses Cilium BGP to peer with the UDM router (ASN 64563, `192.168.1.1`) from Cilium's ASN 64564, advertising LoadBalancer IPs from the pool `192.168.6.6–254` (deliberately off-subnet from the nodes on `192.168.2.0/24`, so VIPs route via the UDM). This allows in-cluster services to advertise VIPs to the LAN. k8s-gateway has **fallthrough enabled** with NextDNS resolvers (`45.90.28.232` / `45.90.30.232`) so unknown `biggs.dog` names resolve to public DNS — this is how LAN/VPN clients reach cluster0 services (omni/netbird/dex at `87.58.147.51`). The default k8s-gateway forward plugin (`/etc/resolv.conf`) was replaced to avoid a DNS loop with in-cluster CoreDNS. See [NOTES.md](docs/NOTES.md#networking-stack) for details on the full networking stack (Cilium, k8s-gateway, CoreDNS, Gateway API).

### Edge Ingress  (`cluster0`)

`cluster0` advertises its single WAN IP (`87.58.147.51/32`) via a Cilium L2 announcement policy (no BGP — it's a single cloud node). Public DNS for `omni`/`dex`/`netbird`/`*.biggs.dog` resolves through Cloudflare to the `cluster0-gateway`; per-host TLS certs are issued in the `networking` namespace by the `letsencrypt-prod` ClusterIssuer (DNS-01/Cloudflare). UDP STUN (NetBird `3478`) bypasses the cloud LB via `externalIPs`.

## 🔐 Secret Management

Secrets follow a three-tier model (on both clusters):

1. **SOPS with age encryption** — Git-committed secrets (Cilium policies, app defaults, and the 1Password Connect credentials/token). The repo-wide age key was rotated on 2026-07-04; `sops.yaml` lists the deployed key plus a pre-staged next key.
2. **External Secrets + 1Password** — Runtime secrets from 1Password vaults (API keys, credentials) via 1Password Connect (`connect` chart `v2.4.1` on both clusters).
3. **cert-manager** — Automatic certificate issuance + renewal (ACME Let's Encrypt, CA issuer).

See [NOTES.md](docs/NOTES.md#security-model) for details.

## 🚀 Getting Started

### Prerequisites

- Kubernetes cluster(s)
- [Flux CLI](https://fluxcd.io/flux/cmd/)
- [SOPS](https://github.com/getsops/sops) with the age key for decryption
- 1Password Connect credentials

### Bootstrap

Each cluster bootstraps via its own Flux Operator syncing from:

```
https://github.com/shrinedogg/biggs.dog.git
```

- `cluster0` syncs `clusters/cluster0` (edge/mgmt).
- `cluster1` syncs `clusters/cluster1` (workloads).

Flux automatically reconciles each cluster's state based on the manifests in its path. Secrets are decrypted by SOPS (age key) before Flux applies them.

## 🔁 Dependency Updates

Dependency updates are managed by Renovate using the repository config in `renovate.json`.
It is set up to update Flux `HelmRelease` chart versions (HelmRepository and OCI-based sources) and container images referenced in Kubernetes manifests, including the media stack under `clusters/cluster1/kubernetes/apps/media/`.

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
