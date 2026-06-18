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
            ├── jitsi/
            ├── kube-system/
            ├── manticore/
            ├── matrix/
            ├── media/
            ├── networking/
            ├── observability/
            ├── openebs/
            ├── renovate/
            └── rook-ceph/
```

## 🖥️ Cluster Nodes

Six bare-metal nodes managed via [Omni](https://omni.siderolabs.io/), all running **Talos Linux v1.13.4** (kernel `6.18.34-talos`, `amd64`) with Kubernetes **v1.36.2**.

| Hostname     | Role          | CPU                                          | RAM    | GPU                                                                          |
| ------------ | ------------- | -------------------------------------------- | ------ | ---------------------------------------------------------------------------- |
| `control-01` | control-plane | AMD EPYC 4564P (16C / 32T)                   | 128 GB | AMD Radeon iGPU (Raphael, `1002:164e`, unused)                               |
| `nv-01`      | worker        | AMD Ryzen 7 7800X3D (8C / 16T)              | 64 GB  | **NVIDIA GeForce RTX 5090** dGPU (32 GB, `10de:2b85`, time-sliced ×4) + AMD Radeon iGPU |
| `worker-01`  | worker        | Intel Core Ultra 5 225H (Arrow Lake-H, 14T) | 32 GB  | Intel Arc Graphics iGPU (`8086:7d51`)                                        |
| `worker-02`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-03`  | worker        | Intel Core i7-1360P (Raptor Lake-P, 16T)    | 32 GB  | Intel Iris Xe Graphics iGPU (`8086:a7a0`)                                    |
| `worker-04`  | worker        | Intel Core Ultra 5 125H (Meteor Lake, 18T)  | 32 GB  | Intel Arc Graphics iGPU (`8086:7d55`)                                        |

> **GPU notes:** The Intel iGPUs are exposed to workloads via the Intel GPU device plugin for media transcoding. `nv-01`'s RTX 5090 is time-sliced into 4 `nvidia.com/gpu` replicas shared between the [Dreamcast game-streaming stack](#-dreamcast-game-streaming-stack) and the in-cluster LLM (vLLM/kagent, see [AI & Agents](#-ai--agents)). The AMD integrated graphics on the two AMD nodes are present but unused (nodes run headless).

## 🔧 Core Components

### Networking


