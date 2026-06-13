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

> **GPU notes:** The Intel iGPUs are exposed to workloads via the Intel GPU device plugin for media transcoding. `nv-01`'s RTX 5090 is time-sliced into 4 `nvidia.com/gpu` replicas for the [Dreamcast game-streaming stack](#-dreamcast-game-streaming-stack). The AMD integrated graphics on the two AMD nodes are present but unused (nodes run headless).

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
- **Steam** — Big Picture via Sway, with a 250Gi `host-path` PVC persisting `/home/retro` (login, library, installed games) across sessions.

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
- **User namespaces** — Steam's pressure-vessel runtime requires `user.max_user_namespaces`, which Talos defaults to `0`. Set via an Omni machine-config patch on the GPU node (node-level config, not in this repo).
- **Privileged Steam container** — Wolf hotplugs `uinput` devices mid-session; Kubernetes has no equivalent of Docker's `device_cgroup_rules`, so the container must be privileged to open the late-appearing `/dev/input/event`* nodes.
- **Root Wolf entrypoint** — a ConfigMap (`wolf-entrypoint.yaml`) shadows the GOW `/entrypoint.sh` to force the Wolf sidecar to run as root, avoiding the upstream `gosu`/`supervisord` privilege-drop crash loop. (Re-declaring `PUID`/`PGID`/`UNAME` is rejected by server-side apply as duplicate map keys.)

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