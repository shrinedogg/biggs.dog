# Engineering Notes

This document contains detailed architectural decisions, engineering notes, and historical context that is less critical for operators but helpful for maintainers and contributors.

> **Note**: Cluster node specs (Talos Linux version, Kubernetes version, OS versions) in `README.md` are managed externally via Omni and reflect state at time of documentation. For live cluster versions, use `kubectl version` and check the Omni console. This Git repo drives desired state for workloads (manifests in `clusters/cluster0/`), not node OS versions.

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

The cluster uses:
- **Cilium** as the CNI (replaces kube-proxy), with BGP for LoadBalancer IP advertisement.
- **k8s-gateway** for split-horizon DNS: `*.biggs.dog` resolves to the internal gateway LB (`192.168.6.7`) in-cluster and to the external gateway LB (`192.168.6.6`) for LAN clients.
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

### Network Policies & Cilium Configuration

The cluster enforces least-privilege **CiliumNetworkPolicy** across all namespaces. Policies are split into two independent Flux Kustomizations:

- **`network-policies-apps`** — lower-risk application namespaces (affine, auth, biggs, dragonfly, games, jitsi, manticore, matrix, media, renovate). Can be updated with confidence.
- **`network-policies-infra`** — higher-risk infrastructure namespaces (networking, ai-system, cnpg-system, observability, rook-ceph, kube-system). Can be suspended independently with `flux suspend kustomization network-policies-infra` if edge or control plane regresses.

This two-tier approach allows staged rollouts and rapid rollback without affecting application policies.

**Key Cilium policy conventions** (each is documented inline in the policy files):

