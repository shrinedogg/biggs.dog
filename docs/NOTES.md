# Engineering Notes

This document contains detailed architectural decisions, engineering notes, and historical context that is less critical for operators but helpful for maintainers and contributors.

> **Two clusters (migration in progress).** The homelab is split across `cluster0` — a single-node **UpCloud cloud** edge/mgmt cluster (public WAN `87.58.147.51`, Cilium L2 announcement) running Dex, NetBird, Omni, Talos Image Factory, cert-manager, external-secrets, and CiliumNetworkPolicies (two-tier: apps + infra) — and `cluster1` — the **on-prem 6-node bare-metal** workload cluster (Cilium BGP → UDM, `192.168.6.0/24` VIPs) running all applications, storage, GPU/AI, and observability. Flux pruning is disabled on both during the cutover. Most sections below describe `cluster1` workloads; cluster-specific notes are called out inline.
>
> **Note**: `cluster1` node specs (Talos Linux version, Kubernetes version, OS versions) in `README.md` are managed via Omni and reflect state at time of documentation. For live cluster versions, use `kubectl version` and check the Omni console (now run in-cluster on `cluster0` — see [System & Hardware](#system--hardware)). This Git repo drives desired state for workloads, not node OS versions.

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
- Big Picture mode via Sway (lightweight Wayland compositor). Gamescope was tried (forces fullscreen on a single virtual display) but its Vulkan compositing on the dGPU triggered NVRM Xid 109 (CTX SWITCH TIMEOUT) -> UE5 GPU crash (Fatal error!) on every launch; under Sway the game runs without that crash. Sway's original wl_drm abort is fixed by the patched wolf image.
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

### Dreamcast on Kubernetes: Implementation Notes

Getting the full stack running required several insights:

- **LB IP sharing** — the operator's `--lb-sharing-key` is aligned to `direwolf` so Cilium LB-IPAM hands every per-session RTP Service the same external IP as the proxy. Mismatched keys split the IP and the RTSP handshake times out (macOS errno 60).
- **GPU on the app container** — the game container needs its own `nvidia.com/gpu` request; CDI driver/device injection is per-allocated-container, so without it the app has no render node and produces a black stream.
- **GPU time-multiplexing with vLLM (`gpu-arbiter`)** — the 32 GB RTX 5090 can't hold both a gaming session and vLLM (~31 GB at idle) at once. Scaling now uses the `deployments/scale` subresource; a backwards `client.MergeFrom` previously emitted `{"spec":{"replicas":null}}`, deleting the field so it defaulted back to `1` and vLLM never actually scaled down; and (2) status is written with a full `Status().Update()` rather than a JSON merge patch, so zero-valued `omitempty` fields like `gamePods` clear instead of going stale.
- **`GBM_BACKENDS_PATH`** — set on both the Wolf sidecar and the Steam container; the CDI hook drops the NVIDIA GBM backend in `/usr/local/lib/gbm` while Mesa only searches `/usr/lib/x86_64-linux-gnu/gbm`.
- **Patched Wolf compositor (wl_drm fix)** — Wolf's `gst-wayland-display` advertised both the legacy `wl_drm` global and `zwp_linux_dmabuf_v1` v4 feedback; nested wlroots (Sway 0.19+) binds both and aborts on the duplicate device announcement (`assert(wl->drm_render_name == NULL)`). The patched `shrinedogg/wolf` image skips `wl_drm` when dmabuf v4 feedback is active (legacy clients can opt back in with `GST_WAYLAND_DISPLAY_ADVERTISE_WL_DRM=1`). This was needed to try Sway as the compositor; the Steam app now runs under Gamescope instead, but the patch stays deployed so Sway remains a working option (and Gamescope's Wayland client path is unaffected either way).
- **Gamescope device pinning (`--prefer-vk-device`)** — nv-01's Ryzen 7800X3D exposes an AMD iGPU (RADV `RAPHAEL_MENDOCINO`, PCI `1002:164e`, `/dev/dri/renderD128`) alongside the RTX 5090 (PCI `10de:2b85`, `/dev/dri/renderD129`). The Steam container is privileged (for `uinput` hotplug, see below), so it sees both GPUs; Gamescope enumerates Vulkan devices and selects the AMD iGPU, then aborts at `CVulkanTexture::BInit` (`rendervulkan.cpp:2195`, assertion `modifiers.size() > 0`) because the iGPU can't provide the dmabuf modifiers it needs. `GAMESCOPE_MODE` (default `-b` in the GOW `launch-comp.sh`, interpolated unquoted so it word-splits into args) is set to `-b --prefer-vk-device 10de:2b85` to force gamescope onto the dGPU. (Wolf's capture is unaffected — it's pinned via `wolfConfig.runtimeVariables.renderNode: /dev/dri/renderD129`.)
- **`/dev/shm` sizing** — a 4Gi memory-backed `emptyDir` at `/dev/shm`; the 64Mi runtime default exhausts instantly under Steam's CEF UI, yielding a black screen with only a cursor.
- **User namespaces** — Steam's pressure-vessel runtime requires `user.max_user_namespaces`, which Talos defaults to `0`. Enabled cluster-wide via Omni machine-config patches on every node (node-level config, not in this repo); also used by the `auth` and `affine` workloads, which run with `hostUsers: false` so their containers' root maps to an unprivileged host UID.
- **Privileged Steam container** — Wolf hotplugs `uinput` devices mid-session; Kubernetes has no equivalent of Docker's `device_cgroup_rules`, so the container must be privileged to open the late-appearing `/dev/input/event`* nodes.
- **Root Wolf entrypoint** — a ConfigMap (`wolf-entrypoint.yaml`) shadows the GOW `/entrypoint.sh` to force the Wolf sidecar to run as root, avoiding the upstream `gosu`/`supervisord` privilege-drop crash loop. (Re-declaring `PUID`/`PGID`/`UNAME` is rejected by server-side apply as duplicate map keys.)
- **DRM render-node override** — `wolfConfig.runtimeVariables.renderNode` is pinned to `/dev/dri/renderD129`. The NVIDIA container toolkit injects the dGPU with its host numbering (`renderD128` doesn't exist inside the container), and with the wrong node Wolf fails GPU vendor detection and silently falls back to **software x264 encoding**.
- **In-container `udevd` (Steam Input)** — beyond the `wolf-agent` fake-udev (which surfaces the Moonlight controller), the Steam app runs a real `systemd-udevd` + `udevadm trigger`. Steam Input emulates a *second* uinput pad for the game, and without an in-container udevd nothing writes its udev db entry / libudev event, so SDL/Proton see no controller in-game.
- **Focus guard (Sway only, currently dormant)** — a small Python/Xlib watcher (`focus-guard.py`) in the Steam container. Steam's `steamwebhelper` maps an invisible, class-less notification popup that steals X input focus from the running game; Gamescope pins focus to the game (so the guard is unnecessary under the current Gamescope config), but Sway honors the grab, breaking keyboard + Steam Input routing. The guard returns focus to the viewable `steam_app_*` window whenever an unnamed/class-less window holds it (legitimate Big Picture focus changes are left alone). It's gated on `if [ "$RUN_SWAY" = "true" ]`, so under Gamescope the script is written but never launched.
- **PulseAudio device names** — the Steam app deliberately does **not** export `PULSE_SINK`/`PULSE_SOURCE`. The image has no `pactl`, so the upstream lookup exported empty/bogus names; libpulse treats a set-but-invalid device as an explicit request and fails the stream (silent Steam) instead of falling back to Wolf's default virtual sink.
- **No `NVIDIA_DRIVER_CAPABILITIES` on the app container** — the operator already appends `NVIDIA_DRIVER_CAPABILITIES=all` to the app container (`session.go`); re-declaring it makes the server-side-apply patch invalid (duplicate map key) so the Deployment is never created and the reaper kills the session after 60s. (Same failure class as the root-entrypoint `PUID` note above.)
- **DLSS / NVAPI under Proton** — DLSS needs two things on Talos. (1) The `nonfree-kmod-nvidia` extension strips the NVIDIA "wine" NGX bridge DLLs (`nvngx.dll` / `_nvngx.dll`), so an `nvngx-bridge` initContainer extracts them from the matching driver `.run` and caches them on the `nvngx-cache` host-path PVC (downloaded at most once); Proton copies them into each prefix's `system32` when `PROTON_ENABLE_NVAPI=1`. (2) DLSS is gated behind NVAPI, so `PROTON_ENABLE_NVAPI=1` + `DXVK_ENABLE_NVAPI=1` are set on the Steam container, otherwise the in-game DLSS toggle stays greyed out despite the RTX GPU.

## Core Components Detail

### Networking Stack

Both clusters run **Cilium** as the CNI (replaces kube-proxy) and **Gateway API** with **AgentGateway** (OCI HelmRelease, charts pinned to a known-good alpha build `0.0.0-alpha.a655af15`), but they advertise service VIPs differently:

- **`cluster1` (on-prem)** — Cilium **BGP** peers with the UDM router (local ASN 64564 ↔ peer 64563 @ `192.168.1.1`), advertising the `192.168.6.6–254` pool (off-subnet from the nodes on `192.168.2.0/24`, so VIPs route via the UDM).
- **`cluster0` (cloud)** — single-node, so it uses a Cilium **L2 announcement** policy with a single-IP pool (`87.58.147.51/32`). The UpCloud Managed LB only supports TCP/HTTP (no UDP), so UDP services (NetBird STUN `3478`) are exposed via `externalIPs` bound on the node's NIC instead of a LoadBalancer Service.

`cluster1` split-horizon DNS:
- **k8s-gateway** — authoritative for `*.biggs.dog` (LB `192.168.6.6`, ClusterIP `10.105.74.41`); resolves internal gateway VIPs in-cluster and external gateway VIPs for LAN clients.
- **CoreDNS** (Talos-managed `kube-dns`) conditionally forwards `biggs.dog` queries to k8s-gateway's ClusterIP instead of Cloudflare, keeping pod traffic in-cluster.
- **lan-dns** — LAN CoreDNS resolver (LB `192.168.6.16`) forwards `biggs.dog` → k8s-gateway and everything else → NextDNS over DoT.

`cluster0` public ingress is the `cluster0-gateway` (`networking` ns) with HTTPS listeners for `omni`/`dex`/`netbird.biggs.dog`, each backed by a per-host cert issued **in the `networking` namespace** (Gateway API resolves name-only `certificateRefs` to the gateway's own namespace) via the `letsencrypt-prod` ClusterIssuer (DNS-01/Cloudflare).

**k8s-gateway fallthrough:** `cluster1`'s k8s-gateway has **fallthrough enabled** with NextDNS resolvers (`45.90.28.232` / `45.90.30.232`) so unknown `biggs.dog` names resolve to public DNS — this is how LAN/VPN clients reach cluster0 services (omni/netbird/dex at `87.58.147.51`). The chart's default `forward . /etc/resolv.conf` plugin was replaced because it loops: k8s-gateway → `/etc/resolv.conf` → in-cluster CoreDNS → k8s-gateway again (CoreDNS conditionally forwards `biggs.dog` to k8s-gateway's ClusterIP), resulting in SERVFAIL. The fix replicates the full chart default plugin list with only the forward parameters changed to NextDNS IPs. The `ready`/`health`/`prometheus` plugins must stay for liveness/readiness probes and ServiceMonitor.

**NetBird gRPC** — NetBird multiplexes gRPC over HTTP/2 on port 80; the gateway must speak HTTP/2 to the backend, not HTTP/1.1. AgentGateway ignores the `agentgateway.dev/backend-protocol: h2c` annotation on HTTPRoute, so an `AgentgatewayPolicy` (`netbird-grpc`) is used instead, targeting the `netbird-grpc` HTTPRoute and setting `backend.http.version: HTTP2`.

**Omni BackendTLSPolicy** — Omni serves its own HTTPS (the omni binary runs with `--cert/--key` on `:443` with a Let's Encrypt cert for `omni.biggs.dog`). The cluster0-gateway terminates client TLS at the omni-https listener, then must re-encrypt to omni-ui over HTTPS. The HTTPRoute annotation `agentgateway.dev/backend-protocol: "HTTPS"` declares that intent, but agentgateway only actually speaks TLS to the backend when a `BackendTLSPolicy` tells it what hostname/SNI to use and what CA to trust. Without this policy, agentgateway sent plain HTTP to omni-ui:443 → omni's TLS server rejected it (`Client sent an HTTP request to an HTTPS server`). The policy uses `wellKnownCACertificates: System` (trusts the public CA that signed omni's Let's Encrypt cert — ISRG Root X1) and `hostname: omni.biggs.dog`.

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

### Network Policies & Cilium Configuration

The cluster enforces least-privilege **CiliumNetworkPolicy** across all namespaces. Policies are split into two independent Flux Kustomizations:

- **`network-policies-apps`** — lower-risk application namespaces (affine, auth, biggs, dragonfly, games, jitsi, manticore, matrix, media, renovate on cluster1; auth, netbird, omni on cluster0). Can be updated with confidence.
- **`network-policies-infra`** — higher-risk infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, kube-system on cluster1; networking, cert-manager, external-secrets, flux-system on cluster0). Can be suspended independently with `flux suspend kustomization network-policies-infra` if edge or control plane regresses.

This two-tier approach allows staged rollouts and rapid rollback without affecting application policies.

**Key Cilium policy conventions** (each is documented inline in the policy files):

- **Default-deny is implicit.** Cilium rejects an empty deny-all (`ingress: [] / egress: []` → `VALID: False`), so there is no standalone deny-all policy. Every namespace's `allow-*` policies select `endpointSelector: {}`, which puts all pods into default-deny for any traffic not explicitly allowed.
- **L7 DNS on every `allow-egress-dns`.** A bare L3/L4 DNS allow lets Go resolvers' rapid parallel A/AAAA replies miss the egress conntrack entry and get dropped as new ingress. Routing DNS through the Cilium DNS proxy (`rules.dns: matchPattern "*"`) fixes that and enables `toFQDNs` (used for GitHub, the OIDC issuer, Backblaze B2, etc.).
- **ClusterIP service return paths.** With `bpf-lb` + default-deny ingress, replies from a ClusterIP service (e.g. CNPG `-rw` Postgres) arrive reverse-NAT'd from the service VIP and miss conntrack, so DB clients carry an explicit `allow-ingress-from-postgres` return-path rule.
- **Gateway data planes** are selected by `gateway.networking.k8s.io/gateway-class-name: agentgateway` (one Deployment per Gateway, e.g. `wildcard-biggs-dog`) — distinct from the control-plane `agentgateway` pod — so `*.biggs.dog` ingress and backend forwarding are authorized.
- **Internet pulls hide behind caches.** Default-deny egress silently breaks anything that reaches out only occasionally — e.g. vLLM downloads a *new* model from Hugging Face but loads already-cached ones from its PVC, so blocked egress only surfaces on a model swap. Such components (`allow-egress-vllm-huggingface`, renovate's `allow-egress-https`, volsync→Backblaze B2) carry an explicit egress allow, scoped to the pod and kept broad on `:443` where the upstream uses rotating CDN/Xet hosts with no stable FQDN set.

### Identity & SSO Details

The two clusters run **different identity stacks** (a deliberate split: the edge cluster needs a always-on cloud IdP reachable before any on-prem dependency is up; the on-prem workload cluster uses the passkey-first stack for its apps).

**Dex** (`cluster0`, `dex.biggs.dog`) — the root OIDC IdP for the edge plane:
- `ghcr.io/dexidp/dex:v2.45.1`, stateless (`storage.type: memory`, single replica; tokens don't survive restarts, fine for interactive logins).
- `enablePasswordDB: true` with a static admin user; clients/secrets templated into the config from 1Password.
- Static clients: `omni` (Omni OIDC login), `netbird` (NetBird's embedded IdP upstream connector), `image-factory` (Image Factory UI).
- **Omni's OIDC callback** — the actual callback path is `/oidc/consume` (not the previously-guessed `/Callback` or `/callback`). The earlier mismatch caused Dex `bad request` errors.
- **Image Factory** — the Image Factory UI at `factory.biggs.dog` uses an `oauth2-proxy` (v7.6.0) authenticated against Dex. The proxy upstreams to `image-factory.omni.svc.cluster.local:8080`. The HTTPRoute path-splits: API paths go directly to image-factory, UI paths (`/` and `/oauth2/*`) go through the proxy.
- `connectors: []` — Dex is the root IdP here, not a federator in front of Pocket ID.

**Pocket ID** (`cluster1`, `id.biggs.dog`) — passkey-first OIDC for workload apps:
- Passkey-first OIDC provider (FIDO2 WebAuthn).
- Postgres backend via CNPG (user database, secret storage).
- File uploads stored in the same database.

**OAuth2 Proxy** (`cluster1`, `auth.biggs.dog`):
- OIDC client to Pocket ID.
- Provides forward-auth for browser apps (agentgateway `AgentgatewayPolicy` with `traffic.extAuth`).
- Uses **Dragonfly (Redis)** for session storage (small session ticket instead of large cookie).
- Protected apps attach a `ReferenceGrant` to reach the OAuth2 Proxy service in the `auth` namespace.

**Protected apps (`cluster1`):**
- Rook-Ceph dashboard
- Bookboss
- kagent UI

**Native OIDC apps (`cluster1`):**
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
- **Omni (Sidero)** — now run **in-cluster on `cluster0`** (`apps/omni/`, image `ghcr.io/siderolabs/omni:v1.9.1`) as the full Talos management plane (UI at `omni.biggs.dog`, machine API `:8090`, event sink `:8091`, K8s proxy `:8100`, Siderolink WireGuard `:50180/udp` advertised at `87.58.147.51:50180`). It manages the on-prem `cluster1` nodes, which phone home over Siderolink. Runs privileged with `/dev/net/tun`; double-TLS via `BackendTLSPolicy` (see below). Backed by embedded etcd + SQLite PVCs; OIDC login via Dex.
- **Talos Image Factory** — builds and signs custom Talos Linux images with cosign (`ghcr.io/siderolabs/image-factory:v1.3.3`). Stateless HTTP service on `:8080` behind an `oauth2-proxy` (v7.6.0) authenticated against Dex at `factory.biggs.dog`. Durable state lives in a registry PVC. cosign signing key and public key are mounted as Secrets. Rate-limit policy and an embedded OCI registry (`registry-deployment`) are also deployed.
- **Per-machine Omni `ConfigPatch`es** — node-level config still lives in Omni as per-machine `ConfigPatch`es (each node carries a `10-<machine-id>` user patch: hostname, NIC rings, node-specific tweaks). Local copies live under `omni/` (git-ignored, outside `clusters/` so Flux never reconciles them). Inspect/apply with `omnictl` (`omnictl get configpatch`, `omnictl apply -f ...`). Nodes imported from existing Talos clusters got this auto-generated on import; machines scaled directly from Omni did not, so their equivalent settings must be authored by hand. CoreDNS is configured cluster-wide via the `coredns-custom` inline-manifest patch (scoped to the cluster, not per node). When setting an explicit `HostnameConfig.hostname` on a directly-scaled node, also `$patch: delete` the default `auto` field, or Talos rejects the config (`'auto' and 'hostname' cannot be set at the same time`).

### Automation

- **Renovate** — automated dependency updates for HelmRelease chart versions and container images referenced in Kubernetes manifests. Configured in `renovate.json`.

## AI & Agents Architecture

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack. The vLLM and kagent infrastructure is shared; agent-specific configs are in [`.rules`](.rules).

### vLLM Deployment

- **Model**: [`rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm`](https://huggingface.co/rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm) (served as `qwen36-local`) — a **27B dense** model (all params active) with a **Gated-DeltaNet / gated-attention hybrid** (only 16 of 64 layers keep paged KV), NVFP4 via compressed-tensors (~18 GiB resident on the 32 GB card). **192K context** served (`--max-model-len=196608`; native max 262K).
- **Version**: v0.23.0 (CUDA 12.9 for Blackwell GPU support on RTX 5090).
- **GPU**: One of the RTX 5090's 4 time-slices; vLLM pins the bulk of the 32 GB card.
- **Scaling**: Idle = 1 replica; gaming session = 0 replicas (managed by `gpu-arbiter-operator`).
- **API**: OpenAI-compatible (`/v1/chat/completions`, etc.) at `http://vllm.ai-system.svc:8000`.

### vLLM Configuration & Performance

**Context cap rationale**: The model's native max is 262K. It was long capped at 131K (to roughly double KV concurrency on the 32 GB card), but was **raised to 192K** (`--max-model-len=196608`) because `exa-agent` web-search results (~38 KB each) were overflowing 131K session windows (one session hit ~164K tokens). The Gated-DeltaNet hybrid keeps most layers' KV bounded, so even 192K is affordable.

**Configuration details** (from `apps/ai-system/vllm/app/deployment.yaml`):
- **`--max-model-len 196608` (192K)** — raised from 131K for exa-agent search-result headroom (see above).
- **`--max-num-seqs 16` / `--max-cudagraph-capture-size 16`** (lowered from 32): the dense 27B model has far more active params per token than the prior MoE, so 16-way keeps prefill responsive under parallel kagent fan-out (the prior 32-way stall was on the MoE; this is a further stability margin).
- **`--gpu-memory-utilization 0.95`** (raised from 0.90): the 27B dense NVFP4 quant is lighter on residency (~18 GiB), leaving headroom to grow the KV pool back toward the 192K cap.
- **`--max-num-batched-tokens=8192`** (bumped from 4096): reduces prefill scheduling rounds for medium prompts.
- **`--kv-cache-dtype fp8`**.
- **Quantization**: auto-detected `compressed-tensors` NVFP4 from the checkpoint — **no `--quantization` flag** is passed (vLLM reads the model's NVFP4 config directly).
- **Tool-call parser**: `--tool-call-parser qwen3_coder` + `--reasoning-parser qwen3` (with `--enable-auto-tool-choice`), paired with the model's built-in chat template. (The prior MoE used `qwen3_xml`; this quant recommends `qwen3_coder`.)
- **`--language-model-only`** — skips the vision encoder on this multimodal checkpoint (replaces the old `--limit-mm-per-prompt`).
- `--enable-prefix-caching`, `--trust-remote-code`.

**Benchmark methodology** (`scripts/vllm-benchmark.py`):
- Runs 8 prompt profiles (short query, short factual, medium conversation, medium analysis, long tool-context, long reasoning, very long conversation history, structured response) at configurable concurrency/warmup/repetitions via raw aiohttp SSE parsing (bypasses OpenAI client streaming bugs).
- Results saved as JSON; compare with `scripts/compare-benchmarks.py`.
- Synthetic workload benchmark simulates 8 kagent-style prompt profiles (50 → 4,000 prompt tokens, 80 → 500 gen tokens) at concurrency 4 with 3 rep/scenario.
- **Measured performance** (measured on the prior MoE config; current dense 27B runs at `gpu-mem-util 0.95` / `max-num-seqs 16` / 192K):
  - Median TTFT **~1.12s** (stddev 0.07s)
  - Decode throughput **~186 tok/s** (stddev 10)
  - Total request time **~2.44s** median
  - Tail TTFT improved ~11% and decode stddev dropped ~29% vs baseline (fewer KV-preemptions, fewer prefill rounds)
- **Raw `vllm bench serve` on the 5090** (prior MoE, at the then-served 131K context):
  - Single-stream **~250 tok/s @ ~65 ms TTFT** (TPOT ~4 ms)
  - Batched Aggregate **~2,450 tok/s @ 32-way** and **~3,070 tok/s @ 64-way** concurrency (0 failures)
  - Well within the 32 GB card
  - **Note:** these figures are from the prior model; `max-num-seqs` is now 16 for production stability (the dense model is compute-heavier per token), but the 64-way figure remains valid as a theoretical throughput ceiling for the card.

**Model right-sizing (history)**: The cluster previously ran `NeuralNet-Hub/Qwen3.6-27B-NVFP4`, but per its author that was a suboptimal `llm-compressor` quant only validated on a **48 GB** card ([discussion](https://huggingface.co/NeuralNet-Hub/Qwen3.6-27B-NVFP4/discussions/1)) — it barely fit the 32 GB 5090 (util pinned near 0.984, 65K context max), causing OOM/`no cache blocks` churn and overflowing `flux-agent`'s ~64K tool schemas. An intermediate swap to the smaller, KV-efficient Gemma-4-26B-A4B (14B on disk, sliding-window attention, 256K context) resolved the OOM/context churn. A move to NVIDIA's official `nvidia/Qwen3.6-35B-A3B-NVFP4` (35B MoE, ~19B on disk, Mamba-hybrid, served at 131K) restored a stronger base with KV headroom.

The **current** model is [`rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm`](https://huggingface.co/rdtand/Qwen3.6-27B-PrismaSCOUT-Blackwell-NVFP4-BF16-vllm) — a **27B dense** NVFP4 quant. The prior `unsloth/Qwen3.6-27B-NVFP4` dense quant left the vision tower + embeddings in BF16 (~23 GiB resident), capping context at ~80K; this quant compresses those too (~18 GiB resident), restoring the full window **and** concurrency. Paired with a Gated-DeltaNet / gated-attention hybrid (only 16 of 64 layers keep paged KV) and `max-model-len` raised to 192K, it now fits `exa-agent`'s large search-result sessions alongside long-term memory with no overflow. See `apps/ai-system/vllm/app/deployment.yaml` for the in-tree rationale comments.

### Embeddings Service

- **Model**: `BAAI/bge-m3` (Infinity embedding server, CPU-only).
- **Deployment**: `michaelf34/infinity:latest-cpu` with PyTorch backend (not ONNX).
- **Port**: 7997 (internal service).
- **API**: OpenAI-compatible `/v1/embeddings` endpoint.
- **Usage**: Backing kagent's long-term vector memory via the `embedding-model` ModelConfig.
- **CPU-only by design**: The single GPU (nv-01) is fully committed to vLLM and scaled to 0 during gaming; a second GPU consumer would contend. Embedding traffic is infrequent and low-throughput, so CPU is sufficient.

### kagent Agents

The 10 agents split across **two deployment patterns** — classic `kind: Agent` CRs (the python runtime, each its own Deployment) and `kind: SandboxAgent` CRs on the substrate runtime (gVisor-sandboxed actors):

**Classic `kind: Agent` CRs** (invocable now via MCP) — the python runtime, each runs as its own Deployment:
- `flux-agent` (read-only) — Flux GitOps inspection (custom, `apps/ai-system/flux-mcp/`).
- `vm-agent` — VictoriaMetrics query + TSDB analysis (custom, `apps/ai-system/victoria-metrics-mcp/`).
- `exa-agent` — Web search and research (custom, `apps/ai-system/exa-mcp/`).
- `cilium-debug-agent` — Cilium diagnosis (static, `apps/ai-system/kagent/cilium-agents/`; carries generic `k8s_*` tools).
- `cilium-policy-agent` — Cilium policy authoring (static, `apps/ai-system/kagent/cilium-agents/`; carries generic `k8s_*` tools).

**`kind: SandboxAgent` CRs on the substrate runtime** (`apps/ai-system/kagent/substrate-agents/`, `platform: substrate`, `workerPoolRef: kagent-default`):
- `k8s-agent` — general Kubernetes inspection/troubleshooting.
- `observability-agent` — metrics, dashboards, alerting.
- `promql-agent` — PromQL query generation.
- `helm-agent` — Helm release management.
- `cilium-manager-agent` — Cilium install/config/upgrade.

These five are `ACCEPTED=True` / `READY=True` (golden actors built; ActorTemplates in `Ready` phase, upserted into the kagent Postgres `agents` table) and are listed by the kagent REST API (`/agents`, kagent-ui) — but are **not yet invocable via the MCP server** (`list_agents` omits them; `invoke_agent` returns "not found"). See [Agent Sandbox & Code Execution](#agent-sandbox--code-execution) for the root cause and the [`.rules`](.rules) fallbacks.

**Disabled chart agents** (kagent HelmRelease toggles): `argo-rollouts-agent`, `istio-agent`, `kgateway-agent`. The 5 substrate agents and the 2 static cilium agents are also disabled in the chart so they don't double-render as classic `Agent` CRs.

The classic agents run in pod runtimes with `executeCodeBlocks: true` and isolated `sandbox` specs via the SIG-Apps `Sandbox` controller (below). Agent selection for MCP tasks is documented in [`.rules`](.rules); each agent has a specific domain and preferred use case.

### Agent Sandbox & Code Execution

There are **two sandboxing mechanisms** deployed in `ai-system`:

1. **SIG-Apps `Sandbox` CRD + controller** (`agents.x-k8s.io`, pinned to `v0.5.0` with `controller.extensions: true`), which provides isolated, stateful single-pod runtimes for classic `kind: Agent` CRs that opt into `executeCodeBlocks` (code execution). All 5 classic agents are configured with code execution enabled.
2. **kagent substrate runtime (ATE / actor runtime)** — a separate control plane for sandboxed code execution via **gVisor**, used by the `kind: SandboxAgent` CRs. See [Substrate Runtime](#substrate-runtime) below.

**Multi-version CRD upgrade path** (SIG-Apps Sandbox): `v0.5.0` graduated the core + extension APIs from `v1alpha1` to `v1beta1` (multi-version CRDs with a self-hosted conversion webhook served by the controller on `:9443`). Because the controller is installed into `ai-system` rather than the upstream-default `agent-sandbox-system`, it rewrites each CRD's `conversion.webhook.clientConfig.service.namespace` to `ai-system` at startup (via `--webhook-namespace`). On an in-place `v0.4.6`->`v0.5.0` upgrade, the controller can deadlock during initial cache sync if pre-existing `v1alpha1` CRs must be converted before its own webhook Service has Ready endpoints — clear the (ephemeral) Sandbox/SandboxClaim/SandboxTemplate/SandboxWarmPool CRs so the first sync has nothing to convert, then let it come up clean.

**Two hard requirements** (both learned the hard way):

1. **Ingress from the kube-apiserver to the conversion webhook (`:9443`) must be allowed.** `ai-system` runs implicit Cilium default-deny ingress (`allow-intra-namespace` selects `endpointSelector: {}`), and the apiserver runs host-network on a *remote* control-plane node, so it isn't covered by Cilium's allow-localhost exemption. Without an explicit allow, every `v1alpha1<->v1beta1 Sandbox` conversion the apiserver issues is silently dropped: the controller crash-loops on cache-sync, `kubectl get sandboxes` hangs, and anything that creates a `Sandbox` (executeCodeBlocks Agents, or SandboxAgent reconciles) stalls to a 30s timeout. Fixed by the `allow-ingress-apiserver-to-sandbox-webhook` CiliumNetworkPolicy in `network-policies/policies/infra/ai-system.yaml` (`fromEntities: [kube-apiserver]` -> `:9443`). This rule is permanent (both for Sandbox CRD conversion on classic agents *and* for SandboxAgent use on the substrate).

2. **`SandboxAgent` agents run but are not yet MCP-invocable.** The substrate `SandboxAgent` controller creates the Sandbox pod (and the kagent REST API `/agents` lists it), but the kagent **MCP** layer omits it. Root cause is an **upstream kagent limitation, not a cluster config issue** (verified live, still present on kagent 0.9.10 / `kagent-dev/kagent@main`): `MCPHandler.listReadyAgents` lists only `v1alpha2.AgentList` (it never enumerates `SandboxAgent` CRs) and hard-codes `condition.Reason == "DeploymentReady"`; classic agents report Ready with reason `DeploymentReady`, while substrate agents report `WorkloadReady`. So substrate agents are excluded twice. `invoke_agent` is blocked by the same gap (returns "agent not found or not ready"). Fix needs an upstream kagent change (also list `SandboxAgentList` and accept `WorkloadReady`); track upstream and bump kagent when fixed. Until then, use the [`.rules`](.rules) fallbacks / direct `kubectl` for the 5 substrate agents. (Historically `SandboxAgent` was tried for all 10 agents and reverted on 2026-06-27 for exactly this reason; it was re-introduced for the 5 built-ins once the substrate runtime itself was stood up — the A2A/MCP gap is the remaining blocker, not the runtime.)

**Substrate namespace overrides**: upstream hard-codes the `ate-system` namespace everywhere, but this cluster runs substrate in `ai-system`. A stack of `ate-system`-vs-`ai-system` bugs gated golden-actor creation, each hidden behind the previous; all are fixed live:
  1. `ate-controller` dial addr (`--ateapi-conn-spec`, substrate HelmRelease).
  2. `ate-api-server` JWT key fetch (`--client-jwt-jwks-url`, on a forked image `shrinedogg/ateapi`). The JWKS URL points at the Kubernetes openid endpoint to work around Omni's IPv6 ULA issuer (`--service-account-issuer`) being unreachable from the IPv4 pod network.
  3. `ate-api-server` atelet discovery (`ATELET_NAMESPACE=ai-system` on the forked image).
  4. kagent env-source RBAC (`controller.substrate.ateApiServer.namespace=ai-system` in the kagent HelmRelease — the RoleBinding subject otherwise points at the nonexistent `ate-system` SA).
  5. gVisor `runsc` asset (`SandboxConfig/gvisor-default` + a `runsc-cache` DaemonSet; runsc `20260622.0` staged in the rustfs `ate-snapshots` bucket and pre-cached per node, because the atelet's S3 asset client doesn't honor `AWS_ENDPOINT_URL` and would otherwise dial real AWS S3).
  6. **Cilium egress (the real final blocker):** `ai-system` is in Cilium default-deny, and `allow-egress-internet` selected only `managed-by=kagent` pods. The atelet (`app=atelet`, Helm-managed) pulls sandbox container images in-process (`memorypullcache`, does NOT reuse node containerd) from `cr.kagent.dev` + `gcr.io`, so its pulls were policy-denied. Fixed by `allow-egress-atelet-registries` (CNP, `app=atelet` -> `world:443`). Node containerd pulls (for ordinary Deployments) always worked (host network); only the atelet's pod-network in-process pulls were blocked.

**Sandbox network scoping** (classic agents): each classic agent declares allowed egress via `spec.sandbox.network.allowedDomains`:
- Most sandboxes lock egress to `*.svc.cluster.local`, so prompt-injected code can hit in-cluster services (e.g. query VictoriaMetrics directly via `requests`/`httpx`) but can't phone out to the internet.
- `flux-agent` is stricter still (`sandbox.network: {}` = no outbound network at all), since it's a read-only diagnostic agent whose code only needs tool-call results.
- That allow-list is layered on the namespace's Cilium policies (`allow-egress-internet` still governs the agent pods themselves); the sandbox allow-list is the tighter boundary for *executed* code specifically.

**Security & de-privileging**: The `vm-agent` runner is de-privileged (`runAsNonRoot`, drop `ALL` capabilities, `privileged: false`) because `executeCodeBlocks` writes to the container filesystem — kagent otherwise schedules agent pods privileged, which combined with tool access is too large a blast radius for a prompt-injectable LLM. **Caveat:** the other classic agents are *not* de-privileged, so kagent still schedules their pods privileged — enabling code execution there raises blast radius until they're hardened the same way vm-agent is.

### Substrate Runtime

The kagent **substrate** (ATE / actor runtime) is deployed in `apps/ai-system/substrate/` (+ `substrate-crds/`) and backs the 5 `SandboxAgent` agents. Components: `ate-controller`, `ate-api-server` (Deployment `ate-api-server-deployment`, running the forked image `docker.io/shrinedogg/ateapi:v0.0.7-jwksurl-ateletns`), `atelet` worker DaemonSet, and `atenet-router`. A `WorkerPool` (`kagent-default`, `sandboxClass: gvisor`, `ateomImage: ghcr.io/kagent-dev/substrate/ateom-gvisor:v0.0.7`) is created by the kagent chart. JWT issuer is the Omni KubeSpan/SideroLink ULA. All substrate Deployments are pinned to the GPU node `nv-01`. gVisor `runsc` (`20260622.0`) is staged in rustfs and pre-cached per node via the `runsc-cache` DaemonSet. The kagent chart wires it in via `controller.substrate.enabled: true`, `ateApiEndpoint: dns:///api.ai-system.svc:443`, `ateApiInsecure: true`, and `substrateWorkerPool.create: true` (`replicas: 1`).

### Long-Term Memory

kagent is configured with vectorized memory (long-term, cross-session) backed by CNPG Postgres + pgvector, using the `embeddings` service for embedding generation. Per-agent memory is disabled on `flux-agent` (custom) because its ~64K tool schemas already push the context window toward saturation; all other classic agents (including `exa-agent`) have memory enabled. `exa-agent` additionally sets `context.compaction` at an 80K-token threshold and pairs with the 192K vLLM cap to absorb large web-search result sets without overflow — an earlier attempt to disable exa memory (suspected context overflow) was reverted once it was clear the overflow came from Exa results, not memory (the pgvector `memory` table had 0 rows). The 5 substrate agents declare no per-agent `memory:` block. None of the disabled chart agents are in scope.

### MCP Servers

- **Flux Operator MCP** (`flux-agent`) — read-only inspection of `FluxInstance`, sources, Kustomizations, HelmReleases, ResourceSets.
- **VictoriaMetrics MCP** (`vm-agent`) — PromQL/MetricsQL queries, alerting rules, TSDB cardinality analysis, embedded VM docs.
- **Exa MCP** (`exa-agent`) — Web search, code discovery, company research.
- **Kubernetes API** (all agents) — native k8s API via controller-runtime client.

### MCP Exposure & Routing

The MCP endpoint is the `kagent-mcp` HTTPRoute (`https://mcp.biggs.dog/mcp`) on the internal LAN-only gateway `internal-biggs-dog` (VIP 192.168.6.15). k8s-gateway split-horizon resolves `mcp.biggs.dog` to `.6.15` for LAN/VPN clients; TLS is terminated at the gateway with the wildcard cert, no auth. WAN clients hit the public gateway (no such route -> 404). This replaced the old `kagent-mcp-lan` plain-HTTP LoadBalancer (`192.168.6.13`, pinned via `io.cilium/lb-ipam-ips`) once the agentgateway was confirmed to no longer mangle the `/mcp` Streamable-HTTP path — verified end-to-end (initialize -> notifications/initialized -> tools/list) over the route. There is no server-side request timeout — long agentic loops complete because inference is fast (~250 tok/s single-stream), not because of a route timeout.

## Cluster Bootstrapping

Each cluster bootstraps via its own **Flux Operator** syncing from `https://github.com/shrinedogg/biggs.dog.git` (main branch). `cluster0` syncs `clusters/cluster0` (edge/mgmt); `cluster1` syncs `clusters/cluster1` (workloads). On each, Flux reconciles:

1. **FluxInstance** (Flux system components).
2. **Sources** (GitRepository, HelmRepository, OCIRepository).
3. **Kustomizations** and **HelmReleases** (ordered via `dependsOn`).

Flux pruning is currently **disabled** on both root syncs as a migration safety measure (see [Architecture](../README.md#-architecture) in the README). Secrets are decrypted by SOPS (age key) before Flux applies them.

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
- **Talos CoreDNS label is `coredns`, not `kube-dns`** — all `allow-egress-dns` policies initially targeted `k8s:k8s-app: kube-dns`, but Talos deploys CoreDNS with `k8s-app=coredns`. This dropped every namespace's DNS under default-deny. Fix: use `k8s-app: coredns` in policy selectors.
- **Cilium webhook ports** — cert-manager and external-secrets webhook Services map `:443` to container port `:10250`. Cilium's kube-proxy replacement delivers traffic on the container port, so CNP ingress rules must allow `:10250`, not `:443`. Diagnosed via `cilium service list`.
- **External-secrets cert-controller** — the cert-controller pod (`app.kubernetes.io/name=external-secrets-cert-controller`) manages ValidatingWebhookConfigurations and needs API server access. A narrow endpointSelector only matched the main controller pod, leaving the cert-controller blocked and crash-looping. Use `{}` endpointSelector to cover all external-secrets pods.

### Observability

- **DCGM metrics lag** — free VRAM reports ~30s behind actual consumption. The `gpu-arbiter-operator` gates on vLLM down first, then VRAM as a secondary signal.
- **Victoria Metrics cardinality** — high cardinality metrics (e.g., per-pod ephemeral metrics) can blow up storage and query times. Use recording rules and aggregation.

### Secrets

- **Don't hardcode secrets** — use SOPS + age for Git-stored secrets, and External Secrets + 1Password for runtime-only secrets.
- **Session storage** — OAuth2 Proxy's session cookie can exceed 4 KB and get chunked, breaking ext-authz subrequests. Use Dragonfly (Redis) to store the session server-side and reduce the cookie to a small ticket.

### Agents & MCP

- **The `SandboxAgent` MCP-listing gap is upstream, not config** — the substrate `kind: SandboxAgent` agents run, build golden actors, and are listed by the kagent REST API (`/agents`), but `MCPHandler.listReadyAgents` lists only `v1alpha2.Agent` and hard-codes `condition.Reason == "DeploymentReady"`; substrate agents report `WorkloadReady`, so they're excluded from `list_agents` and `invoke_agent` returns "not found". No Service/ingress/Helm value fixes this on kagent 0.9.10 — it needs an upstream kagent change. Verified by probing `/api/a2a/ai-system/<agent>/.well-known/agent-card.json` → "Agent not found" (registry lookup, not network).
- **The apiserver→webhook netpol is non-obvious but critical** — Cilium's implicit default-deny dropped all apiserver traffic to the controller because the apiserver runs on a *remote* host (control-plane node). Took tracing through the CRD conversion path and the controller's deadlock during cache-sync to diagnose. This rule is now permanent (both for `SandboxAgent` use *and* for classic agents with `executeCodeBlocks`).
- **Git history is the source of truth for restoration** — when rolling back from a partial deployment state, the backup YAML contains *generated* objects (not the source manifests). Restoring from git history (`git checkout <commit> -- <file>`) is necessary to get the canonical, working manifests. Post-migration cleanup (e.g., kustomization.yaml deletions in custom agent app dirs) don't need to be restored — Flux auto-generates kustomizations for leaf app directories. Only the source manifests and the Flux Kustomization references need recovery.

## Future Improvements

- **Cilium Egress Gateway** — route outbound traffic through a dedicated node to stabilize external IPs (useful for services that block by IP).
- **Distributed Tracing** — add Jaeger or Tempo for end-to-end tracing across kafka, game streaming, and agent operations.
- **GPU Metrics Dashboard** — Grafana dashboard for DCGM metrics, game session lifecycle, vLLM scaling events.
- **Finish the cluster split** — re-enable Flux pruning on both clusters once the `cluster0`/`cluster1` cutover is confirmed stable, and reconcile any remaining drift between the two trees.
- **Substrate agents via MCP** — bump kagent once upstream lists `SandboxAgent` CRs and accepts `WorkloadReady` in `listReadyAgents`, so `k8s-agent`/`helm-agent`/`promql-agent`/`observability-agent`/`cilium-manager-agent` become MCP-invocable.
- **Agent hardening** — de-privilege and add `securityContext` to the other classic agents (currently only vm-agent is hardened).
