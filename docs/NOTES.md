# Engineering Notes

This document contains detailed architectural decisions, engineering notes, and historical context that is less critical for operators but helpful for maintainers and contributors.

> **Two clusters.** The homelab is split across `cluster0` (an on-prem single-node **Talos management cluster** at LAN IP `192.168.2.31`, running Cilium with L2 announcement) hosting Dex, Omni, Talos Image Factory, cert-manager, external-secrets, OpenEBS, CAPI management subtree, and CiliumNetworkPolicies (two-tier: apps + infra); and `cluster1` (the **on-prem 6-node bare-metal** workload cluster running Cilium BGP -> UDM, with `192.168.6.0/24` VIPs) hosting all applications, storage, GPU/AI, and observability. Remote administration uses the UDM built-in VPN (NetBird has been retired). Flux pruning is disabled on both root syncs as a safety measure. Most sections below describe `cluster1` workloads; cluster-specific notes are called out inline.
>
> **Note**: `cluster1` node specs (Talos Linux version, Kubernetes version, OS versions) in `README.md` are managed via Omni and reflect state at time of documentation. For live cluster versions, use `kubectl version` and check the Omni console (run in-cluster on `cluster0` at `omni.biggs.dog` - see [System and Hardware](#system-and-hardware)). This Git repo drives desired state for workloads, not node OS versions.

## Dreamcast Engineering Notes

### Forked Images

Getting the GPU-accelerated game streaming stack working end-to-end required forking the Games on Whales operator ([shrinedogg/fenrir](https://github.com/shrinedogg/fenrir)) plus several cluster-specific config decisions. Images are built locally and published to Docker Hub with semver tags.

| Image | Tag | Reason |
| ----- | --- | ------ |
| `docker.io/shrinedogg/direwolf-operator` | `v0.1.0` | Retries stream reconciliation (upstream stalls the session until the 1-minute reaper kills it whenever the agent is not up on the first try) and prunes stale `trackedSessions` entries that spam logs. |
| `docker.io/shrinedogg/moonlight-proxy` | `v0.1.1` | Raises the `/launch` wait from 25s to 120s; a cold start (image pull + Wolf boot + agent readiness) exceeds 25s, so upstream returned 500 and the client cancelled the session. |
| `docker.io/shrinedogg/wolf-agent` | `v0.1.0` | Implements Wolf's `fake-udev` mechanism in Go: on device hotplug it writes `/run/udev/data` entries and broadcasts synthetic libudev netlink events in the pod netns so SDL/Steam detect controllers. |
| `docker.io/shrinedogg/wolf` | `v0.1.0` | Overlay on `wolf:stable` with a patched `gst-wayland-display` ([shrinedogg/gst-wayland-display](https://github.com/shrinedogg/gst-wayland-display), branch `fix/optional-wl-drm`): skips the legacy `wl_drm` global when dmabuf v4 feedback is active, fixing the wlroots/Sway nested-compositor abort. |
| `docker.io/shrinedogg/gpu-arbiter-operator` | `v0.1.1` | Go/controller-runtime port of the original bash `gpu-arbiter`; scales `vllm` to 0 during sessions and lifts the VRAM scheduling gate. v0.1.x fixed scaling to use the `deployments/scale` subresource (a backwards merge patch had emitted `replicas:null`, defaulting back to 1) and switched status writes to a full `Status().Update()` so zero-valued fields clear. |

### Defined Apps Detail

**Firefox** (reference app)
- Validates the GPU/video path end-to-end with a real browser workload.

**Test Ball** (synthetic testing)
- A `videotestsrc` pattern with no app container.
- Isolates the Wolf/NVENC encode path from actual app rendering.
- Useful for diagnosing video pipeline issues without needing a full desktop app.

**Steam** (gaming)
- Big Picture mode via Sway (lightweight Wayland compositor). Gamescope was tried (forces fullscreen on a single virtual display) but its Vulkan compositing on the dGPU triggered NVRM Xid 109 (CTX SWITCH TIMEOUT) -> UE5 GPU crash (Fatal error!) on every launch; under Sway the game runs without that crash. Sway's original wl_drm abort is fixed by the patched wolf image.
- Persistent 250Gi `host-path` PVC at `/home/retro` survives session restarts, storing login, library, and installed games.
- DLSS support under Proton (via NVIDIA wine NGX bridge DLLs restored in a separate 4Gi `nvngx-cache` PVC).

### GPU Time-Slicing and vLLM

`nv-01` is equipped with **dual NVIDIA GeForce RTX 5090 dGPUs** (32 GB each, 64 GB total GDDR7 VRAM):
1. **ASUS TUF Gaming GeForce RTX 5090** (32 GB, PCIe slot 1, direct, Gen5 x8)
2. **Zotac GAMING GeForce RTX 5090 AMP Extreme Infinity** (32 GB, PCIe slot 2 via 900mm Gen5 riser, upright mount, Gen5 x8)

Hosted on an **ASRock X870E Taichi Lite** motherboard (PCIe 5.0 x8/x8 bifurcation, wide 4-pitch / 81 mm slot spacing, no M.2 lane-sharing conflict) in a **Lian Li O11D EVO XL** chassis with a 1600W PSU.

The GPU Operator configures 4x time-slicing per physical GPU, providing **8 total schedulable `nvidia.com/gpu` replicas** across the node:
1. One held by `nvidia-gpu-tuning` DaemonSet (which tunes both cards via `NVIDIA_VISIBLE_DEVICES=all`).
2. Replicas allocated to vLLM (single-card footprint consuming ~18 GiB weights + 5.71 GiB fp8 KV cache, or scalable across both cards via `-tp 2`).
3. Two replicas for an active Dreamcast gaming session (one for the Wolf sidecar, one for the game container).

When a gaming pod spins up, the `gpu-arbiter-operator` scales vLLM to 0. Even with 64 GB across two cards, arbitration manages peak board power (~1100-1200W transient under dual full load), chassis thermals, and prevents NVRM Xid 109 context switch timeouts under concurrent heavy graphics and compute workloads.

### DCGM Metrics and Gate Lifting

The `gpu-arbiter-operator` removes the `gpu.biggs.dog/await-vram` scheduling gate via a three-condition precedent:

1. **vLLM down** (~1-2s latency) - the primary signal.
2. **Free VRAM threshold** (`max(DCGM_FI_DEV_FB_FREE)` across monitored GPUs via VictoriaMetrics, ~30s lag) - the secondary signal.
3. **Safety timeout** (`spec.timeoutSeconds`, default 45s) - fallback if metrics are stale or missing.

If any condition holds, the gate lifts and the pod can schedule. This degrades gracefully: even if DCGM exporter stalls or metrics lag, the session will not hang indefinitely.

### Dreamcast on Kubernetes: Implementation Notes

Getting the full stack running required several insights:

- **LB IP sharing** - the operator's `--lb-sharing-key` is aligned to `direwolf` so Cilium LB-IPAM hands every per-session RTP Service the same external IP as the proxy. Mismatched keys split the IP and the RTSP handshake times out (macOS errno 60).
- **GPU on the app container** - the game container needs its own `nvidia.com/gpu` request; CDI driver/device injection is per-allocated-container, so without it the app has no render node and produces a black stream.
- **GPU workload arbitration with vLLM (`gpu-arbiter`)** - coordinates workload lifecycle between vLLM and Dreamcast gaming sessions on `nv-01`. Scaling uses the `deployments/scale` subresource; a backwards `client.MergeFrom` previously emitted `{"spec":{"replicas":null}}`, deleting the field so it defaulted back to `1` and vLLM never actually scaled down; and status is written with a full `Status().Update()` rather than a JSON merge patch so zero-valued `omitempty` fields like `gamePods` clear instead of going stale. Arbitration avoids simultaneous peak power draw across both 5090s and protects against Xid 109 context switch timeouts during sessions.
- **`GBM_BACKENDS_PATH`** - set on both the Wolf sidecar and the Steam container; the CDI hook drops the NVIDIA GBM backend in `/usr/local/lib/gbm` while Mesa only searches `/usr/lib/x86_64-linux-gnu/gbm`.
- **Patched Wolf compositor (wl_drm fix)** - Wolf's `gst-wayland-display` advertised both the legacy `wl_drm` global and `zwp_linux_dmabuf_v1` v4 feedback; nested wlroots (Sway 0.19+) binds both and aborts on the duplicate device announcement (`assert(wl->drm_render_name == NULL)`). The patched `shrinedogg/wolf` image skips `wl_drm` when dmabuf v4 feedback is active (legacy clients can opt back in with `GST_WAYLAND_DISPLAY_ADVERTISE_WL_DRM=1`). This was needed to try Sway as the compositor; the Steam app now runs under Gamescope instead, but the patch stays deployed so Sway remains a working option (and Gamescope's Wayland client path is unaffected either way).
- **Gamescope and Vulkan device pinning (`VK_DRIVER_FILES`)** - `nv-01` physically exposes three GPU adapters: the AMD Ryzen 7800X3D integrated graphics (RADV `RAPHAEL_MENDOCINO`, PCI `1002:164e`, `/dev/dri/renderD128`) and the dual RTX 5090 dGPUs (`10de:2b85`, `/dev/dri/renderD129` and `renderD130`). Because the Steam container is privileged (for `uinput` hotplug), it sees all adapters. Mesa's Vulkan loader enumerates AMD as device 0 by default, causing Gamescope to abort on modifier negotiation. Setting `VK_DRIVER_FILES=/etc/vulkan/icd.d/nvidia_icd.json` restricts the Vulkan loader strictly to the NVIDIA ICD so only the RTX 5090s are exposed to Steam, DXVK, vkd3d, and Gamescope.
- **`/dev/shm` sizing** - a 4Gi memory-backed `emptyDir` at `/dev/shm`; the 64Mi runtime default exhausts instantly under Steam's CEF UI, yielding a black screen with only a cursor.
- **User namespaces** - Steam's pressure-vessel runtime requires `user.max_user_namespaces`, which Talos defaults to `0`. Enabled cluster-wide via Omni machine-config patches on every node (node-level config, not in this repo); also used by the `auth` workload, which runs with `hostUsers: false` so its containers' root maps to an unprivileged host UID.
- **Privileged Steam container** - Wolf hotplugs `uinput` devices mid-session; Kubernetes has no equivalent of Docker's `device_cgroup_rules`, so the container must be privileged to open the late-appearing `/dev/input/event`* nodes.
- **Root Wolf entrypoint** - a ConfigMap (`wolf-entrypoint.yaml`) shadows the GOW `/entrypoint.sh` to force the Wolf sidecar to run as root, avoiding the upstream `gosu`/`supervisord` privilege-drop crash loop. (Re-declaring `PUID`/`PGID`/`UNAME` is rejected by server-side apply as duplicate map keys.)
- **DRM render-node override** - `wolfConfig.runtimeVariables.renderNode` defaults to `/dev/dri/renderD129`, but with two 5090s the device plugin may allocate the Wolf sidecar the other card, and CDI injects only that card's node (`renderD130`) with host numbering (`renderD128` does not exist inside the container). With a node that is not present Wolf fails GPU vendor detection, falls back to software x264/x265, and `waylanddisplaysrc` cannot open the node, so the Wayland display never starts: the app container loops on `Waiting for wayland display...` and Moonlight connects (RTSP/audio work) but shows no video. The root entrypoint ConfigMap (`wolf-entrypoint.yaml`) therefore checks `WOLF_RENDER_NODE` at boot and, if absent, exports the injected NVIDIA render node (vendor `0x10de` in `/sys/class/drm`) before starting Wolf. Wolf reads the variable once at config load and every session app inherits it. Open follow-up: the sidecar and the privileged Steam container can still be allocated different 5090s.
- **In-container `udevd` (Steam Input)** - beyond the `wolf-agent` fake-udev (which surfaces the Moonlight controller), the Steam app runs a real `systemd-udevd` + `udevadm trigger`. Steam Input emulates a second uinput pad for the game, and without an in-container udevd nothing writes its udev db entry / libudev event, so SDL/Proton see no controller in-game.
- **Focus guard (Sway only, currently dormant)** - a small Python/Xlib watcher (`focus-guard.py`) in the Steam container. Steam's `steamwebhelper` maps an invisible, class-less notification popup that steals X input focus from the running game; Gamescope pins focus to the game (so the guard is unnecessary under the current Gamescope config), but Sway honors the grab, breaking keyboard + Steam Input routing. The guard returns focus to the viewable `steam_app_*` window whenever an unnamed/class-less window holds it (legitimate Big Picture focus changes are left alone). It is gated on `if [ "$RUN_SWAY" = "true" ]`, so under Gamescope the script is written but never launched.
- **PulseAudio device names** - the Steam app deliberately does **not** export `PULSE_SINK`/`PULSE_SOURCE`. The image has no `pactl`, so the upstream lookup exported empty/bogus names; libpulse treats a set-but-invalid device as an explicit request and fails the stream (silent Steam) instead of falling back to Wolf's default virtual sink.
- **No `NVIDIA_DRIVER_CAPABILITIES` on the app container** - the operator already appends `NVIDIA_DRIVER_CAPABILITIES=all` to the app container (`session.go`); re-declaring it makes the server-side-apply patch invalid (duplicate map key) so the Deployment is never created and the reaper kills the session after 60s. (Same failure class as the root-entrypoint `PUID` note above.)
- **DLSS / NVAPI under Proton** - DLSS needs two things on Talos. (1) The `nonfree-kmod-nvidia` extension strips the NVIDIA "wine" NGX bridge DLLs (`nvngx.dll` / `_nvngx.dll`), so an `nvngx-bridge` initContainer extracts them from the matching driver `.run` and caches them on the `nvngx-cache` host-path PVC (downloaded at most once); Proton copies them into each prefix's `system32` when `PROTON_ENABLE_NVAPI=1`. (2) DLSS is gated behind NVAPI, so `PROTON_ENABLE_NVAPI=1` + `DXVK_ENABLE_NVAPI=1` are set on the Steam container, otherwise the in-game DLSS toggle stays greyed out despite the RTX GPU.

## Core Components Detail

### Networking Stack

Both clusters run **Cilium** as the CNI (replaces kube-proxy) and **Gateway API** with **AgentGateway** (OCI HelmRelease, charts pinned to a verified build), but they advertise service VIPs differently:

- **`cluster1` (on-prem workloads)** - Cilium **BGP** peers with the UDM router (local ASN 64564 <-> peer 64563 at `192.168.1.1`), advertising the `192.168.6.6-254` pool (off-subnet from the nodes on `192.168.2.0/24`, so VIPs route via the UDM).
- **`cluster0` (on-prem management)** - single-node, so it uses a Cilium **L2 announcement** policy with a single-IP pool (`192.168.2.31/32`), shared across `cluster0-gateway` and `omni-siderolink` via the `cluster0-edge` sharing key.

`cluster1` split-horizon DNS:
- **k8s-gateway** - authoritative for `*.biggs.dog` (LB `192.168.6.6`, ClusterIP `10.101.183.97`, 2 replicas); resolves internal gateway VIPs in-cluster and external gateway VIPs for LAN clients.
- **CoreDNS** (Talos-managed `kube-dns`) conditionally forwards `biggs.dog` queries to k8s-gateway's ClusterIP (`10.101.183.97`) instead of Cloudflare, keeping pod traffic in-cluster.
- **lan-dns** - LAN CoreDNS resolver (LB `192.168.6.16`) forwards `biggs.dog` -> k8s-gateway and everything else -> NextDNS over DoT (`tls://45.90.28.0`, `tls://45.90.30.0`).

`cluster0` ingress is `cluster0-gateway` (`networking` namespace) with HTTPS listeners for `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog`, each backed by a per-host cert issued in the `networking` namespace (Gateway API resolves name-only `certificateRefs` to the gateway's own namespace) via the `letsencrypt-prod` ClusterIssuer (DNS-01/Cloudflare). Omni re-encrypts to its pod cert over HTTPS.

**k8s-gateway fallthrough:** `cluster1`'s k8s-gateway has **fallthrough enabled** with NextDNS resolvers (`45.90.28.232` / `45.90.30.232`) so unknown `biggs.dog` names resolve to public DNS. Before fallthrough, both `k8s-gateway` and `lan-dns` carry a `hosts` block mapping `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog` to `192.168.2.31` locally: public DNS for these is Cloudflare-proxied, and the Cloudflare edge answers gRPC with a 403 challenge page that breaks omnictl and Omni-proxied kubeconfigs from the LAN. The chart's default `forward . /etc/resolv.conf` plugin was replaced because it loops: k8s-gateway -> `/etc/resolv.conf` -> in-cluster CoreDNS -> k8s-gateway again (CoreDNS conditionally forwards `biggs.dog` to k8s-gateway's ClusterIP), resulting in SERVFAIL. The fix replicates the full chart default plugin list with only the forward parameters changed to NextDNS IPs. The `ready`/`health`/`prometheus` plugins remain for liveness/readiness probes and ServiceMonitor.

**Omni BackendTLSPolicy** - Omni serves its own HTTPS (the omni binary runs with `--cert/--key` on `:443` with a Let's Encrypt cert for `omni.biggs.dog`). The cluster0-gateway terminates client TLS at the omni-https listener, then must re-encrypt to omni-ui over HTTPS. The HTTPRoute annotation `agentgateway.dev/backend-protocol: "HTTPS"` declares that intent, but agentgateway only actually speaks TLS to the backend when a `BackendTLSPolicy` tells it what hostname/SNI to use and what CA to trust. Without this policy, agentgateway sent plain HTTP to omni-ui:443 -> omni's TLS server rejected it (`Client sent an HTTP request to an HTTPS server`). The policy uses `wellKnownCACertificates: System` (trusts the public CA that signed omni's Let's Encrypt cert - ISRG Root X1) and `hostname: omni.biggs.dog`.

### Storage Layers

- **Rook-Ceph** - distributed block storage (`ceph-block` StorageClass, pool `ceph-blockpool` size 3) on four OSDs, one Micron 7450 960 GB NVMe per worker. Rook v1.20 (chart `v1.20.6`) no longer deploys CSI itself: the `Driver`/`OperatorConfig` CRs for the ceph-csi-operator live in `rook-ceph/csi-rbac/drivers.yaml` next to the driver RBAC; without them no provisioner or nodeplugin runs. OSD devices are named by `/dev/disk/by-id/nvme-Micron_7450_..._<serial>`, never `/dev/nvmeXn1` (see Storage pitfalls). Cluster fsid `37a406cf-68c2-4131-96e7-f7b7c050b2c4` survived the 2026-09-07 rebuild via the mon-store adoption procedure in `.omni/cluster1/` (plan `2026-09-07_000000-cluster1-rebuild-selfhosted-omni-ceph-preserved`).
- **OpenEBS** - local container-attached storage (ZFS and local disk via localpv host-path provisioner, chart `4.6.0` on both clusters).
- **Volsync** - bidirectional backup and replication of PVs (chart `0.16.0`) to Backblaze B2. Cache PVCs pinned to `ceph-block`.
- **Snapshot Controller** - CSI volume snapshots (chart `5.2.0`).
- **NFS CSI** - NFS provisioner for shared namespaces (chart `4.13.4`).
- **ZFS** - volume management on nodes with ZFS pools.

### Database and Caching

- **CNPG** - PostgreSQL operator managing in-cluster Postgres clusters (chart `0.29.0`, used by Pocket ID, kagent, and others; PG18 minimal Trixie image catalog).
- **Barman Cloud** - CNPG plugin (`0.7.1`) for backup/recovery to object storage.
- **Dragonfly** - Redis-compatible in-memory store (used by OAuth2 Proxy for session storage and other services).

### Security Model

Secrets follow a three-tier model:

1. **SOPS + age** - Git-encrypted secrets (for config that can be committed, e.g., Cilium policies, app defaults).
2. **External Secrets + 1Password** - Runtime secrets synced from 1Password vaults (chart `2.9.0` with 1Password Connect chart `v2.4.1`).
3. **cert-manager** - Automatic certificate issuance and renewal (chart `v1.21.1`, ACME Let's Encrypt, CA issuer for self-signed).

### Mindwtr (Notes App)

Mindwtr (`mindwtr` namespace) is a self-hosted, offline-capable notes PWA (`mindwtr-app`, static nginx build) paired with a sync/REST server (`mindwtr-cloud`) that stores a single JSON store + attachments on an RWO PVC (`strategy: Recreate`, since only one writer can hold the store). Both are fronted by a single `mindwtr.biggs.dog` HTTPRoute on the LAN-only `internal-biggs-dog` gateway, path-split three ways:

- `/health` and `/v1` route straight to `mindwtr-cloud` and are **bearer-token only** (`MINDWTR_CLOUD_AUTH_TOKENS`, from the `mindwtr-cloud-auth` ExternalSecret); upstream Mindwtr's mobile/desktop/CLI clients cannot complete an interactive OIDC login, so this path deliberately bypasses SSO.
- `/` (the PWA, named rule `pwa`) is fronted by a Pocket-ID-backed `AgentgatewayPolicy` (`mindwtr-forward-auth`) that targets the HTTPRoute by `sectionName: pwa`, so only the browser path gets the shared `.biggs.dog` oauth2-proxy cookie SSO; the API rules are untouched.

`mindwtr-cloud` trusts `X-Forwarded-For` from the pod CIDR (`MINDWTR_CLOUD_TRUST_PROXY_HEADERS`/`_TRUSTED_PROXY_IPS`) since agentgateway is the only ingress path under Cilium default-deny, so its auth-failure rate limiter sees real client IPs instead of bucketing everything against the gateway address.

### Network Policies and Cilium Configuration

The cluster enforces least-privilege **CiliumNetworkPolicy** across all namespaces. Policies are split into two independent Flux Kustomizations:

- **`network-policies-apps`** - application namespaces (auth, biggs, dragonfly, dreamcast, games, livekit, matrix, media, mindwtr, renovate on cluster1; auth, omni on cluster0). Can be updated with confidence.
- **`network-policies-infra`** - infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, kube-system on cluster1; capi, cert-manager, external-secrets, flux-system, networking on cluster0). Can be suspended independently with `flux suspend kustomization network-policies-infra` if edge or control plane regresses.

This two-tier approach allows staged rollouts and rapid rollback without affecting application policies.

**Key Cilium policy conventions** (each is documented inline in the policy files):

- **Default-deny is implicit.** Cilium rejects an empty deny-all (`ingress: [] / egress: []` -> `VALID: False`), so there is no standalone deny-all policy. Every namespace's `allow-*` policies select `endpointSelector: {}`, which puts all pods into default-deny for any traffic not explicitly allowed.
- **L7 DNS on every `allow-egress-dns`.** A bare L3/L4 DNS allow lets Go resolvers' rapid parallel A/AAAA replies miss the egress conntrack entry and get dropped as new ingress. Routing DNS through the Cilium DNS proxy (`rules.dns: matchPattern "*"`) fixes that and enables `toFQDNs` (used for GitHub, the OIDC issuer, Backblaze B2, etc.).
- **ClusterIP service return paths.** With `bpf-lb` + default-deny ingress, replies from a ClusterIP service (e.g. CNPG `-rw` Postgres) arrive reverse-NAT'd from the service VIP and miss conntrack, so DB clients carry an explicit `allow-ingress-from-postgres` return-path rule.
- **Gateway data planes** are selected by `gateway.networking.k8s.io/gateway-class-name: agentgateway` (one Deployment per Gateway, e.g. `wildcard-biggs-dog`) - distinct from the control-plane `agentgateway` pod - so `*.biggs.dog` ingress and backend forwarding are authorized.
- **Internet pulls hide behind caches.** Default-deny egress silently breaks anything that reaches out only occasionally; e.g. vLLM downloads a new model from Hugging Face but loads already-cached ones from its PVC, so blocked egress only surfaces on a model swap. Such components (`allow-egress-vllm-huggingface`, renovate's `allow-egress-https`, volsync->Backblaze B2) carry an explicit egress allow, scoped to the pod and kept broad on `:443` where the upstream uses rotating CDN/Xet hosts with no stable FQDN set.

### Identity and SSO Details

The two clusters run different identity stacks (a deliberate split: the management cluster needs an always-on IdP reachable before any on-prem dependency is up; the workload cluster uses the passkey-first stack for its apps).

**Dex** (`cluster0`, `dex.biggs.dog`) - root OIDC IdP for the management plane:
- `ghcr.io/dexidp/dex:v2.45.1`, stateless (`storage.type: memory`, single replica; tokens do not survive restarts, fine for interactive logins).
- `enablePasswordDB: true` with a static admin user; clients/secrets templated into the config from 1Password.
- Static clients: `omni` (Omni OIDC login), `image-factory` (Image Factory UI).
- **Omni's OIDC callback** - the actual callback path is `/oidc/consume` (not `/Callback` or `/callback`).
- **Image Factory** - the Image Factory UI at `factory.biggs.dog` uses an `oauth2-proxy` authenticated against Dex. The proxy upstreams to `image-factory.omni.svc.cluster.local:8080`. The HTTPRoute path-splits: API paths go directly to image-factory, UI paths (`/` and `/oauth2/*`) go through the proxy.
- `connectors: []` - Dex is the root IdP here, not a federator in front of Pocket ID.

**Pocket ID** (`cluster1`, `id.biggs.dog`) - passkey-first OIDC for workload apps:
- Passkey-first OIDC provider (`v2.14.0`, FIDO2 WebAuthn).
- Postgres backend via CNPG (user database, secret storage).
- File uploads stored in the same database.

**OAuth2 Proxy** (`cluster1`, `auth.biggs.dog`):
- OIDC client to Pocket ID (image `v7.15.4`, chart `10.7.0`).
- Provides forward-auth for browser apps (agentgateway `AgentgatewayPolicy` with `traffic.extAuth`).
- Uses **Dragonfly (Redis)** for session storage (small session ticket instead of large cookie).
- Protected apps attach a `ReferenceGrant` to reach the OAuth2 Proxy service in the `auth` namespace.

**Protected apps (`cluster1`):**
- Rook-Ceph dashboard
- Bookboss
- kagent UI
- Mindwtr PWA (browser rule only, targeted by `sectionName`; the `/v1` sync + REST API rules stay bearer-token-only - see [Mindwtr](#mindwtr-notes-app))

**Native OIDC apps (`cluster1`):**
- Grafana (direct Pocket ID client, no forward-auth needed)

### Observability Stack

- **VictoriaMetrics** - metrics storage (`victoria-metrics-k8s-stack` chart `0.91.2`).
- **VictoriaLogs** - log aggregation and storage (chart `0.13.9` single, `0.3.7` collector).
- **Grafana Operator** - Grafana deployment and dashboard management (chart `10.5.15`, dashboards stored as CRDs).

The DCGM exporter (NVIDIA GPU metrics) feeds into VictoriaMetrics, and the `gpu-arbiter-operator` queries it via the VictoriaMetrics HTTP API.

### System and Hardware

- **NFD** (Node Feature Discovery) - detects hardware capabilities (GPU models, CPU flags, etc.) and labels nodes.
- **Intel GPU Plugin** - enables Intel iGPU device plugin for media transcoding on worker nodes.
- **NVIDIA GPU Operator** - device plugin with time-slicing (chart `v26.7.0`; driver and toolkit provided by Talos system extensions).
- **Omni (Sidero)** - run in-cluster on `cluster0` (`apps/omni/`, image `ghcr.io/siderolabs/omni:v1.10.5`) as the full Talos management plane (UI at `omni.biggs.dog`, machine API `:8090`, event sink `:8091`, K8s proxy `:8100`, Siderolink WireGuard `:50180/udp` advertised at `192.168.2.31:50180`). Sole manager of `cluster1` (the hosted Sidero SaaS Omni is retired). Node join is via the generic ISO from `factory.biggs.dog` (control-01 needs the `control-01-bond` media preset because its switch ports are a static LACP aggregate). Machine templates and per-machine patches: `.omni/cluster1/self-hosted/` (git-ignored, `omnictl cluster template sync -f cluster-template.yaml`). Hardware template tracks `nv-01`'s dual RTX 5090 topology (ASRock X870E Taichi Lite x8/x8 bifurcation, ASUS TUF in slot 1, Zotac AMP Extreme Infinity upright in slot 2 via 900mm riser, Lian Li O11D EVO XL, 1600W PSU, Sidero kernel-signed open GPU modules 595.71.05). LAN clients must resolve `omni.biggs.dog` to `192.168.2.31`: both `k8s-gateway` and `lan-dns` carry a `hosts` block for edge names because the Cloudflare-proxied public answer 403s gRPC. Runs privileged with `/dev/net/tun`; double-TLS via `BackendTLSPolicy`. Backed by embedded etcd + SQLite PVCs on OpenEBS; OIDC login via Dex.
- **Talos Image Factory** - builds and signs custom Talos Linux images with cosign (`ghcr.io/siderolabs/image-factory:v1.6.0`). Stateless HTTP service on `:8080` behind an `oauth2-proxy` authenticated against Dex at `factory.biggs.dog`. Durable state lives in a registry PVC. cosign signing key and public key are mounted as Secrets. Rate-limit policy and an embedded OCI registry (`registry-deployment`) are also deployed.
- **Cluster API (CAPI) on `cluster0`** - CAPI operator (`0.28.0`), core CAPI `v1.14`, CABPT `v0.7.6`, CACPPT `v0.6.4`, and CAPT `v0.7.1` (Tinkerbell) manage the management node. Manifests live in `clusters/cluster0/capi/`.
- **`nv-01` Dual-GPU Node Hardware** - AMD Ryzen 7 7800X3D (8C / 16T), 64 GB DDR5 RAM, dual NVIDIA GeForce RTX 5090 dGPUs (ASUS TUF in PCIe slot 1 + Zotac AMP Extreme Infinity upright in PCIe slot 2 via 900mm riser, 64 GB total GDDR7 VRAM), ASRock X870E Taichi Lite motherboard (PCIe 5.0 x8/x8 bifurcation), Lian Li O11D EVO XL chassis, 1600W PSU, Samsung 9100 PRO 1TB install disk, Realtek RTL8126 5GbE NIC (`enp9s0`), and Sidero Talos kernel-signed open GPU modules (`595.71.05`).
- **Per-machine Omni `ConfigPatch`es** - node-level config lives in Omni as per-machine `ConfigPatch`es (each node carries a `10-<machine-id>` user patch: hostname, NIC rings, node-specific tweaks). Local copies live under `.omni/cluster1/self-hosted/` (git-ignored). Inspect/apply with `omnictl` (`omnictl get configpatch`, `omnictl apply -f ...`). CoreDNS is configured cluster-wide via the `coredns-custom` inline-manifest patch (scoped to the cluster, not per node). When setting an explicit `HostnameConfig.hostname` on a directly-scaled node, also `$patch: delete` the default `auto` field, or Talos rejects the config (`'auto' and 'hostname' cannot be set at the same time`).

### Automation

- **Renovate** - automated dependency updates for HelmRelease chart versions and container images referenced in Kubernetes manifests (`ghcr.io/mend/renovate-ce:15.4.0`). Configured in `renovate.json`.

## AI and Agents Architecture

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack. The vLLM and kagent infrastructure is shared; agent-specific configs are in [`.rules`](.rules).

### vLLM Deployment

- **Model**: [`unsloth/Qwen3.8-27B-NVFP4`](https://huggingface.co/unsloth/Qwen3.8-27B-NVFP4) (served as `qwen 3.8 - local`) - a **27B dense** model with a **Gated-DeltaNet / gated-attention hybrid** (only 16 of 64 layers keep paged KV), NVFP4 via compressed-tensors (~19.9 GB on disk / ~18 GiB resident on a 32 GB card). **173K context** served (`--max-model-len=177184`; native max 262K).
- **Version**: `docker.io/vllm/vllm-openai:v0.28.0` (CUDA 12.9 for Blackwell GPU support on RTX 5090).
- **GPU**: Deployed on `nv-01`'s dual RTX 5090 platform (64 GB total VRAM). vLLM currently runs with a single-card 32 GB allocation (~18 GiB weights + 5.71 GiB KV cache at 173K context), leaving the second 5090 available for multi-GPU scaling (`-tp 2`) or dedicated streaming isolation.
- **Scaling**: Idle = 1 replica; gaming session = 0 replicas (managed by `gpu-arbiter-operator`).
- **API**: OpenAI-compatible (`/v1/chat/completions`, etc.) at `http://vllm.ai-system.svc:8000`.

### vLLM Configuration and Performance

**Context cap rationale**: The model's native max is 262K. It is served at 173K (`--max-model-len=177184`) as vLLM's measured ceiling for this quant at util 0.96 (yielding 5.71 GiB available fp8 KV cache). The Gated-DeltaNet hybrid keeps most layers' KV bounded, ensuring long-context prompts remain performant.

**Configuration details** (from `clusters/cluster1/kubernetes/apps/ai-system/vllm/app/deployment.yaml`):
- **`--max-model-len 177184` (173K)** - measured ceiling providing headroom over large `exa-agent` sessions (~164K tokens).
- **`--max-num-seqs 8` / `--max-cudagraph-capture-size 8`** - concurrency cap sized for the dense 27B model on 5.71 GiB KV cache (where one max-length prompt takes most of the pool).
- **`--gpu-memory-utilization 0.96`** - documented ceiling leaving headroom for CUDA graph allocation. (Util 0.97 contributed to a node lockup when embeddings also ran on GPU).
- **`--max-num-batched-tokens 8192`** - reduces prefill scheduling rounds for medium tool prompts.
- **`--kv-cache-dtype fp8`**.
- **Quantization**: auto-detected `compressed-tensors` NVFP4 from the checkpoint; no `--quantization` flag is passed.
- **Tool-call parser**: `--tool-call-parser qwen3_coder` + `--reasoning-parser qwen3` (with `--enable-auto-tool-choice`), paired with the model's built-in chat template.
- **`--language-model-only`** - skips the vision encoder on this checkpoint, preserving ~3 GB of VRAM for KV cache.
- `--enable-prefix-caching`, `--trust-remote-code`.

**Model right-sizing (history)**:
1. `NeuralNet-Hub/Qwen3.6-27B-NVFP4` (suboptimal `llm-compressor` quant validated only on 48 GB card; util pinned near 0.984, 65K context max, OOM / cache block starvation).
2. `Gemma-4-26B-A4B` (14B on disk, sliding-window attention, 256K context; resolved OOM churn).
3. `nvidia/Qwen3.6-35B-A3B-NVFP4` (35B MoE, ~19B on disk, Mamba-hybrid, served at 131K).
4. `rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm` (27B dense, ~18 GiB resident, 192K context).
5. `unsloth/Qwen3.6-27B-NVFP4` (dense quant with BF16 vision/embeddings, ~23 GiB resident, 177184 ceiling with 5.71 GiB KV).
6. `unsloth/Qwen3.8-27B-NVFP4` (current: Unsloth Dynamic V3.0, ~19.9 GB disk / ~18 GiB resident, Gated-DeltaNet hybrid attention with only 16 of 64 layers keeping paged KV, 173K context at util 0.96 and 8-way concurrency).

### Embeddings Service

- **Model**: `BAAI/bge-m3` (Infinity embedding server, CPU-only).
- **Deployment**: `michaelf34/infinity:latest-cpu` with PyTorch backend.
- **Port**: 7997 (internal service).
- **API**: OpenAI-compatible `/v1/embeddings` endpoint.
- **Usage**: Backing kagent's long-term vector memory via the `embedding-model` ModelConfig.
- **CPU-only by design**: The dual RTX 5090s on `nv-01` are reserved for LLM inference and game streaming. Running embeddings on CPU avoids unnecessary VRAM reservation and maintains clean separation.

### kagent Agents

The 11 agents split across two deployment patterns: classic `kind: Agent` CRs (python runtime, each its own Deployment) and `kind: SandboxAgent` CRs on the substrate runtime (gVisor-sandboxed actors):

**Classic `kind: Agent` CRs** (invocable via MCP) - python runtime, each runs as its own Deployment:
- `flux-agent` (read-only) - Flux GitOps inspection (custom, `clusters/cluster1/kubernetes/apps/ai-system/flux-mcp/`).
- `vm-agent` - VictoriaMetrics query + TSDB analysis (custom, `clusters/cluster1/kubernetes/apps/ai-system/victoria-metrics-mcp/`).
- `exa-agent` - Web search and research (custom, `clusters/cluster1/kubernetes/apps/ai-system/exa-mcp/`).
- `cilium-debug-agent` - Cilium diagnosis (static, `clusters/cluster1/kubernetes/apps/ai-system/kagent/cilium-agents/`; carries generic `k8s_*` tools).
- `cilium-policy-agent` - Cilium policy authoring (static, `clusters/cluster1/kubernetes/apps/ai-system/kagent/cilium-agents/`; carries generic `k8s_*` tools).
- `codebase-agent` - Structural code intelligence over indexed repos (custom, `clusters/cluster1/kubernetes/apps/ai-system/codebase-memory-mcp/`).
- `mindwtr-agent` - Mindwtr task management (custom, `clusters/cluster1/kubernetes/apps/ai-system/mindwtr-mcp/`).

**`kind: SandboxAgent` CRs on the substrate runtime** (`clusters/cluster1/kubernetes/apps/ai-system/kagent/substrate-agents/`, `platform: substrate`, `workerPoolRef: kagent-default`):
- `k8s-agent` - general Kubernetes inspection/troubleshooting.
- `observability-agent` - metrics, dashboards, alerting.
- `promql-agent` - PromQL query generation.
- `helm-agent` - Helm release management.
- `cilium-manager-agent` - Cilium install/config/upgrade.

These five are `ACCEPTED=True` / `READY=True` (golden actors built; ActorTemplates in `Ready` phase, upserted into kagent Postgres `agents` table) and are listed by the kagent REST API (`/agents`, kagent-ui), but are not yet invocable via the MCP server (`list_agents` omits them; `invoke_agent` returns "not found"). See [Agent Sandbox and Code Execution](#agent-sandbox-and-code-execution) for the root cause and [`.rules`](.rules) fallbacks.

**Disabled chart agents**: `argo-rollouts-agent`, `istio-agent`, `kgateway-agent` (plus the 5 substrate agents and 2 cilium agents are disabled in the chart to prevent duplicate classic Agent CRs).

### Agent Sandbox and Code Execution

There are two sandboxing mechanisms deployed in `ai-system`:

1. **SIG-Apps `Sandbox` CRD + controller** (`agents.x-k8s.io`, GitRepository ref `v1.0.0` with `controller.extensions: true`), which provides isolated, stateful single-pod runtimes for classic `kind: Agent` CRs that opt into `executeCodeBlocks`. All classic agents are configured with code execution enabled.
2. **kagent substrate runtime (ATE / actor runtime)** - a separate control plane for sandboxed code execution via **gVisor**, used by `kind: SandboxAgent` CRs. See [Substrate Runtime](#substrate-runtime) below.

**Two hard requirements**:

1. **Ingress from the kube-apiserver to the conversion webhook (`:9443`) must be allowed.** `ai-system` runs implicit Cilium default-deny ingress (`allow-intra-namespace` selects `endpointSelector: {}`), and the apiserver runs host-network on a remote control-plane node, so it is not covered by Cilium's allow-localhost exemption. Without an explicit allow, every Sandbox conversion the apiserver issues is silently dropped: the controller crash-loops on cache-sync, `kubectl get sandboxes` hangs, and anything creating a `Sandbox` stalls to a 30s timeout. Handled by the `allow-ingress-apiserver-to-sandbox-webhook` CiliumNetworkPolicy in `clusters/cluster1/kubernetes/apps/network-policies/policies/infra/ai-system.yaml` (`fromEntities: [kube-apiserver]` -> `:9443`).
2. **`SandboxAgent` agents run but are not yet MCP-invocable.** Upstream kagent's `MCPHandler.listReadyAgents` lists only `v1alpha2.AgentList` and hard-codes `condition.Reason == "DeploymentReady"`; substrate agents report `WorkloadReady`. So substrate agents are excluded from `list_agents`, and `invoke_agent` returns "agent not found or not ready". Until upstream resolves this, use [`.rules`](.rules) fallbacks or direct `kubectl` for the 5 substrate agents.

### Substrate Runtime

The kagent **substrate** (ATE / actor runtime) is deployed in `clusters/cluster1/kubernetes/apps/ai-system/substrate/` (+ `substrate-crds/`) and backs the 5 `SandboxAgent` agents.
- **Charts**: `substrate` and `substrate-crds` at `0.0.21` (`sources/substrate-oci.yaml`, `sources/substrate-crds-oci.yaml`).
- **Worker pool**: `kagent-default`, `sandboxClass: gvisor`, `ateomImage: ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.21` in kagent HelmRelease.
- **Components**: `ate-controller`, `ate-api-server` (Deployment `ate-api-server-deployment`, running digest-pinned image `docker.io/shrinedogg/ateapi@sha256:78d90103f3054bf6544bf3726fa63800a47b970b3425a3e60f4efbfff9bbdad3` with `--client-jwt-jwks-url`), `atelet` worker DaemonSet, and `atenet-router`.
- **Storage**: Postgres StatefulSet volumeClaimTemplate and `rustfs-data` PVC are patched to `storageClassName: host-path` via HelmRelease postRenderers.
- **RBAC**: Manifest `clusters/cluster1/kubernetes/apps/ai-system/substrate/app/ate-system-namespace.yaml` creates the `ate-system` namespace to satisfy chart RBAC.
- **Assets**: gVisor `runsc` (`20260622.0`) staged in rustfs and pre-cached per node via `runsc-cache` DaemonSet.

**Drift correction (`driftDetection: {mode: enabled}`)**: the substrate `HelmRelease` runs Flux server-side dry-run drift detection on every reconcile, ensuring any out-of-band deletes or edits are reverted to git state.

### Long-Term Memory

kagent is configured with vectorized memory backed by CNPG Postgres + pgvector, using the `embeddings` service for vector embeddings. Per-agent memory is disabled on `flux-agent` because its large tool schemas push context towards saturation. All other classic agents have memory enabled. `exa-agent` sets `context.compaction` at 80K tokens and pairs with the 173K vLLM cap to absorb large search results without overflow.

### MCP Servers

- **Flux Operator MCP** (`flux-agent`) - read-only inspection of `FluxInstance`, sources, Kustomizations, HelmReleases, ResourceSets.
- **VictoriaMetrics MCP** (`vm-agent`) - PromQL/MetricsQL queries, alerting rules, TSDB cardinality analysis, embedded VM docs.
- **Exa MCP** (`exa-agent`) - Web search, code discovery, company research.
- **codebase-memory-mcp** (`codebase-agent`) - code intelligence over indexed repos (tree-sitter -> SQLite knowledge graph + bundled semantic search; 15 tools). Wrapped in `mcp-proxy` bridge with git-sync native sidecar.
- **mindwtr-mcp** (`mindwtr-agent`) - GTD task management against the Mindwtr SQLite database.
- **Kubernetes API** (all agents) - native k8s API via controller-runtime client.

### MCP Exposure and Routing

The MCP endpoint is the `kagent-mcp` HTTPRoute (`https://mcp.biggs.dog/mcp`) on the internal gateway `internal-biggs-dog` (VIP `192.168.6.15`). k8s-gateway split-horizon resolves `mcp.biggs.dog` to `.6.15` for LAN/VPN clients; TLS terminates at the gateway with the wildcard cert. WAN clients hitting the public gateway get a 404 (no route).

## Cluster Bootstrapping

Each cluster bootstraps via its own **Flux Operator** syncing from `https://github.com/shrinedogg/biggs.dog.git` (main branch).

- `cluster0` bootstraps via `knr-bootstrap local-talos` using `bootstrap.toml`, syncing `clusters/cluster0/capi` initially, then widening to `clusters/cluster0`.
- `cluster1` is managed by self-hosted Omni on `cluster0` and syncs `clusters/cluster1`.

On each cluster, Flux reconciles:
1. **FluxInstance** (Flux system components).
2. **Sources** (GitRepository, HelmRepository, OCIRepository).
3. **Kustomizations** and **HelmReleases** (ordered via `dependsOn`).

Flux pruning is currently disabled on both root syncs as a migration safety measure. Secrets are decrypted by SOPS (age key) before Flux applies them.

## Dependency Update Workflow

Renovate scans the repo for:
- `HelmRelease` chart versions (with source URLs).
- Container image tags referenced in Kubernetes manifests.
- `renovate.json` config (grouping, scheduling, etc.).

On a match, Renovate opens a PR with updated versions. Once merged, Flux reconciles automatically.

## Common Pitfalls and Lessons Learned

### GPU Scaling

- **Do not use JSON merge patch for zero-valued fields** - `omitempty` drops zero values, so status fields like `gamePods: 0` will not persist. Use `Status().Update()` for authoritative writes.
- **Use the `deployments/scale` subresource** - cleaner than a full deployment patch, matches RBAC grants, and avoids null-value bugs.
- **vLLM Deployment intentionally omits `spec.replicas`** - defaults to 1, so Flux does not fight the arbiter over the count.

### Fenrir and Games on Whales

- **Labels on pod templates do not survive** - Fenrir strips `metadata.labels` from App CR templates. Live pods get labels from Fenrir's generated selectors, not the CR.
- **Cold start latency** - image pulls + Wolf boot + agent readiness can exceed 25s, so moonlight-proxy timeout needed to be raised to 120s.
- **Controller retries** - direwolf-operator was stalling on reconcile retries; the fork adds automatic retries and prunes stale session entries.

### Networking

- **CoreDNS patching for split-horizon DNS** - hairpinning traffic out through the external gateway wastes bandwidth. Patching CoreDNS to forward `biggs.dog` queries to k8s-gateway keeps pods in-cluster.
- **CiliumNetworkPolicy learning curve** - start with permissive policies and tighten incrementally. Two-tier (apps + infra) allows staged rollouts.
- **Talos CoreDNS label is `coredns`, not `kube-dns`** - all `allow-egress-dns` policies initially targeted `k8s:k8s-app: kube-dns`, but Talos deploys CoreDNS with `k8s-app=coredns`. This dropped every namespace's DNS under default-deny. Fix: use `k8s-app: coredns` in policy selectors.
- **Cilium webhook ports** - cert-manager and external-secrets webhook Services map `:443` to container port `:10250`. Cilium's kube-proxy replacement delivers traffic on the container port, so CNP ingress rules must allow `:10250`, not `:443`. Diagnosed via `cilium service list`.
- **External-secrets cert-controller** - the cert-controller pod (`app.kubernetes.io/name=external-secrets-cert-controller`) manages ValidatingWebhookConfigurations and needs API server access. A narrow endpointSelector only matched the main controller pod, leaving the cert-controller blocked and crash-looping. Use `{}` endpointSelector to cover all external-secrets pods.
- **k8s-gateway ClusterIP pinning** - pinned to `10.101.183.97`. ClusterIP is immutable once assigned.
- **Cross-cluster edge names resolution** - LAN clients resolving `omni.biggs.dog`, `dex.biggs.dog`, and `factory.biggs.dog` need `hosts` blocks in `k8s-gateway` and `lan-dns` pointing to `192.168.2.31`, otherwise Cloudflare's edge returns a 403 challenge page that breaks gRPC.

### Observability

- **DCGM metrics lag** - free VRAM reports ~30s behind actual consumption. `gpu-arbiter-operator` gates on vLLM down first, then VRAM as a secondary signal.
- **VictoriaMetrics cardinality** - high cardinality metrics can inflate storage and query times. Use recording rules and aggregation.
- **VMSingle cannot run 2 replicas on one PVC** - `vmsingle`'s local storage takes an exclusive `flock` on its data directory, so a second replica sharing the same PVC fails to start. Pinned `replicaCount: 1`, raised memory limit to 8Gi, and set `useDefaultResources: false`.

### Media and Transcoding

- **Co-locate two GPU-transcode pods on one node and one starves** - Emby and Ersatz both use the Intel-iGPU `nodeSelector` (`intel.feature.node.kubernetes.io/gpu: "true"`), so with more than one Intel-GPU-capable node they could land on the same host and contend for the same iGPU. Fixed with a preferred (not required) `podAntiAffinity` on each toward the other's `app` label.

### Storage

- **Never address NVMe drives by `/dev/nvmeXn1` in anything persistent.** Enumeration order is not stable across reboots on two-drive workers: on 2026-09-07 worker-04 came up with `nvme0n1`/`nvme1n1` swapped, Talos installed onto the Ceph OSD (osd.1 wiped; size-3 pool kept data), and Rook then built a 256 GB osd.4 on the OS drive it found empty. Talos `install.diskSelector.serial`/`wwid` in the Omni template and `/dev/disk/by-id/nvme-<model>_<serial>` in Rook `storage.nodes[].devices` list are the only safe forms. Serials come from `talosctl get disks -o yaml`.
- **Omni cannot move Talos to a different disk on an installed machine.** Remove/re-add only re-runs the install onto the disk that already carries Talos, and `omnictl machine install` refuses machines that belong to a cluster. A real disk change needs: zap both drives from a privileged pod (`wipefs -a`, `sgdisk --zap-all`, zero the first and last 100 MB; the running system keeps its in-memory partition table), remove the machine from the template so Omni reboots it, let it boot the USB ISO into maintenance, then re-add. If Omni still does not install, its `ClusterMachineConfigStatus` holds a stale `prerebootbootid`; removing and re-adding the machine destroys that object and the clean-install path honours `diskSelector`.
- **Restored PVCs and Flux server-side apply.** Objects recreated with `kubectl apply` are owned by `kubectl-client-side-apply`; Flux's first SSA migrates those fields and then removes anything not in git, including `spec.volumeName`, which is immutable, so the Kustomization fails with `spec is immutable after creation`. Fix: `kubectl apply --server-side --field-manager=<other> --force-conflicts` of a manifest containing only `spec.volumeName`, so a second manager owns the field and Flux leaves it alone.
- **Rook mon-store adoption checklist.** Fresh Rook up with `mon.count: 1`, confirm new fsid and zero OSDs (prepare jobs must skip the drives as `ceph_bluestore`), stop operator + mon/mgr, replace `mon-a/data` with the captured store, keyring = the new `[mon.]` section, `monmaptool` to a single member at the mon's host IP, fsid patched into `secret/rook-ceph-mon`, `auth * required = none` via `rook-config-override` for first boot, operator back on. Re-enabling cephx needs the old `client.admin` key (from captured `ceph auth ls`) to `auth import` Rook's new `mon.`/`client.admin` keys, because the adopted store still holds the old auth database.

### Fresh-cluster CRD ordering

Things that worked on the old cluster only because objects already existed, fixed in git during the 2026-09-07 rebuild:

- A `kubernetes/apps/<ns>/<app>/` directory without `kustomization.yaml` makes Flux's auto-generated root recurse into `app/`; a single unknown kind (HTTPRoute before Gateway API CRDs) then fails the whole `flux-system` Kustomization dry-run (`livekit`).
- A CRD instance next to the HelmRelease that installs its CRD (`ClusterImageCatalog` beside the CNPG operator) fails dry-run until the operator exists; keep it in a Kustomization that `dependsOn` the operator.
- Chart values that only worked because the release already existed: `zfs-localpv` `zfsNode.securityContext` is the pod-level context, `privileged` there is rejected by server-side apply on a first install.
- Talos `inlineManifests` (the `coredns-custom` ConfigMap) apply at bootstrap only. Changing the patch later updates Omni's desired state but not the live ConfigMap; converge it once by hand with the rendered manifest.
- Talos `install.diskSelector` in a template patch, `hosts` blocks for cross-cluster names, and the Rook CSI `Driver` CR are the other three that had lived out of band.

### Secrets

- **Do not hardcode secrets** - use SOPS + age for Git-stored secrets, and External Secrets + 1Password for runtime-only secrets.
- **Session storage** - OAuth2 Proxy's session cookie can exceed 4 KB and get chunked, breaking ext-authz subrequests. Use Dragonfly (Redis) to store the session server-side and reduce the cookie to a small ticket.

### Agents and MCP

- **The `SandboxAgent` MCP-listing gap is upstream, not config** - substrate `kind: SandboxAgent` agents run, build golden actors, and are listed by the kagent REST API (`/agents`), but `MCPHandler.listReadyAgents` lists only `v1alpha2.Agent` and hard-codes `condition.Reason == "DeploymentReady"`; substrate agents report `WorkloadReady`, so they are excluded from `list_agents` and `invoke_agent` returns "not found". This requires an upstream kagent change.
- **The apiserver->webhook netpol is critical** - Cilium's implicit default-deny dropped all apiserver traffic to the conversion webhook because the apiserver runs on a remote control-plane node. Fixed by explicit ingress rule (`allow-ingress-apiserver-to-sandbox-webhook`) in `clusters/cluster1/kubernetes/apps/network-policies/policies/infra/ai-system.yaml`.
- **Git history is the source of truth for restoration** - when rolling back from partial deployment state, the backup YAML contains generated objects. Restoring from git history (`git checkout <commit> -- <file>`) recovers canonical source manifests.
- **A stdio-only MCP image needs a spec-strict bridge** - codebase-memory-mcp is stdio-only; `supergateway` failed on `notifications/initialized`, while `mcp-proxy` answered 202 and registered cleanly with kagent.
- **A glibc binary can run in a musl bridge image** - codebase-memory-mcp is glibc-linked; stage the binary and glibc runtime via an initContainer into shared emptyDir, then spawn through explicit loader (`ld-linux`).
- **git-sync must be a native sidecar** - run git-sync as an initContainer with `restartPolicy: Always` (native sidecar, k8s >=1.29) ordered before the wait initContainer.

## Future Improvements

- **Cilium Egress Gateway** - route outbound traffic through a dedicated node to stabilize external IPs.
- **Distributed Tracing** - add Jaeger or Tempo for end-to-end tracing across game streaming and agent operations.
- **GPU Metrics Dashboard** - Grafana dashboard for DCGM metrics, game session lifecycle, vLLM scaling events.
- **Substrate agents via MCP** - bump kagent once upstream lists `SandboxAgent` CRs and accepts `WorkloadReady` in `listReadyAgents`, so substrate agents become MCP-invocable.
- **Agent hardening** - de-privilege and add `securityContext` to remaining classic agents.
