# biggs.dog

> Biggs was my dog. He was the best boy and when I found out I could buy a domain with .dog as the extension, I migrated my homelab services to biggs.dog to honor him.

## Overview

This is a mono repository for home infrastructure and Kubernetes clusters, following Infrastructure as Code (IaC) and GitOps practices using [Flux](https://fluxcd.io/). Desired state lives in Git; Flux reconciles it into the clusters.

The homelab is split across **two clusters**:

- **`cluster0`** - an on-prem single-node [Talos Linux](https://www.talos.dev/) management cluster (LAN IP `192.168.2.31`) acting as the **management plane**: the Talos management plane ([Omni](https://omni.siderolabs.io/)), Talos Image Factory, root identity ([Dex](https://dexidp.io/)), [OpenEBS](https://openebs.io/) storage, the Cluster API (CAPI) management subtree, cert-manager, external-secrets, and Cilium CNI. Remote access uses the UniFi Dream Machine (UDM) built-in VPN.
- **`cluster1`** - the **on-prem bare-metal workload cluster** (6 nodes: `control-01`, `nv-01`, `worker-01` through `worker-04`) running Talos Linux `v1.13.8` with Kubernetes `v1.36.3`: all applications, Rook-Ceph distributed storage, OpenEBS storage, GPU/AI workloads (dual RTX 5090s on `nv-01`, 64 GB VRAM), media, communication, and observability.

## Architecture

### GitOps with Flux

Each cluster runs its own [Flux Operator](https://fluxcd.controlplane.io/operator/) instance syncing a dedicated path on the `main` branch of this repository:

| Cluster | Sync path | Flux distribution | Contents |
| --- | --- | --- | --- |
| `cluster0` | `clusters/cluster0` | Flux `2.9.0` | Management plane: Dex, Omni, Image Factory, CAPI management subtree, cert-manager, external-secrets, OpenEBS, Cilium, network policies |
| `cluster1` | `clusters/cluster1` | Flux `2.9.0` | Workloads: applications, Rook-Ceph and OpenEBS storage, CloudNativePG, AI/agents, observability, network policies |

Flux components on each cluster: Source Controller, Kustomize Controller, Helm Controller, Notification Controller.

### Repository Structure

```
clusters/
├── cluster0/                      # On-prem Talos management cluster (single node, 192.168.2.31)
│   ├── capi/                      # Cluster API management subtree (CAPI operator, Tinkerbell, providers)
│   │   ├── capi-providers/        # CAPI, CABPT, CACPPT, CAPT provider definitions
│   │   ├── clusters/management/   # Management cluster CRs (Hardware, Cluster, TalosControlPlane, CRS)
│   │   ├── infrastructure/        # CAPI operator and Tinkerbell manifests
│   │   └── sources/               # CAPI Helm and OCI sources
│   ├── flux-system/               # FluxInstance + sources
│   └── kubernetes/apps/
│       ├── auth/dex/              # Dex OIDC IdP (root identity for edge apps)
│       ├── cert-manager/          # Certificate issuance (ACME + CA issuers)
│       ├── external-secrets/      # External Secrets + 1Password Connect
│       ├── kube-system/cilium/    # Cilium CNI (L2 announcement, 192.168.2.31/32)
│       ├── network-policies/      # CiliumNetworkPolicies (two-tier: apps + infra)
│       ├── networking/            # agentgateway (cluster0-gateway) + Cloudflare DDNS
│       ├── omni/
│       │   ├── omni/              # Sidero Omni (Talos management plane for cluster1)
│       │   └── image-factory/     # Talos image factory
│       └── openebs/               # OpenEBS localpv host-path storage
└── cluster1/                      # On-prem bare-metal workload cluster (6 nodes)
    ├── flux-system/               # FluxInstance + sources
    └── kubernetes/apps/
        ├── ai-system/             # vLLM + kagent agents + substrate runtime + MCP servers
        ├── auth/                  # SSO stack (Pocket ID + OAuth2 Proxy)
        ├── biggs/                 # Tribute
        ├── cert-manager/          # Certificate issuance (ACME + CA issuers)
        ├── cnpg/                  # CloudNativePG databases + Barman Cloud
        ├── dragonfly/             # Redis-compatible cache
        ├── dreamcast/             # GPU game streaming (Fenrir/Wolf + NVIDIA GPU Operator + GPU Arbiter)
        ├── external-secrets/      # External Secrets + 1Password Connect
        ├── games/                 # Dedicated game servers (Windrose)
        ├── kube-system/           # Cilium (BGP), CoreDNS, NFD, GPU plugins, storage
        ├── liquidctl/             # NZXT Kraken Elite AIO fan/pump control (nv-01)
        ├── livekit/               # LiveKit SFU (WebRTC media server for MatrixRTC)
        ├── matrix/                # Continuwuity (Matrix) + Sable client
        ├── media/                 # Emby, Bookboss, Ersatz, Nsyncd
        ├── mindwtr/               # Mindwtr notes PWA + self-hosted sync server
        ├── network-policies/      # Tiered CiliumNetworkPolicies (apps + infra)
        ├── networking/            # k8s-gateway, lan-dns, agentgateway (wildcard-biggs-dog)
        ├── observability/         # VictoriaMetrics/Logs, Grafana Operator
        ├── openebs/               # Container-attached storage
        ├── renovate/              # Automated dependency updates
        └── rook-ceph/             # Distributed storage (Rook v1.20 + Ceph CSI driver)
```

## Cluster Nodes

### `cluster1` - on-prem bare metal

Six bare-metal nodes managed via self-hosted [Omni](https://omni.siderolabs.io/) running on `cluster0` (`omni.biggs.dog`, context `self-hosted`, cluster `biggs-dog`), all running **Talos Linux v1.13.8** with Kubernetes **v1.36.3**. This is where workloads and the GPU reside.

| Hostname | Role | CPU | RAM | GPU |
| --- | --- | --- | --- | --- |
| `control-01` | control-plane | AMD EPYC 4564P (16C / 32T) | 128 GB | AMD Radeon iGPU (Raphael, `1002:164e`, unused) |
| `nv-01` | worker | AMD Ryzen 7 7800X3D (8C / 16T) | 64 GB | **Dual NVIDIA GeForce RTX 5090** dGPUs (2x 32 GB = 64 GB VRAM: ASUS TUF in PCIE1, Zotac AMP Extreme Infinity upright in PCIE2; 4x time-slicing per card = 8 `nvidia.com/gpu` replicas) + AMD Radeon iGPU |
| `worker-01` | worker | Intel Core Ultra 5 225H (Arrow Lake-H, 14T) | 32 GB | Intel Arc Graphics iGPU (`8086:7d51`) |
| `worker-02` | worker | Intel Core i7-1360P (Raptor Lake-P, 16T) | 32 GB | Intel Iris Xe Graphics iGPU (`8086:a7a0`) |
| `worker-03` | worker | Intel Core i7-1360P (Raptor Lake-P, 16T) | 32 GB | Intel Iris Xe Graphics iGPU (`8086:a7a0`) |
| `worker-04` | worker | Intel Core Ultra 5 125H (Meteor Lake, 18T) | 32 GB | Intel Arc Graphics iGPU (`8086:7d55`) |

### `cluster0` - on-prem management node

A single-node Talos management cluster (`talos-mgmt-01` / `cluster0-cp-01`) on the LAN at `192.168.2.31`, running **Talos Linux v1.14** with Kubernetes **v1.36.0**. Bootstrapped using `knr-bootstrap` (knr-ops `local-talos` pattern) via Cluster API (CAPI) with Tinkerbell and Talos providers (`bootstrap.toml`). It hosts the Talos management plane (Omni), Talos Image Factory, root identity (Dex), and OpenEBS storage. Cilium advertises the node IP (`192.168.2.31/32`) via an L2 announcement policy shared between `cluster0-gateway` and `omni-siderolink`.

> **GPU notes (`cluster1`):** The Intel iGPUs are exposed to workloads via the Intel GPU device plugin for media transcoding. `nv-01` carries **dual NVIDIA GeForce RTX 5090 dGPUs** (64 GB total GDDR7 VRAM across an ASUS TUF in PCIe slot 1 and a Zotac AMP Extreme Infinity on a 900mm riser in PCIe slot 2, hosted on an ASRock X870E Taichi Lite with PCIe 5.0 x8/x8 bifurcation in a Lian Li O11D EVO XL chassis powered by a 1600W PSU). The NVIDIA GPU Operator slices each card into 4 replicas (8 schedulable `nvidia.com/gpu` replicas total). The `nvidia-gpu-tuning` DaemonSet manages clocks (2800 MHz) and power caps (550W per card) across both GPUs (`NVIDIA_VISIBLE_DEVICES=all`). vLLM and the [Dreamcast game streaming stack](#dreamcast-game-streaming-stack) are arbitrated by the [GPU Arbiter](#gpu-arbiter) during gaming sessions to manage peak dual-card power draw, thermal headroom, and prevent Xid 109 context switch timeouts. `nv-01` runs a Samsung 9100 PRO 1TB install disk, a Realtek RTL8126 5GbE NIC (`enp9s0`), and Sidero Talos kernel-signed open GPU modules (`595.71.05`). The AMD integrated graphics on the Ryzen 7800X3D CPU is bypassed via `VK_DRIVER_FILES` so rendering and compute target the NVIDIA hardware exclusively.

> **Storage disk selection notes (`cluster1`):** Workers carry two NVMe drives. Linux NVMe drive enumeration order (`/dev/nvme0n1` vs `/dev/nvme1n1`) is unstable across reboots on multi-drive hosts. Talos install drives are pinned by hardware serial via `machine.install.diskSelector` in the Omni cluster template. Rook-Ceph OSDs (one Micron 7450 960 GB NVMe per worker) are pinned by persistent by-id paths (`/dev/disk/by-id/nvme-Micron_7450_..._<serial>`).

## Core Components

### Networking

| Cluster | Component | Description |
| --- | --- | --- |
| both | [Cilium](https://cilium.io/) | CNI (kube-proxy replacement). `cluster0`: L2 announcement + single-IP pool (`192.168.2.31/32`). `cluster1`: BGP peering with the UDM (ASN 64564 <-> 64563) advertising LoadBalancer IPs from `192.168.6.6-254`. |
| `cluster1` | [k8s-gateway](https://github.com/ori-edge/k8s_gateway) | Split-horizon DNS authoritative for `*.biggs.dog` (LB `192.168.6.6`, ClusterIP `10.101.183.97`, 2 replicas). Contains a hosts block mapping `omni.biggs.dog`, `dex.biggs.dog`, `factory.biggs.dog` to `192.168.2.31` locally before fallthrough to NextDNS. |
| `cluster1` | lan-dns | LAN resolver (CoreDNS, LB `192.168.6.16`): contains a hosts block for cluster0 edge names to `192.168.2.31`, forwards `biggs.dog` to k8s-gateway's ClusterIP (`10.101.183.97`), and forwards everything else to NextDNS over DoT (`tls://45.90.28.0`, `tls://45.90.30.0`). The UDM hands out `.6.16` via per-VLAN DHCP. |
| both | [Gateway API](https://gateway-api.sigs.k8s.io/) | Kubernetes ingress using Gateway API. `cluster1` runs `wildcard-biggs-dog` (LB `192.168.6.7`), fronted by UDM port forwards on 80/443. `cluster0` runs `cluster0-gateway` (LB `192.168.2.31`). |
| both | [AgentGateway](https://github.com/kgateway-dev/kgateway) | Gateway API implementation with OCI charts pinned to a verified build. |

`cluster1` DNS: LAN clients resolve `biggs.dog` via **lan-dns** (`192.168.6.16`), which forwards to k8s-gateway for internal VIPs and to NextDNS over DoT for everything else. In-cluster, **CoreDNS** (kube-dns, Talos-managed) forwards `biggs.dog` to k8s-gateway's ClusterIP (`10.101.183.97`), so pods resolve `*.biggs.dog` internally instead of hairpinning through Cloudflare. Both forward targets use the ClusterIP (not the LB VIP) to avoid a Cilium same-node LB hairpin failure when a resolver pod is co-located with k8s-gateway.

`cluster0` ingress is `cluster0-gateway` (`networking` namespace) with HTTPS listeners for `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog` (TLS terminated with per-host certs issued in the `networking` namespace via the `letsencrypt-prod` ClusterIssuer), plus a wildcard `*.biggs.dog` HTTP listener. Omni re-encrypts to its pod cert (HTTPS backend via BackendTLSPolicy).

**Service-specific gateways:**
- **ersatz** (`cluster1`, media server): LAN-only HTTPS gateway at `ersatz.biggs.dog`
- **internal-biggs-dog** (`cluster1`): LAN-only gateway (VIP `192.168.6.15`) for internal routes including `mcp.biggs.dog` and `mindwtr.biggs.dog`

### Storage (`cluster1`)

| Component | Description |
| --- | --- |
| [Rook-Ceph](https://rook.io/) | Distributed block storage cluster (`ceph-block` StorageClass, pool `ceph-blockpool` size 3) on four OSDs (Micron 7450 960 GB NVMe per worker). Rook v1.20 with ceph-csi-operator Driver and OperatorConfig CRs in git (`rook-ceph/csi-rbac/drivers.yaml`). Cluster fsid `37a406cf-68c2-4131-96e7-f7b7c050b2c4` preserved via mon-store adoption. |
| [OpenEBS](https://openebs.io/) | Container attached storage (localpv host-path provisioner, chart `4.6.0` on both clusters). |
| [Volsync](https://volsync.readthedocs.io/) | Backup and replication of persistent volumes to Backblaze B2 (chart `0.16.0`). Cache PVCs pinned to `ceph-block`. |
| [Snapshot Controller](https://github.com/kubernetes-csi/external-snapshotter) | CSI volume snapshots (chart `5.2.0`). |
| NFS CSI Driver | NFS storage provisioner (chart `4.13.4`). |
| ZFS | ZFS volume management. |

### Database (`cluster1`)

| Component | Description |
| --- | --- |
| [CloudNativePG](https://cloudnative-pg.io/) | PostgreSQL operator for in-cluster databases (chart `0.29.0`, PG18 minimal Trixie image catalog). |
| [Barman Cloud](https://pgbarman.org/) | CNPG plugin (`0.7.1`) for PostgreSQL backup and recovery to object storage. |
| [Dragonfly](https://www.dragonflydb.io/) | Redis-compatible in-memory datastore. |

### Security and Secrets (both)

| Component | Description |
| --- | --- |
| [cert-manager](https://cert-manager.io/) | Certificate management with CA and ACME issuers (chart `v1.21.1` on both clusters). |
| [External Secrets](https://external-secrets.io/) | Sync secrets from external providers (chart `2.9.0` on both clusters). |
| [1Password Connect](https://developer.1password.com/docs/connect/) | Secret backend for External Secrets. The `connect` chart (`v2.4.1`) is deployed on **both** clusters, with its `1password-credentials.json` and API `token` shipped as **SOPS-encrypted Secrets in Git** (decrypted in-cluster by Flux's `sops-age` key), not inline chart values. |
| [SOPS](https://github.com/getsops/sops) | Encrypted secrets (age key). The repo-wide age key is configured in `.sops.yaml`. |

### Network Policies (`cluster1` and `cluster0`)

Both clusters run a least-privilege [CiliumNetworkPolicy](https://docs.cilium.io/en/stable/security/policy/) posture. Policies live centrally in `apps/network-policies/policies/` and are wired through **two independent Flux Kustomizations** so the rollout can be staged and rolled back per-tier:

- **`cluster1`** - `network-policies-apps` (`policies/apps/`) covers application namespaces (auth, biggs, dragonfly, dreamcast, games, livekit, matrix, media, mindwtr, renovate). `network-policies-infra` (`policies/infra/`) covers infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, plus a scoped `kube-system` policy covering Hubble relay/UI pods).
- **`cluster0`** - `network-policies-apps` covers auth (Dex) and omni. `network-policies-infra` covers networking (agentgateway), cert-manager, external-secrets, flux-system, and capi. Suspend independently with `flux suspend kustomization network-policies-infra` if the control plane regresses.

### Identity and SSO

The two clusters run different identity stacks:

**`cluster0` (management) - Dex** (`dex.biggs.dog`):
[Dex](https://dexidp.io/) (`v2.45.1`) is the root OIDC identity provider for the management plane, backing Omni and Image Factory. It runs stateless (`storage.type: memory`) with `enablePasswordDB: true` and a static admin user; clients and secrets are templated into the config from 1Password. Config lives in `clusters/cluster0/kubernetes/apps/auth/dex/`.

| Component | Description |
| --- | --- |
| [Dex](https://dexidp.io/) (`cluster0`) | Root OIDC IdP for management apps (Omni, Image Factory). Stateless, static admin user. |
| [Pocket ID](https://github.com/pocket-id/pocket-id) (`cluster1`) | Passkey-based OIDC provider at `id.biggs.dog` (image `v2.14.0`, Postgres via CNPG, uploads stored in database). |
| [OAuth2 Proxy](https://github.com/oauth2-proxy/oauth2-proxy) (`cluster1`) | OIDC client at `auth.biggs.dog` (image `v7.15.4`, chart `10.7.0`); forward-auth for apps with a shared `.biggs.dog` session cookie. |

On `cluster1`, protected apps attach an agentgateway `AgentgatewayPolicy` with `traffic.extAuth` that calls OAuth2 Proxy's `/oauth2/auth` endpoint and redirects unauthenticated users to Pocket ID sign-in. OAuth2 Proxy uses **Dragonfly (Redis) for session storage** so the browser cookie stays a small session ticket.

- **Forward-auth (`cluster1`, via OAuth2 Proxy):** Rook-Ceph dashboard, Bookboss, kagent UI, Mindwtr (browser PWA only; the `/v1` sync API uses bearer tokens for CLI and mobile sync).
- **Native OIDC (`cluster1`, direct Pocket ID client):** Grafana.

### Observability (`cluster1`)

| Component | Description |
| --- | --- |
| [VictoriaMetrics](https://victoriametrics.com/) | Metrics storage and monitoring (`victoria-metrics-k8s-stack` chart `0.91.2`). |
| [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) | Log aggregation (chart `0.13.9` single, `0.3.7` collector; includes Talos kernel logs with GPU Xid alerting). |
| [Grafana Operator](https://grafana.github.io/grafana-operator/) | Grafana deployment and dashboard management (chart `10.5.15`). |

### System (`cluster1`)

| Component | Description |
| --- | --- |
| [Node Feature Discovery](https://kubernetes-sigs.github.io/node-feature-discovery/) | Hardware feature detection. |
| Intel GPU Plugin | Intel GPU device plugin for hardware media transcoding acceleration. |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) | NVIDIA device plugin with GPU time-slicing (chart `v26.7.0`; driver and toolkit provided by Talos system extensions). |

### Management Plane (`cluster0`)

| Component | Description |
| --- | --- |
| [Omni](https://omni.siderolabs.io/) (Sidero) | In-cluster Talos management plane at `omni.biggs.dog` (`v1.10.5`): UI, machine API (`:8090`), event sink (`:8091`), Kubernetes proxy (`:8100`), and Siderolink WireGuard (`:50180/udp`). Sole manager of `cluster1` nodes (which phone home over Siderolink). Backed by embedded etcd + SQLite PVCs on OpenEBS; OIDC login via Dex. |
| [Talos Image Factory](https://www.talos.dev/latest/learnmore/image-factory/) | Builds and signs custom Talos Linux images with cosign (`ghcr.io/siderolabs/image-factory:v1.6.0`). Stateless HTTP service behind OAuth2 Proxy authenticated against Dex at `factory.biggs.dog`. Durable state in registry PVC on OpenEBS. |
| [Cluster API (CAPI)](https://cluster-api.sigs.k8s.io/) | CAPI operator (`0.28.0`), core CAPI `v1.14`, CABPT `v0.7.6`, CACPPT `v0.6.4`, and CAPT `v0.7.1` (Tinkerbell) managing the single on-prem management node. |
| [Dex](https://dexidp.io/) | Root OIDC identity provider for Omni and Image Factory. See [Identity and SSO](#identity-and-sso). |
| [OpenEBS](https://openebs.io/) | Localpv host-path provisioner backing Omni and Image Factory persistent volumes. |
| Cloudflare DDNS | CronJob (`docker.io/favonia/cloudflare-ddns:1.15.1`) updating dynamic DNS. |

### Automation

| Component | Description |
| --- | --- |
| [Renovate](https://docs.renovatebot.com/) (`cluster1`) | Automated dependency updates (`ghcr.io/mend/renovate-ce:15.4.0` for HelmRelease chart versions and container images). |

## Applications

| Category | Applications | Notes |
| --- | --- | --- |
| **Authentication** | Pocket ID, OAuth2 Proxy | Passkey-first OIDC SSO for applications |
| **Media** | Emby, Bookboss, Ersatz, Nsyncd | Content and book management (`emby:4.10.0.29`, `bookboss:v0.8.34`) |
| **Communication** | LiveKit SFU, Continuwuity, Sable | WebRTC media server (`livekit:v1.13.6`), Matrix homeserver, Sable Matrix web client |
| **Task Management** | Mindwtr, mindwtr-agent | Offline PWA + self-hosted sync server; GTD agent with MCP tools |
| **Game Streaming** | Fenrir / Wolf | GPU-accelerated Moonlight streaming (see [Dreamcast Game Streaming Stack](#dreamcast-game-streaming-stack)) |
| **Game Servers** | Windrose Online | Dedicated MMO server on Wine backend (`windrose:0.10.0.7.33-372c3516`) |
| **Hardware** | liquidctl | NZXT Kraken Elite AIO fan and pump curves on `nv-01` (privileged, raw USB HID) |
| **Other** | biggs | Tribute |

Detailed application deployment configurations are in `clusters/cluster1/kubernetes/apps/<namespace>/`.

## Dreamcast Game Streaming Stack

The `dreamcast` namespace is an on-demand, GPU-accelerated game-streaming platform built on [Games on Whales](https://games-on-whales.github.io/) Fenrir/Wolf. A [Moonlight](https://moonlight-stream.org/) client pairs with an in-cluster `moonlight-proxy`, and the `direwolf-operator` spins up a per-session pod (Wolf compositor + the app) on the NVIDIA node, encodes the desktop with NVENC, and streams it back over RTSP/RTP.

### Components

| Component | Description |
| --- | --- |
| [NVIDIA GPU Operator](https://github.com/NVIDIA/gpu-operator) | `gpu-operator` Helm chart (`v26.7.0`) with `driver` and `toolkit` disabled. On Talos the driver ships via the `nonfree-kmod-nvidia` system extension and the container toolkit via system extension + machine config, so the operator only runs NFD + device plugin. The dual physical RTX 5090 GPUs are **time-sliced into 4 replicas each (8 total `nvidia.com/gpu` replicas)**: one is held by the `nvidia-gpu-tuning` DaemonSet (tuning both cards), the rest serve a session's Wolf sidecar + game container, and vLLM. vLLM is scaled to 0 during gaming sessions by the [GPU Arbiter](#gpu-arbiter) to maintain thermal and power stability across the dual-card chassis. |
| [Fenrir / direwolf-operator](https://github.com/games-on-whales/fenrir) | Operator (OCI HelmRelease) that reconciles `App`/`User`/`Session`/`Pairing` CRDs and creates session pods. Fronted by `moonlight-proxy`. Forked as `docker.io/shrinedogg/direwolf-operator:v0.1.0`. |
| [Wolf](https://games-on-whales.github.io/wolf/) | Per-session streaming sidecar: Wayland compositor, GStreamer + NVENC video pipeline, PulseAudio capture, and virtual input. Forked as `docker.io/shrinedogg/wolf:v0.1.0` (wl_drm patch). |
| [gpu-arbiter-operator](https://github.com/shrinedogg/gpu-arbiter-operator) (custom) | controller-runtime operator (`docker.io/shrinedogg/gpu-arbiter-operator:v0.1.1`) that reconciles a cluster-scoped `GPUArbiter` CR: scales the `vllm` Deployment to 0 whenever an `alex-steam`/`direwolf-worker` session pod appears in `dreamcast`, and back to 1 when idle, then lifts the `gpu.biggs.dog/await-vram` scheduling gate once VRAM is free. See [GPU Arbiter](#gpu-arbiter). |
| `nvidia-gpu-tuning` (DaemonSet) | Privileged DaemonSet pinned to `nv-01` running `nvidia-smi -pm 1 -lgc 0,2800 -pl 550` across both RTX 5090 cards (`NVIDIA_VISIBLE_DEVICES=all`) to cap boost clocks (stock max 3105 MHz; Xid 109 CTX SWITCH TIMEOUT mitigation) and board power (stock TDP 600 W -> 550 W cap); re-asserted every 5 min. Consumes one of the time-sliced GPU replicas to trigger CDI injection of `nvidia-smi`. |

### GPU Arbiter

The [`gpu-arbiter-operator`](https://github.com/shrinedogg/gpu-arbiter-operator) reconciles a cluster-scoped `GPUArbiter` CR (`cluster1`) to coordinate resource allocation between heavy vLLM inference and interactive Moonlight/Wolf streaming sessions on `nv-01`, managing peak dual-5090 power and thermal loads and preventing Xid 109 driver timeouts:

1. **Scales vLLM** to 0 when gaming pods appear, back to 1 when idle.
2. **Lifts the scheduling gate** (`gpu.biggs.dog/await-vram`) once VRAM is freed.

**Deployment:** `clusters/cluster1/kubernetes/apps/dreamcast/gpu-arbiter-instance` and `gpu-arbiter-operator`. Image: `shrinedogg/gpu-arbiter-operator:v0.1.1`. Query status with `kubectl get gpuarbiter cluster1`.

### Defined Apps

Three gaming apps under `fenrir/app/apps.yaml`: **Firefox** (reference app), **Test Ball** (synthetic videotestsrc), **Steam** (Big Picture + persistent 250Gi `/home/retro` PVC + DLSS). See [NOTES.md](docs/NOTES.md#dreamcast-engineering-notes) for details.

### Forked Images

See [NOTES.md](docs/NOTES.md#forked-images) for the list of patched Dreamcast images (direwolf-operator, moonlight-proxy, wolf-agent, wolf, gpu-arbiter-operator) and why they diverge from upstream.

## AI and Agents

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack: an OpenAI-compatible LLM served in-cluster by [vLLM](https://github.com/vllm-project/vllm), and [kagent](https://kagent.dev/) agents that use it to inspect and troubleshoot the cluster over MCP. No inference leaves the cluster. Per-task agent routing for this repo is documented in [`.rules`](.rules).

### Components

| Component | Description |
| --- | --- |
| [vLLM](https://github.com/vllm-project/vllm) | OpenAI-compatible inference server (`docker.io/vllm/vllm-openai:v0.28.0`, CUDA 12.9 for Blackwell) pinned to `nv-01`, utilizing RTX 5090 GPU capacity (with dual-GPU 64 GB VRAM available on the node for multi-GPU scaling or dedicated isolation). Scaled to 0 during [Dreamcast](#dreamcast-game-streaming-stack) sessions by the [GPU Arbiter](#gpu-arbiter) and back to 1 when idle. Serves [`unsloth/Qwen3.8-27B-NVFP4`](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4) (served as `qwen 3.8 - local`) - a **27B dense** model with a Gated-DeltaNet / gated-attention hybrid (only 16 of 64 layers keep paged KV), NVFP4 via compressed-tensors (~19.9 GB on disk / ~18 GiB resident on a 32 GB card). **173K context** served (`--max-model-len=177184`; measured ceiling with 5.71 GiB available fp8 KV cache). fp8 KV cache, `--max-num-seqs 8`, `--max-cudagraph-capture-size 8`, `--max-num-batched-tokens 8192`, `--gpu-memory-utilization 0.96`, `--tool-call-parser qwen3_coder` + `--reasoning-parser qwen3`, `--enable-auto-tool-choice`, `--enable-prefix-caching`, `--trust-remote-code`, `--language-model-only` (skips the vision encoder). |
| [kagent](https://kagent.dev/) | Agent framework and controller (chart `0.9.12`). Configured with ModelConfig `qwen 3.8 - local` -> local vLLM. Exposes an MCP server over a LAN-only HTTPRoute (`kagent-mcp` at `https://mcp.biggs.dog/mcp` on the internal gateway `internal-biggs-dog`, VIP 192.168.6.15) plus a UI (`kagent.biggs.dog`) behind OAuth2 Proxy forward-auth. Backed by CNPG Postgres with pgvector for long-term vector memory. Embedding model: `BAAI/bge-m3` via the `embeddings` service (CPU-only Infinity deployment). |
| **Substrate runtime** (kagent ATE / actor runtime) | Control plane for **sandboxed agent code execution via gVisor**, deployed in `ai-system` (charts `substrate` and `substrate-crds` at `0.0.21`). Components: `ate-controller`, `ate-api-server` (digest-pinned fork `shrinedogg/ateapi@sha256:78d90103f3054bf6544bf3726fa63800a47b970b3425a3e60f4efbfff9bbdad3` with `--client-jwt-jwks-url`), `atelet` worker DaemonSet, and `atenet-router`. gVisor `runsc` (`20260622.0`) staged in rustfs `ate-snapshots` bucket and pre-cached per node via `runsc-cache` DaemonSet. A `WorkerPool` (`kagent-default`, `sandboxClass: gvisor`, `ateomImage: ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21`) is managed by kagent. Postgres and rustfs storage are patched to `host-path`. `ate-system` namespace manifest included for chart RBAC. |
| flux-mcp / `flux-agent` | Custom read-only kagent `Agent` wired to the Flux Operator MCP server for GitOps inspection and reconciliation root-cause analysis (`clusters/cluster1/kubernetes/apps/ai-system/flux-mcp/`). Per-agent memory disabled to avoid saturating context with tool schemas. |
| victoria-metrics-mcp / `vm-agent` | Custom kagent `Agent` backed by the VictoriaMetrics MCP server (`v1.20.2`): PromQL/MetricsQL query access, alerting rule inspection, TSDB cardinality analysis (`clusters/cluster1/kubernetes/apps/ai-system/victoria-metrics-mcp/`). |
| exa-mcp / `exa-agent` | Custom kagent `Agent` backed by the Exa MCP server (`3.2.1`): web search, code discovery, company research (`clusters/cluster1/kubernetes/apps/ai-system/exa-mcp/`). Long-term memory enabled with context compaction at 80K tokens. |
| codebase-memory-mcp / `codebase-agent` | Custom kagent `Agent` backed by codebase-memory-mcp (`v0.9.0`): structural code intelligence over indexed repos (biggs.dog), auto-synced via git-sync sidecar. stdio-only upstream wrapped in `mcp-proxy` bridge (`clusters/cluster1/kubernetes/apps/ai-system/codebase-memory-mcp/`). |
| mindwtr-mcp / `mindwtr-agent` | Custom kagent `Declarative` Agent backed by the Mindwtr MCP server (`mindwtr-mcp`): GTD task management with CRUD access to the Mindwtr SQLite database. Runs with `executeCodeBlocks` enabled, 30-day vector memory, and context compaction at 80K tokens (`clusters/cluster1/kubernetes/apps/ai-system/mindwtr-mcp/`). |
| [agent-sandbox](https://github.com/kubernetes-sigs/agent-sandbox) | SIG-Apps `Sandbox` CRD + controller (`agents.x-k8s.io`, GitRepository ref `v1.0.0`, `controller.extensions: true`). Provides isolated, stateful single-pod runtimes for classic `kind: Agent` CRs that opt into `executeCodeBlocks`. |
| embeddings | CPU-only Infinity embedding server serving `BAAI/bge-m3` for kagent's long-term vector memory. CPU-only to avoid contending with GPU-constrained vLLM. |

**Available agents** (`kubectl get agents,sandboxagents -n ai-system`):

The 11 agents split across two deployment patterns:

- **Classic `kind: Agent` CRs** (invocable via MCP): `flux-agent`, `vm-agent`, `exa-agent`, `cilium-debug-agent`, `cilium-policy-agent`, `codebase-agent`, `mindwtr-agent`. The two cilium agents are defined statically in `clusters/cluster1/kubernetes/apps/ai-system/kagent/cilium-agents/` with generic `k8s_*` tools alongside Cilium tools. `codebase-agent` lives in `clusters/cluster1/kubernetes/apps/ai-system/codebase-memory-mcp/`.
- **`kind: SandboxAgent` CRs on the substrate runtime** (`clusters/cluster1/kubernetes/apps/ai-system/kagent/substrate-agents/`): `k8s-agent`, `helm-agent`, `promql-agent`, `observability-agent`, `cilium-manager-agent`. These are `READY=True` with golden actors built, but are not yet invocable via the MCP server due to an upstream kagent limitation (`listReadyAgents` lists only `v1alpha2.Agent` with `DeploymentReady`, while substrate agents report `WorkloadReady`). Use the fallbacks in [`.rules`](.rules) or direct `kubectl`.
- **Disabled chart agents**: `argo-rollouts-agent`, `istio-agent`, `kgateway-agent` (the 5 substrate agents and 2 cilium agents are disabled in chart values to prevent duplicate classic Agent CRs).

See [`.rules`](.rules) for agent selection by task domain and live invocability status.

## Networking Configuration

### BGP Peering (`cluster1`)

`cluster1` uses Cilium BGP to peer with the UDM router (ASN 64563, `192.168.1.1`) from Cilium ASN 64564, advertising LoadBalancer IPs from the pool `192.168.6.6-254` (off-subnet from the nodes on `192.168.2.0/24`, so VIPs route via the UDM). k8s-gateway has **fallthrough enabled** with NextDNS resolvers (`45.90.28.232` / `45.90.30.232`) so external `biggs.dog` names resolve to public DNS. Before fallthrough, a local hosts block resolves `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog` to `192.168.2.31` (the cluster0 node), preventing Cloudflare 403 challenge pages on gRPC calls. See [NOTES.md](docs/NOTES.md#networking-stack) for details.

### Management Ingress (`cluster0`)

`cluster0` advertises its node IP (`192.168.2.31/32`) via a Cilium L2 announcement policy shared with `omni-siderolink`. `cluster0-gateway` provides TLS termination for `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog` via certificates issued by the `letsencrypt-prod` ClusterIssuer.

## Secret Management

Secrets follow a three-tier model:

1. **SOPS with age encryption** - Git-committed secrets (Cilium policies, app defaults, and 1Password Connect credentials/token). Configured in `.sops.yaml`.
2. **External Secrets + 1Password** - Runtime secrets from 1Password vaults via 1Password Connect (`connect` chart `v2.4.1` on both clusters).
3. **cert-manager** - Automatic certificate issuance and renewal (ACME Let's Encrypt, CA issuer).

See [NOTES.md](docs/NOTES.md#security-model) for details.

## Getting Started

### Prerequisites

- Kubernetes cluster(s)
- [Flux CLI](https://fluxcd.io/flux/cmd/)
- [SOPS](https://github.com/getsops/sops) with the age key for decryption
- 1Password Connect credentials

### Bootstrap

Each cluster bootstraps via Flux Operator syncing from:

```
https://github.com/shrinedogg/biggs.dog.git
```

- `cluster0` bootstraps via `knr-bootstrap local-talos` using `bootstrap.toml` syncing `clusters/cluster0/capi`, then widens to `clusters/cluster0`.
- `cluster1` is managed by self-hosted Omni on `cluster0` and syncs `clusters/cluster1`.

Flux automatically reconciles desired state based on manifests in each path. Secrets are decrypted by SOPS (age key) before Flux applies them.

## Dependency Updates

Dependency updates are managed by Renovate using the repository config in `renovate.json` (`ghcr.io/mend/renovate-ce:15.4.0`).
It updates Flux `HelmRelease` chart versions (HelmRepository and OCI-based sources) and container images referenced in Kubernetes manifests, including the media stack under `clusters/cluster1/kubernetes/apps/media/`.

## App Structure Pattern

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

## License

Personal homelab configuration. Feel free to use as reference.