- **Default-deny is implicit.** Cilium rejects an empty deny-all (`ingress: [] / egress: []` → `VALID: False`), so there is no standalone deny-all policy. Every namespace's `allow-*` policies select `endpointSelector: {}`, which puts all pods into default-deny for any traffic not explicitly allowed.
- **L7 DNS on every `allow-egress-dns`.** A bare L3/L4 DNS allow lets Go resolvers' rapid parallel A/AAAA replies miss the egress conntrack entry and get dropped as new ingress. Routing DNS through the Cilium DNS proxy (`rules.dns: matchPattern "*"`) fixes that and enables `toFQDNs` (used for GitHub, the OIDC issuer, Backblaze B2, etc.).
- **ClusterIP service return paths.** With `bpf-lb` + default-deny ingress, replies from a ClusterIP service (e.g. CNPG `-rw` Postgres) arrive reverse-NAT'd from the service VIP and miss conntrack, so DB clients carry an explicit `allow-ingress-from-postgres` return-path rule.
- **Gateway data planes** are selected by `gateway.networking.k8s.io/gateway-class-name: agentgateway` (one Deployment per Gateway, e.g. `wildcard-biggs-dog`) — distinct from the control-plane `agentgateway` pod — so `*.biggs.dog` ingress and backend forwarding are authorized.
- **Internet pulls hide behind caches.** Default-deny egress silently breaks anything that reaches out only occasionally — e.g. vLLM downloads a *new* model from Hugging Face but loads already-cached ones from its PVC, so blocked egress only surfaces on a model swap. Such components (`allow-egress-vllm-huggingface`, renovate's `allow-egress-https`, volsync→Backblaze B2) carry an explicit egress allow, scoped to the pod and kept broad on `:443` where the upstream uses rotating CDN/Xet hosts with no stable FQDN set.

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
- **Omni / Talos machine config** — node-level config lives in Omni (Sidero) as per-machine `ConfigPatch`es, not in the Flux tree. Inspect/apply with `omnictl` (`omnictl get configpatch`, `omnictl apply -f ...`). Local copies of these patches live under `omni/` (git-ignored, outside `clusters/cluster0/` so Flux never reconciles them). Each node carries a `10-<machine-id>` user patch (hostname, NIC rings, node-specific tweaks); nodes imported from existing Talos clusters got this auto-generated on import, whereas machines scaled directly from Omni do not, so their equivalent settings must be authored by hand. CoreDNS is configured cluster-wide via the `coredns-custom` inline-manifest patch (scoped to the cluster, not per node). When setting an explicit `HostnameConfig.hostname` on a directly-scaled node, also `$patch: delete` the default `auto` field, or Talos rejects the config (`'auto' and 'hostname' cannot be set at the same time`).

### Automation

- **Renovate** — automated dependency updates for HelmRelease chart versions and container images referenced in Kubernetes manifests. Configured in `renovate.json`.

## AI & Agents Architecture

The `ai-system` namespace runs a fully local, GPU-accelerated agentic-ops stack. The vLLM and kagent infrastructure is shared; agent-specific configs are in [`.rules`](.rules).

### vLLM Deployment

- **Model**: `nvidia/Qwen3.6-35B-A3B-NVFP4` (35B MoE, ~3B active parameters, **131K context** served, native max 262K) with Mamba-hybrid attention.
- **Version**: v0.23.0 (CUDA 12.9 for Blackwell GPU support on RTX 5090).
- **Quant**: NVIDIA **NVFP4** (native Blackwell FP4 tensor core support, ~19B on disk).
- **GPU**: One of the RTX 5090's 4 time-slices (~8 GB per slice, vLLM pins ~31 GB, one per session games at ~1–2 GB).
- **Scaling**: Idle = 1 replica; gaming session = 0 replicas (managed by `gpu-arbiter-operator`).
- **API**: OpenAI-compatible (`/v1/chat/completions`, etc.) at `http://vllm.ai-system.svc:8000`.

### vLLM Configuration & Performance

**Context cap rationale**: The model's native max is 262K, but at 262K the KV pool on the 32 GB card only covers ~3.2 concurrent full-context requests. Capping at 131K doubles that to ~6.4 concurrent requests while staying well above flux-agent's ~64K tool-schema need.

**Configuration details** (`--max-num-seqs 32` capped for stability):
- Runs with `fp8` KV cache, `--max-num-seqs 32` / `--max-cudagraph-capture-size 32` (lowered from 64 after a vLLM stall/restart under parallel kagent fan-out — 6-9 agents firing long-context tool-schema prompts simultaneously saturated GPU compute during prefill and stalled the async event loop past the 10s×6 liveness headroom; 32-way lets vLLM queue excess requests instead of compute-locking).
- **`--max-model-len 131072` (131K; native max is 262K, but at 262K the ~838K-token KV pool covers ~3.2 concurrent full-context reqs, so capped at 131K for ~6x headroom)**.
- **`--gpu-memory-utilization 0.90` (reduced from 0.97)**: On this time-sliced, shared GPU, 0.97 reserved ~31.6GB and left only ~1GB free — co-scheduled consumers then hit NVRM `NV_ERR_NO_MEMORY`, contributing to a full node lockup (2026-06-25). `0.90` reserves ~29.3GB (leaves ~3.2GB headroom). The earlier `0.97` had trimmed KV-exhaustion preemptions (decode min 146 → 166 tok/s, stddev −29%), so this trades a little tail latency for stability.
- **`--max-num-batched-tokens=8192` (bumped from 4096)**: Reduces prefill scheduling rounds for medium prompts. Halves prefill rounds for 200–400 token range, shaving 2–5% off total time for those scenarios.
- **Tool-call parser**: Qwen3.6 uses `--tool-call-parser qwen3_xml` + `--reasoning-parser qwen3` (per NVIDIA's model card), with `--enable-auto-tool-choice`, paired with the model's built-in chat template.
- **Quantization**: `--quantization modelopt` (vLLM auto-detects NVIDIA ModelOpt's NVFP4 config from the checkpoint). `--trust-remote-code` is set per the model card.
- **Mamba-hybrid attention** — keeps most layers' KV bounded, so even the full 131K window is cheap.
- **Text-only inference** — `--limit-mm-per-prompt={"image":0,"video":0}` skips the vision encoder on this multimodal checkpoint.

**Benchmark methodology** (`scripts/vllm-benchmark.py`):
- Runs 8 prompt profiles (short query, short factual, medium conversation, medium analysis, long tool-context, long reasoning, very long conversation history, structured response) at configurable concurrency/warmup/repetitions via raw aiohttp SSE parsing (bypasses OpenAI client streaming bugs).
- Results saved as JSON; compare with `scripts/compare-benchmarks.py`.
- Synthetic workload benchmark simulates 8 kagent-style prompt profiles (50 → 4,000 prompt tokens, 80 → 500 gen tokens) at concurrency 4 with 3 rep/scenario.
- **Measured performance** (at 0.97 GPU util, now running 0.90 for stability):
  - Median TTFT **~1.12s** (stddev 0.07s)
  - Decode throughput **~186 tok/s** (stddev 10)
  - Total request time **~2.44s** median
  - Tail TTFT improved ~11% and decode stddev dropped ~29% vs baseline (fewer KV-preemptions, fewer prefill rounds)
- **Raw `vllm bench serve` on the 5090**:
  - Single-stream **~250 tok/s @ ~65 ms TTFT** (TPOT ~4 ms)
  - Batched aggregate **~2,450 tok/s @ 32-way** and **~3,070 tok/s @ 64-way** concurrency (0 failures) *at served 131K context*
  - Well within the 32 GB card
  - **Note:** `max-num-seqs` is now capped at 32 for production stability (64-way stalled under real agent fan-out), but the 64-way benchmark figure remains valid as the theoretical throughput ceiling.

**Model right-sizing (history)**: The cluster previously ran `NeuralNet-Hub/Qwen3.6-27B-NVFP4`, but per its author that was a suboptimal `llm-compressor` quant only validated on a **48 GB** card ([discussion](https://huggingface.co/NeuralNet-Hub/Qwen3.6-27B-NVFP4/discussions/1)) — it barely fit the 32 GB 5090 (util pinned near 0.984, 65K context max), causing OOM/`no cache blocks` churn and overflowing `flux-agent`'s ~64K tool schemas. An intermediate swap to the smaller, KV-efficient Gemma-4-26B-A4B (14B on disk, sliding-window attention, 256K context) resolved the OOM/context churn. The current model, NVIDIA's official `nvidia/Qwen3.6-35B-A3B-NVFP4` (NVFP4, ~19B on disk), keeps the KV headroom (Mamba-hybrid attention, served at 131K) while moving back to a stronger MoE base — flux-agent and the other heavy agents now fit with long-term memory on and no overflow.

### Embeddings Service

- **Model**: `BAAI/bge-m3` (Infinity embedding server, CPU-only).
- **Deployment**: `michaelf34/infinity:latest-cpu` with PyTorch backend (not ONNX).
- **Port**: 7997 (internal service).
- **API**: OpenAI-compatible `/v1/embeddings` endpoint.
- **Usage**: Backing kagent's long-term vector memory via the `embedding-model` ModelConfig.
- **CPU-only by design**: The single GPU (nv-01) is fully committed to vLLM and scaled to 0 during gaming; a second GPU consumer would contend. Embedding traffic is infrequent and low-throughput, so CPU is sufficient.

### kagent Agents

The 10 agents split into two deployment patterns:

**Chart-managed agents** (enabled via kagent HelmRelease toggles):
- `k8s-agent` — general Kubernetes inspection/troubleshooting.
- `observability-agent` — metrics, dashboards, alerting.
- `promql-agent` — PromQL query generation.
- `helm-agent` — Helm release management.
- `cilium-manager-agent` — Cilium install/config/upgrade.

**Custom (non-chart) agents** (static manifests in dedicated Kustomizations):
- `flux-agent` (read-only) — Flux GitOps inspection (defined in `apps/ai-system/flux-mcp/`).
- `vm-agent` — VictoriaMetrics query + TSDB analysis (defined in `apps/ai-system/victoria-metrics-mcp/`).
- `exa-agent` — Web search and research (defined in `apps/ai-system/exa-mcp/`).
- `cilium-debug-agent` — Cilium diagnosis (defined in `apps/ai-system/kagent/cilium-agents/`).
- `cilium-policy-agent` — Cilium policy authoring (defined in `apps/ai-system/kagent/cilium-agents/`).

**Disabled agents** (chart toggles): `argo-rollouts-agent`, `istio-agent`, `kgateway-agent`.

All 10 agents are deployed as classic `kind: Agent` CRs, which run in pod runtimes with `executeCodeBlocks: true` and isolated `sandbox` specs (see Agent Sandbox section below). Agent selection for MCP tasks is documented in [`.rules`](.rules); each agent has a specific domain and preferred use case.

### Agent Sandbox & Code Execution

The cluster runs **SIG-Apps `Sandbox`** CRD + controller (`agents.x-k8s.io`, pinned to `v0.5.0` with `controller.extensions: true`), which provides isolated, stateful single-pod runtimes for agents that opt into `executeCodeBlocks`. All 10 kagent agents are configured with code execution enabled.

**Multi-version CRD upgrade path**: `v0.5.0` graduated the core + extension APIs from `v1alpha1` to `v1beta1` (multi-version CRDs with a self-hosted conversion webhook served by the controller on `:9443`). Because the controller is installed into `ai-system` rather than the upstream-default `agent-sandbox-system`, it rewrites each CRD's `conversion.webhook.clientConfig.service.namespace` to `ai-system` at startup (via `--webhook-namespace`). On an in-place `v0.4.6`->`v0.5.0` upgrade, the controller can deadlock during initial cache sync if pre-existing `v1alpha1` CRs must be converted before its own webhook Service has Ready endpoints — clear the (ephemeral) Sandbox/SandboxClaim/SandboxTemplate/SandboxWarmPool CRs so the first sync has nothing to convert, then let it come up clean.

**Two hard requirements** (both learned the hard way):

1. **Ingress from the kube-apiserver to the conversion webhook (`:9443`) must be allowed.** `ai-system` runs implicit Cilium default-deny ingress (`allow-intra-namespace` selects `endpointSelector: {}`), and the apiserver runs host-network on a *remote* control-plane node, so it isn't covered by Cilium's allow-localhost exemption. Without an explicit allow, every `v1alpha1<->v1beta1 Sandbox` conversion the apiserver issues is silently dropped: the controller crash-loops on cache-sync, `kubectl get sandboxes` hangs, and anything that creates a `Sandbox` (executeCodeBlocks Agents, or old SandboxAgent reconciles) stalls to a 30s timeout. Fixed by the `allow-ingress-apiserver-to-sandbox-webhook` CiliumNetworkPolicy in `network-policies/policies/infra/ai-system.yaml` (`fromEntities: [kube-apiserver]` -> `:9443`). This rule is permanent (both for Sandbox CRD conversion on classic agents *and* for any future SandboxAgent use).

2. **Agent architecture: Classic `Agent` CRs only (not `SandboxAgent`)** — `SandboxAgent` was tried for all 10 agents and reverted (2026-06-27). The sandboxagent controller does create the Sandbox pod (and `/api/agents` lists it), but it never registers the agent in the controller's **A2A registry** — so the agent is *not invokable* via the kagent MCP server (`mcp.biggs.dog`) or UI (`/api/a2a/...` returns "Agent not found", and `list_agents` returns empty). There is no config knob to wire it up; it needs an upstream kagent code change. The agents stay as classic `kind: Agent` CRs (chart-managed toggles in the kagent HelmRelease for the built-ins; custom manifests under `flux-mcp/`, `victoria-metrics-mcp/`, `exa-mcp/`, and `kagent/cilium-agents/`), which remain fully invokable *and* still use the `Sandbox` controller for sandboxed code execution via `executeCodeBlocks`. The controller install (`apps/ai-system/agent-sandbox/`) is kept for that and for a future kagent release that wires `SandboxAgent` -> A2A.

**Sandbox network scoping**: Each agent declares allowed egress via `spec.sandbox.network.allowedDomains`:
- Most sandboxes lock egress to `*.svc.cluster.local`, so prompt-injected code can hit in-cluster services (e.g. query VictoriaMetrics directly via `requests`/`httpx`) but can't phone out to the internet.
- `flux-agent` is stricter still (`sandbox.network: {}` = no outbound network at all), since it's a read-only diagnostic agent whose code only needs tool-call results.
- That allow-list is layered on the namespace's Cilium policies (`allow-egress-internet` still governs the agent pods themselves); the sandbox allow-list is the tighter boundary for *executed* code specifically.

**Security & de-privileging**: The `vm-agent` runner is de-privileged (`runAsNonRoot`, drop `ALL` capabilities, `privileged: false`) because `executeCodeBlocks` writes to the container filesystem — kagent otherwise schedules agent pods privileged, which combined with tool access is too large a blast radius for a prompt-injectable LLM. **Caveat:** the chart-managed agents are *not* de-privileged (the `postRenderers` patches only add the sandbox fields, not a `securityContext`), so kagent still schedules their pods privileged — enabling code execution there raises blast radius until they're hardened the same way vm-agent is.

### Long-Term Memory

kagent is configured with vectorized memory (long-term, cross-session) backed by CNPG Postgres + pgvector, using the `embeddings` service for embedding generation. Per-agent memory is disabled on `flux-agent` (custom) because its ~64K tool schemas already bring the 131K context window to saturation; other agents have memory enabled and remain well under the cap (~20% KV cache peak under load).

### MCP Servers

- **Flux Operator MCP** (`flux-agent`) — read-only inspection of `FluxInstance`, sources, Kustomizations, HelmReleases, ResourceSets.
- **VictoriaMetrics MCP** (`vm-agent`) — PromQL/MetricsQL queries, alerting rules, TSDB cardinality analysis, embedded VM docs.
- **Exa MCP** (`exa-agent`) — Web search, code discovery, company research.
- **Kubernetes API** (all agents) — native k8s API via controller-runtime client.

### MCP Exposure & Routing

The MCP endpoint is the `kagent-mcp` HTTPRoute (`https://mcp.biggs.dog/mcp`) on the internal LAN-only gateway `internal-biggs-dog` (VIP 192.168.6.15). k8s-gateway split-horizon resolves `mcp.biggs.dog` to `.6.15` for LAN/VPN clients; TLS is terminated at the gateway with the wildcard cert, no auth. WAN clients hit the public gateway (no such route -> 404). This replaced the old `kagent-mcp-lan` plain-HTTP LoadBalancer (`192.168.6.13`, pinned via `io.cilium/lb-ipam-ips`) once the agentgateway was confirmed to no longer mangle the `/mcp` Streamable-HTTP path — verified end-to-end (initialize -> notifications/initialized -> tools/list) over the route. There is no server-side request timeout — long agentic loops complete because inference is fast (~250 tok/s single-stream), not because of a route timeout.

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

### Agents & MCP

- **The `SandboxAgent` gap is not a network/configuration issue** — the `kind: SandboxAgent` agent runs a pod successfully, but the kagent controller never registers it in the A2A registry (the in-memory map/service lookup that `mcp.biggs.dog` queries). No Service, no ingress rule, no helm value can fix this on kagent 0.9.10 — it requires upstream code that ties `SandboxAgent` reconciliation to A2A registration. This was verified by probing `/api/a2a/ai-system/flux-agent/.well-known/agent-card.json` → "Agent not found" (registry lookup, not network).
- **The apiserver→webhook netpol is non-obvious but critical** — Cilium's implicit default-deny dropped all apiserver traffic to the controller because the apiserver runs on a *remote* host (control-plane node). Took tracing through the CRD conversion path and the controller's deadlock during cache-sync to diagnose. This rule is now permanent (both for `SandboxAgent` use *and* for classic agents with `executeCodeBlocks`).
- **Git history is the source of truth for restoration** — when rolling back from a partial deployment state, the backup YAML contains *generated* objects (not the source manifests). Restoring from git history (`git checkout <commit> -- <file>`) is necessary to get the canonical, working manifests. Post-migration cleanup (e.g., kustomization.yaml deletions in custom agent app dirs) don't need to be restored — Flux auto-generates kustomizations for leaf app directories. Only the source manifests and the Flux Kustomization references need recovery.

## Future Improvements

- **Cilium Egress Gateway** — route outbound traffic through a dedicated node to stabilize external IPs (useful for services that block by IP).
- **Distributed Tracing** — add Jaeger or Tempo for end-to-end tracing across kafka, game streaming, and agent operations.
- **GPU Metrics Dashboard** — Grafana dashboard for DCGM metrics, game session lifecycle, vLLM scaling events.
- **Multi-cluster Flux** — expand to manage additional clusters (e.g., edge nodes) from a central repo.
- **Agent hardening** — de-privilege and add `securityContext` to chart-managed agents (currently only vm-agent is hardened).