| Component                                                | Description                                            |
| -------------------------------------------------------- | ------------------------------------------------------ |
| [Cilium](https://cilium.io/)                             | CNI with BGP support for LoadBalancer IP advertisement |
| [k8s-gateway](https://github.com/ori-edge/k8s_gateway)   | DNS for Kubernetes services                            |
| [Gateway API](https://gateway-api.sigs.k8s.io/)          | Kubernetes ingress using Gateway API                   |
| [AgentGateway](https://github.com/kgateway-dev/kgateway) | Gateway API implementation installed from OCI charts   |
| [Cloudflared](https://github.com/cloudflare/cloudflared) | Cloudflare Tunnel for external access                  |


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

### Authentication

- **Pocket ID** - Passkey-first OIDC identity provider (`id.biggs.dog`)
- **OAuth2 Proxy** - Forward-auth / SSO gateway for browser apps (`auth.biggs.dog`)

### Media Stack

- **Emby** - Media server
- **Bookboss** - Book management
- **Ersatz** - Custom media service
- **Nsyncd** - Synchronization service

### Communication

- **Jitsi Meet** - Self-hosted video conferencing
- **Continuwuity** - Matrix homeserver (Conduwuit fork)

### Productivity

- **AFFiNE** - Collaborative knowledge base and workspace
- **Manticore Search** - Full-text search engine (used by AFFiNE)

### Game Streaming

- **Fenrir / Wolf** - GPU-accelerated game streaming to [Moonlight](https://moonlight-stream.org/) clients (Firefox, Steam Big Picture, a test pattern). See [Dreamcast Game Streaming Stack](#-dreamcast-game-streaming-stack) below.

### Other

- **biggs** - Biggs the dog.

## 🎮 Dreamcast Game Streaming Stack

The `dreamcast` namespace is the newest addition to the cluster: an on-demand, GPU-accelerated game-streaming platform built on [Games on Whales](https://games-on-whales.github.io/) Fenrir/Wolf. A [Moonlight](https://moonlight-stream.org/) client pairs with an in-cluster `moonlight-proxy`, and the `direwolf-operator` spins up a per-session pod (Wolf compositor + the app) on the NVIDIA node, encodes the desktop with NVENC, and streams it back over RTSP/RTP.

### Components


| Component                                                               | Description                                                                                                                                                                                                                                                                                                                                                                                                                       |
| ----------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator)           | `gpu-operator` Helm chart with `driver` and `toolkit` **disabled** — on Talos the driver ships via the `nonfree-kmod-nvidia` system extension and the container toolkit via a system extension + machine config, so the operator only runs NFD + device plugin. The single physical GPU is **time-sliced into 4 `nvidia.com/gpu` replicas** so each session can give one slice to the Wolf sidecar and one to the game container. |
| [Fenrir / direwolf-operator](https://github.com/games-on-whales/fenrir) | Operator (installed from an OCI HelmRelease) that reconciles `App`/`User`/`Session`/`Pairing` CRDs and creates session pods. Fronted by `moonlight-proxy`.                                                                                                                                                                                                                                                                        |
| [Wolf](https://games-on-whales.github.io/wolf/)                         | Per-session streaming sidecar: Wayland compositor, GStreamer + NVENC video pipeline, PulseAudio capture, and virtual input.                                                                                                                                                                                                                                                                                                       |


### Defined Apps (`fenrir/app/apps.yaml`)

- **Firefox** — reference app, validates the GPU/video path.
- **Test Ball** — synthetic `videotestsrc` pattern with no app container; isolates the Wolf/NVENC encode path from app rendering.
- **Steam** — Big Picture via Sway, with a 250Gi `host-path` PVC persisting `/home/retro` (login, library, installed games) across sessions. Includes DLSS support under Proton (see DLSS notes below) and a `nvngx-cache` (4Gi `host-path`) PVC for the restored NVIDIA wine NGX bridge DLLs.

### Patched Fork & Engineering Notes

Getting this working end-to-end required a fork of the operator (`[shrinedogg/fenrir](https://github.com/shrinedogg/fenrir)`) plus several cluster-specific config decisions. Images are built locally and published to Docker Hub with semver tags.

**Forked images:**


| Image                                    | Tag      | Why                                                                                                                                                                                                    |
| ---------------------------------------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `docker.io/shrinedogg/direwolf-operator` | `v0.1.0` | Retries stream reconciliation (upstream stalls the session until the 1-minute reaper kills it whenever the agent isn't up on the first try) and prunes stale `trackedSessions` entries that spam logs. |
| `docker.io/shrinedogg/moonlight-proxy`   | `v0.1.1` | Raises the `/launch` wait from 25s to 120s; a cold start (image pull + Wolf boot + agent readiness) exceeds 25s, so upstream returned 500 and the client cancelled the session.                        |
| `docker.io/shrinedogg/wolf-agent`        | `v0.1.0` | Implements Wolf's `fake-udev` mechanism in Go: on device hotplug it writes `/run/udev/data` entries and broadcasts synthetic libudev netlink events in the pod netns so SDL/Steam detect controllers.  |
| `docker.io/shrinedogg/wolf`              | `v0.1.0` | Overlay on `wolf:stable` with a patched `gst-wayland-display` ([shrinedogg/gst-wayland-display](https://github.com/shrinedogg/gst-wayland-display), branch `fix/optional-wl-drm`): skips the legacy `wl_drm` global when dmabuf v4 feedback is active, fixing the wlroots/Sway nested-compositor abort. |


**Key fixes captured in the manifests:**

- **LB IP sharing** — the operator's `--lb-sharing-key` is aligned to `direwolf` so Cilium LB-IPAM hands every per-session RTP Service the same external IP as the proxy. Mismatched keys split the IP and the RTSP handshake times out (macOS errno 60).
- **GPU on the app container** — the game container needs its own `nvidia.com/gpu` request; CDI driver/device injection is per-allocated-container, so without it the app has no render node and produces a black stream.
- `**GBM_BACKENDS_PATH`** — set on both the Wolf sidecar and the Steam container; the CDI hook drops the NVIDIA GBM backend in `/usr/local/lib/gbm` while Mesa only searches `/usr/lib/x86_64-linux-gnu/gbm`.
- **Sway via patched Wolf compositor** — Wolf's `gst-wayland-display` advertised both the legacy `wl_drm` global and `zwp_linux_dmabuf_v1` v4 feedback; nested wlroots (Sway 0.19+) binds both and aborts on the duplicate device announcement (`assert(wl->drm_render_name == NULL)`). The patched `shrinedogg/wolf` image skips `wl_drm` when dmabuf v4 feedback is active (legacy clients can opt back in with `GST_WAYLAND_DISPLAY_ADVERTISE_WL_DRM=1`), letting Steam run under Sway instead of gamescope.
- `**/dev/shm` sizing** — a 4Gi memory-backed `emptyDir` at `/dev/shm`; the 64Mi runtime default exhausts instantly under Steam's CEF UI, yielding a black screen with only a cursor.
- **User namespaces** — Steam's pressure-vessel runtime requires `user.max_user_namespaces`, which Talos defaults to `0`. Enabled cluster-wide via Omni machine-config patches on every node (node-level config, not in this repo); also used by the `auth` and `affine` workloads, which run with `hostUsers: false` so their containers' root maps to an unprivileged host UID.
- **Privileged Steam container** — Wolf hotplugs `uinput` devices mid-session; Kubernetes has no equivalent of Docker's `device_cgroup_rules`, so the container must be privileged to open the late-appearing `/dev/input/event`* nodes.
- **Root Wolf entrypoint** — a ConfigMap (`wolf-entrypoint.yaml`) shadows the GOW `/entrypoint.sh` to force the Wolf sidecar to run as root, avoiding the upstream `gosu`/`supervisord` privilege-drop crash loop. (Re-declaring `PUID`/`PGID`/`UNAME` is rejected by server-side apply as duplicate map keys.)
- **DRM render-node override** — `wolfConfig.runtimeVariables.renderNode` is pinned to `/dev/dri/renderD129`. The NVIDIA container toolkit injects the dGPU with its host numbering (`renderD128` doesn't exist inside the container), and with the wrong node Wolf fails GPU vendor detection and silently falls back to **software x264 encoding**.
- **In-container `udevd` (Steam Input)** — beyond the `wolf-agent` fake-udev (which surfaces the Moonlight controller), the Steam app runs a real `systemd-udevd` + `udevadm trigger`. Steam Input emulates a *second* uinput pad for the game, and without an in-container udevd nothing writes its udev db entry / libudev event, so SDL/Proton see no controller in-game.
- **Focus guard (Sway only)** — a small Python/Xlib watcher (`focus-guard.py`) launched in the Steam container. Steam's `steamwebhelper` maps an invisible, class-less notification popup that steals X input focus from the running game; gamescope pins focus to the game but Sway honors the grab, breaking keyboard + Steam Input routing. The guard returns focus to the viewable `steam_app_*` window whenever an unnamed/class-less window holds it (legitimate Big Picture focus changes are left alone).
- **PulseAudio device names** — the Steam app deliberately does **not** export `PULSE_SINK`/`PULSE_SOURCE`. The image has no `pactl`, so the upstream lookup exported empty/bogus names; libpulse treats a set-but-invalid device as an explicit request and fails the stream (silent Steam) instead of falling back to Wolf's default virtual sink.
- **No `NVIDIA_DRIVER_CAPABILITIES` on the app container** — the operator already appends `NVIDIA_DRIVER_CAPABILITIES=all` to the app container (`session.go`); re-declaring it makes the server-side-apply patch invalid (duplicate map key) so the Deployment is never created and the reaper kills the session after 60s. (Same failure class as the root-entrypoint `PUID` note above.)
- **DLSS / NVAPI under Proton** — DLSS needs two things on Talos. (1) The `nonfree-kmod-nvidia` extension strips the NVIDIA "wine" NGX bridge DLLs (`nvngx.dll` / `_nvngx.dll`), so an `nvngx-bridge` initContainer extracts them from the matching driver `.run` and caches them on the `nvngx-cache` host-path PVC (downloaded at most once); Proton copies them into each prefix's `system32` when `PROTON_ENABLE_NVAPI=1`. (2) DLSS is gated behind NVAPI, so `PROTON_ENABLE_NVAPI=1` + `DXVK_ENABLE_NVAPI=1` are set on the Steam container, otherwise the in-game DLSS toggle stays greyed out despite the RTX GPU.

## 🤖 AI & Agents

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack: an OpenAI-compatible LLM served in-cluster by [vLLM](https://github.com/vllm-project/vllm), and [kagent](https://kagent.dev/) agents that use it to inspect and troubleshoot the cluster over MCP. No inference leaves the cluster. Per-task agent routing for this repo is documented in [`.rules`](.rules).

### Components

| Component | Description |
| --------- | ----------- |
| [vLLM](https://github.com/vllm-project/vllm) | OpenAI-compatible inference server pinned to `nv-01`, consuming one of the RTX 5090's 4 `nvidia.com/gpu` time-slices. Serves [`nvidia/Gemma-4-26B-A4B-NVFP4`](https://huggingface.co/nvidia/Gemma-4-26B-A4B-NVFP4) — NVIDIA's ModelOpt **NVFP4** quant of Gemma-4-26B-A4B-IT: a 26B MoE (~3.8B active), 14B on disk, **256K context** with hybrid sliding-window attention, running on the 5090's native Blackwell FP4 tensor cores. |
| [kagent](https://kagent.dev/) | Agent framework + controller. Renders a default `ModelConfig` pointing at the local vLLM, runs the built-in agents, and exposes an MCP server at `kagent-mcp.biggs.dog/mcp` (basic-auth) plus a UI behind OAuth2 Proxy forward-auth. Backed by CNPG Postgres with pgvector for long-term (cross-session) memory. |
| flux-mcp / `flux-agent` | A custom (non-chart) **read-only** kagent `Agent` wired to the Flux Operator MCP server, for GitOps inspection and reconciliation root-cause analysis. Defined in `apps/ai-system/flux-mcp/`. |
| victoria-metrics-mcp / `vm-agent` | A custom kagent `Agent` backed by the [VictoriaMetrics MCP server](https://github.com/VictoriaMetrics/mcp-victoriametrics) (`v1.20.2`), providing direct PromQL/MetricsQL query access, alerting rule inspection, TSDB cardinality analysis, and embedded VM documentation search. Defined in `apps/ai-system/victoria-metrics-mcp/`. |
| minimax-mcp / `minimax-agent` | A specialized **cognition layer** agent that correlates high-level reasoning with low-level cluster data. Uses the Minimax M3 model via an outbound-only MCP server. Defined in `clusters/cluster0/kubernetes/apps/ai-system/minimax-mcp/`. |

**Available agents** (`kubectl get agents -n ai-system`): `k8s-agent`, `observability-agent`, `promql-agent`, `helm-agent`, `flux-agent`, `vm-agent`, `minimax-agent`, and three Cilium agents (`cilium-manager-agent`, `cilium-debug-agent`, `cilium-policy-agent`). The chart's `argo-rollouts`, `istio`, and `kgateway` agents are disabled. See [`.rules`](.rules) for which agent to use for what.

### Engineering Notes

- **NVFP4 on a consumer 5090** — the RTX 5090 (Blackwell, `sm_120`) has native FP4 tensor cores, and vLLM `v0.23.0` runs the NVFP4 weights on a real FP4 GEMM path (NVIDIA ModelOpt NVFP4; MoE backend is vLLM-CUTLASS/Marlin) — no fp16 fallback.
- **Served name must match kagent** — vLLM's `--served-model-name` must equal the kagent provider `model:` in the `HelmRelease`, or every agent 404s on the model.
- **Tool-call parser** — Gemma-4 uses `--tool-call-parser gemma4` + `--reasoning-parser gemma4` (per NVIDIA's model card), with `--enable-auto-tool-choice`. (The prior Qwen3.6 model needed `qwen3_coder` instead — parser choice is model-family-specific.)
- **Quantization auto-detect** — no `--quantization` flag; vLLM reads NVIDIA ModelOpt's NVFP4 config from the checkpoint. `--trust-remote-code` is required (Gemma-4 ships custom modeling code).
- **CUDA graphs + context on 32 GB** — runs with `fp8` KV cache, `--max-num-seqs 64` / `--max-cudagraph-capture-size 64`, **`--max-model-len 262144` (256K, the model's native max)**, and `--gpu-memory-utilization 0.98`. The model's **hybrid sliding-window (1024) + global attention** keeps most layers' KV bounded, so even the full 256K window is cheap — where the old full-attention 27B capped at 65K. The CUDA driver context caps usable util near ~0.984, so 0.98 is the practical max.
- **MCP route timeout** — agent runs are multi-step LLM tool-calling loops that can exceed Envoy's ~15s default; the `kagent-mcp` `HTTPRoute` sets `timeouts.request: 300s`. The MoE's ~3.8B active params make inference fast, easing this.
- **Observability & measured performance** — vLLM's `/metrics` are scraped into Victoria Metrics via a `VMServiceScrape`, with a Grafana dashboard (`apps/ai-system/vllm/app/grafana-dashboard.yaml`, "AI" folder) charting throughput, TTFT, TPOT, and KV-cache usage. Measured on the 5090 (`vllm bench serve`, random 1K-in/512-out): single-stream **~140 tok/s @ ~50 ms TTFT**; batched aggregate **~1,960 tok/s @ 32-way** and **~2,750 tok/s @ 64-way** concurrency (0 failures), KV peaking ~20% — ample headroom on the 256K window.
- **Model right-sizing (history)** — the cluster previously ran `NeuralNet-Hub/Qwen3.6-27B-NVFP4`, but per its author that was a suboptimal `llm-compressor` quant only validated on a **48 GB** card ([discussion](https://huggingface.co/NeuralNet-Hub/Qwen3.6-27B-NVFP4/discussions/1)) — it barely fit the 32 GB 5090 (util pinned near 0.984, 65K context max), causing OOM/`no cache blocks` churn and overflowing `flux-agent`'s ~64K tool schemas. The swap to the smaller, KV-efficient Gemma-4-26B-A4B (14B on disk, sliding-window attention, 256K context) resolved all of it: flux-agent and the other heavy agents now fit with memory on, and inference is faster.
- **M3 Cognition Layer** — Unlike standard lookup agents, the `minimax-agent` is designed for high-level reasoning. It follows three core patterns: **State Correlation** (correlating metrics from `observability-agent` with cluster state), **Policy-First Architecture** (reasoning through security requirements before generating `CiliumNetworkPolicy`), and **GitOps-Centric Troubleshooting** (always proposing changes to the desired state in Git rather than manual `kubectl` mutations).

## 🌐 Networking Configuration

### BGP Peering

The cluster uses Cilium BGP to peer with the network router (UDM) for LoadBalancer IP advertisement:

## 🔐 Secret Management

Secrets are managed using:

1. **SOPS with age encryption** - For secrets stored in Git
2. **External Secrets + 1Password** - For runtime secret injection from 1Password vaults

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
        ├── kustomization.yaml
        └── helmrelease.yaml (or raw manifests)
```

## 📝 License

Personal homelab configuration - feel free to use as reference.