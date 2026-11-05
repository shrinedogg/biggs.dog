# 03 Live Inventory: agentgateway cutover inputs (cluster1)

Issue #746 (umbrella #745): pre-migration inventory for moving agentgateway from the legacy train (chart v2.2.1, controller v2.2.1, data plane 0.12.0) to the 1.x train (v1.7.0).

Captured live from cluster1 (read-only kubectl, KUBECONFIG biggs-dog) on 2026-11-05 ~20:40 EET, cross-checked against `~/Code/biggs.dog` (`clusters/cluster1/`). Raw JSON dumps: `/Users/shrinedogg/.hermes/cache/scratch/inv/raw/`. Secret values were never read; names and keys only.

| # | Surface | Live read-back | Verdict |
|---|---------|----------------|---------|
| 1 | Gateways (2) | Both Accepted=True, Programmed=True; every listener Accepted/Programmed/ResolvedRefs=True | Healthy |
| 2 | GatewayClass | `agentgateway`, controllerName `agentgateway.dev/agentgateway`, Accepted=True | Healthy |
| 3 | Data plane + controller | 3/3 pods Running, 0 restarts, all on worker-01 | Healthy |
| 4 | Gateway Services | 3 Services; both LBs have VIPs (192.168.6.15 / 192.168.6.7) | Healthy |
| 5 | HTTPRoutes | 28 routes, all Accepted=True and ResolvedRefs=True | Healthy |
| 6 | AgentgatewayPolicies | 11 policies, all Attached (route targets all Accepted) | Healthy |
| 7 | AgentgatewayBackends | 6 backends, all Accepted=True; 2 BackendTLPolicies present | Healthy |
| 8 | Cilium policies | 18 agentgateway-keyed CNPs (plus 2 for the separate k8s-gateway DNS component); live == repo | In sync |
| 9 | kagent ModelConfigs | 2 total; 1 references the gateway service (port 8445) | See 9 |
| 10 | Observability | VMPodScrape on data plane :15020 (internal only); 2 dashboards | See 10 |
| 11 | Flux HelmReleases | Both Ready=True InstallSucceeded (v2.2.1 / 0.0.0-alpha.a655af15) | Healthy |

## 1. Gateways (namespace `networking`)

Both Gateways live in `networking`, class `agentgateway`, created 2026-09-08T04:46:25Z, pinned in `spec.addresses` (matches `status.addresses`), labels `app.kubernetes.io/name=agentgateway` + Flux kustomization labels.

### Gateway `networking/internal-biggs-dog` (LAN-only, VIP 192.168.6.15)

| Listener | Port | Protocol | Hostname | TLS | allowedRoutes | Listener conditions |
|----------|------|----------|----------|-----|---------------|---------------------|
| internal-wildcard-http | 80 | HTTP | `*.biggs.dog` | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| internal-wildcard-https | 443 | HTTPS | `*.biggs.dog` | Terminate, certRef Secret `biggs-dog-tls` (ns networking) | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| model-actors-minimax | 8443 | HTTP | (none) | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| model-actors-glm | 8444 | HTTP | (none) | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| model-actors-vllm | 8445 | HTTP | (none) | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |

Gateway conditions: `Accepted=True` (reason Accepted), `Programmed=True` (reason Programmed, "Successfully programmed Gateway"). supportedKinds per listener: HTTPRoute + GRPCRoute (gateway.networking.k8s.io).

The three hostname-less 8443/8444/8445 listeners exist for the substrate actor path (issue #661): atenet-egress dials the address directly and rewrites Host to IP form, so hostname-less listeners pair with hostname-less catch-all HTTPRoutes. Plain HTTP by design (see repo note in `internal-gateway.yaml`). The VIP is not in the UDM WAN port-forward, so these ports are LAN/VPN only.

### Gateway `networking/wildcard-biggs-dog` (public, VIP 192.168.6.7)

| Listener | Port | Protocol | Hostname | TLS | allowedRoutes | Listener conditions |
|----------|------|----------|----------|-----|---------------|---------------------|
| wildcard-biggs-dog-http | 80 | HTTP | `*.biggs.dog` | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| wildcard-biggs-dog-https | 443 | HTTPS | `*.biggs.dog` | Terminate, certRef Secret `biggs-dog-tls` | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| biggs-dog-http | 80 | HTTP | `biggs.dog` | none | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |
| biggs-dog-https | 443 | HTTPS | `biggs.dog` | Terminate, certRef Secret `biggs-dog-tls` | namespaces: from All | Accepted=True, Conflicted=False, Programmed=True, ResolvedRefs=True |

Gateway conditions: `Accepted=True`, `Programmed=True`.

Repo cross-check: `kubernetes/apps/networking/agentgateway/app/gateway.yaml` (wildcard) and `internal-gateway.yaml` (internal) match the live spec exactly (listeners, TLS refs, addresses, allowedRoutes).

## 2. GatewayClass

| Name | controllerName | Accepted | parametersRef | Repo file |
|------|----------------|----------|---------------|-----------|
| `agentgateway` | `agentgateway.dev/agentgateway` | True | none | none (controller-created at startup, not in repo) |

Description: "Specialized class for agentgateway." Age 58d. Note the controllerName string: if the 1.x train renames it, every Gateway, CNP label match, and ModelConfig path that keys on this value must change with it.

## 3. Data-plane and controller workloads (namespace `networking`)

All pods on node `worker-01`, 0 restarts, started 2026-11-04 (25h old at capture). No nodeSelector, affinity, or tolerations on any of the three agentgateway deployments.

### Deployment `networking/agentgateway` (controller)

| Field | Value |
|-------|-------|
| Image | `cr.agentgateway.dev/controller:v2.2.1` |
| Replicas / strategy | 1, RollingUpdate |
| Container ports | 9978 TCP `grpc-xds-agw` (XDS gRPC), 9093 TCP `health`, 9092 TCP `metrics` |
| Args | (none) |
| Env (names) | GOMEMLIMIT, GOMAXPROCS, KGW_LOG_LEVEL, KGW_XDS_SERVICE_NAME, KGW_AGENTGAWAY_XDS_SERVICE_PORT, KGW_DEFAULT_IMAGE_REGISTRY, KGW_DEFAULT_IMAGE_TAG, KGW_DEFAULT_IMAGE_PULL_POLICY, KGW_DISCOVERY_NAMESPACE_SELECTORS, KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES, KGW_ENABLE_AGENTGATEWAY, KGW_ENABLE_ENVOY, KGW_GATEWAY_CLASS_PARAMETERS_REFS, POD_NAMESPACE |
| Env values (non-sensitive, chart/behavior knobs) | KGW_LOG_LEVEL=info, KGW_XDS_SERVICE_NAME=agentgateway, KGW_AGENTGATEWAY_XDS_SERVICE_PORT=9978, KGW_DEFAULT_IMAGE_REGISTRY=cr.agentgateway.dev, KGW_DEFAULT_IMAGE_TAG=v2.2.1, KGW_DEFAULT_IMAGE_PULL_POLICY=IfNotPresent, KGW_DISCOVERY_NAMESPACE_SELECTORS=[], KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true, KGW_ENABLE_AGENTGATEWAY=true, KGW_ENABLE_ENVOY=false, KGW_GATEWAY_CLASS_PARAMETERS_REFS={} |
| ServiceAccount | `agentgateway` |
| Resources | none (no requests/limits) |
| Probes | readiness HTTP `:9093/readyz` (10s); no liveness |
| Pod annotations | prometheus.io/scrape=true, prometheus.io/port=9092, prometheus.io/path=/metrics |
| Security | podSecurityContext seccompProfile RuntimeDefault; container: allowPrivilegeEscalation=false, drop ALL caps, seccomp RuntimeDefault (from HelmRelease values) |
| Pod | `agentgateway-55ddbb4c55-7hgz2`, 10.244.1.241, worker-01 |

### Deployment `networking/internal-biggs-dog` (data plane for Gateway internal-biggs-dog)

| Field | Value |
|-------|-------|
| Image | `cr.agentgateway.dev/agentgateway:0.12.0` |
| Replicas / strategy | 1, RollingUpdate |
| Container ports (declared) | 15020 TCP `metrics` (listener ports 80/443/8443-8445 are bound directly, see sysctl) |
| Args | `-f /config/config.yaml` |
| Env (names) | TERMINATION_GRACE_PERIOD_SECONDS, CONNECTION_MIN_TERMINATION_DEADLINE, NODE_NAME, POD_NAMESPACE, POD_NAME, RUST_BACKTRACE, RUST_LOG, XDS_ADDRESS, NAMESPACE, GATEWAY, CPU_LIMIT, INSTANCE_IP, SERVICE_ACCOUNT |
| ServiceAccount | `internal-biggs-dog` |
| Resources | none (no requests/limits) |
| Probes | readiness HTTP `:15021/healthz/ready` (10s); no liveness |
| Pod annotations | prometheus.io/scrape=true, prometheus.io/port=15020, checksum/config annotation |
| Volumes | `config-volume` (ConfigMap `internal-biggs-dog`, key config.yaml = `config: {}`; real config comes over XDS), `xds-token` (projected SA token, audience `kgateway`, 12h expiry), `tmp` (emptyDir) |
| Pod security | sysctl `net.ipv4.ip_unprivileged_port_start=0`; container: runAsNonRoot, runAsUser=10101, readOnlyRootFilesystem=true, drop ALL caps |
| Labels (on pod) | `gateway.networking.k8s.io/gateway-name=internal-biggs-dog`, `gateway.networking.k8s.io/gateway-class-name=agentgateway`, `app.kubernetes.io/name=internal-biggs-dog`, `app.kubernetes.io/instance=internal-biggs-dog` |
| Pod | `internal-biggs-dog-5457f856f6-h9plg`, 10.244.1.118, worker-01 |

### Deployment `networking/wildcard-biggs-dog` (data plane for Gateway wildcard-biggs-dog)

Identical shape to internal-biggs-dog: image `cr.agentgateway.dev/agentgateway:0.12.0`, replicas 1, args `-f /config/config.yaml`, same env names, SA `wildcard-biggs-dog`, ConfigMap `wildcard-biggs-dog`, readiness `:15021/healthz/ready`, same sysctl and security context. Labels `gateway.networking.k8s.io/gateway-name=wildcard-biggs-dog` / `app.kubernetes.io/name=wildcard-biggs-dog`. Pod `wildcard-biggs-dog-7745bd89df-g6lk6`, 10.244.1.205, worker-01.

XDS chain: data plane authenticates to the controller with the projected token (audience `kgateway`) against `KGW_XDS_SERVICE_NAME=agentgateway` :9978; mTLS material comes from cert-manager in `networking`: Certificate `agentgateway-xds-cert` (secret `agentgateway-xds-cert`, READY) issued by Issuer `agentgateway-xds-ca-issuer` <- self-signed CA `agentgateway-xds-ca` (secret `agentgateway-xds-ca-secret`, READY, root `agentgateway-xds-root-issuer`). All 59d, all Ready=True. Repo files: `cert-manager/cert-manager/{certificates,ca-certificates,issuers}/agentgateway-xds-*.yaml`.

### Separate component (inventory only, NOT agentgateway): k8s-gateway

| Field | Value |
|-------|-------|
| Deployment | `networking/k8s-gateway`, 2 replicas, image `codeberg.org/k8s-gateway/k8s_gateway:1.9.2` (chart k8s-gateway@4.0.1, HelmRelease networking/k8s-gateway Ready=True) |
| Role | CoreDNS plugin that answers the `biggs.dog` zone (split-horizon DNS to gateway VIPs) |
| Service | `networking/k8s-gateway` LoadBalancer, VIP 192.168.6.6, :53 UDP+TCP |
| Corefile | zone `biggs.dog.:1053`, `k8s_gateway biggs.dog { apex k8s-gateway.networking; resources HTTPRoute Service; fallthrough biggs.dog }`; explicit hosts `192.168.2.31 omni.biggs.dog dex.biggs.dog netbird.biggs.dog factory.biggs.dog`; forward . 45.90.28.232 45.90.30.232 |
| CNP | `networking/k8s-gateway` (egress kube-apiserver/cluster + world:53) |

Also related but substrate-owned: `ai-system/atenet-egress` and `ai-system/atenet-router` Deployments (1 replica each, on nv-01 via the substrate HelmRelease nodeSelector patch) run image `cr.agentgateway.dev/agentgateway:v0.0.0-alpha.168b05d6@sha256:5e8384...` (an agentgateway-repo build, deployed by the substrate chart, not the agentgateway chart). atenet-egress is the pod that carries actor egress to the internal gateway (see section 8).

## 4. Gateway-related Services (namespace `networking`)

| Service | Type | VIP | Selector | Ports (name : port -> targetPort) |
|---------|------|-----|----------|-----------------------------------|
| `internal-biggs-dog` | LoadBalancer | 192.168.6.15 (VIP mode) | app.kubernetes.io/instance+name=internal-biggs-dog, gateway-name=internal-biggs-dog | listener-80:80, listener-443:443, listener-8443:8443, listener-8444:8444, listener-8445:8445 (all TCP) |
| `wildcard-biggs-dog` | LoadBalancer | 192.168.6.7 (VIP mode) | app.kubernetes.io/instance+name=wildcard-biggs-dog, gateway-name=wildcard-biggs-dog | listener-80:80, listener-443:443 (both TCP) |
| `agentgateway` (controller) | ClusterIP | 10.108.53.245 | agentgateway=agentgateway, app.kubernetes.io/name=agentgateway | grpc-xds-agw:9978, health:9093 (both TCP; metrics 9092 is NOT exposed on the Service) |

Service ports are synced by the controller from Gateway listeners (ownerReference on the Services). The controller Service has no metrics port; controller metrics rely on the pod annotation plus vmagent annotation discovery.

## 5. All HTTPRoutes in the cluster (28)

All 28 read back with parent conditions `Accepted=True` and `ResolvedRefs=True`. ParentRefs all point at class `agentgateway` Gateways in `networking`. All backendRefs are weight 1 (only backendRefs shown; multi-rule routes list one row per rule).

| ns/name | Hostnames | parentRef (sectionName) | Match (path) | backendRefs (kind/name:port) | Filter | Status |
|---------|-----------|--------------------------|--------------|-------------------------------|--------|--------|
| ai-system/embeddings | embeddings.biggs.dog | internal-biggs-dog | PathPrefix /v1/embeddings | Service ai-system/embeddings:7997 | URLRewrite -> /embeddings | Accepted, ResolvedRefs |
| ai-system/kagent | kagent.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service ai-system/kagent-ui:8080 | - | Accepted, ResolvedRefs |
| ai-system/kagent-mcp | mcp.biggs.dog | internal-biggs-dog | PathPrefix / | Service ai-system/kagent-controller:8083 | - | Accepted, ResolvedRefs |
| ai-system/minimax | minimax.biggs.dog | internal-biggs-dog | PathPrefix / | AgentgatewayBackend ai-system/minimax | - | Accepted, ResolvedRefs |
| ai-system/mistral | mistral.biggs.dog | internal-biggs-dog | PathPrefix / | AgentgatewayBackend ai-system/mistral | - | Accepted, ResolvedRefs |
| ai-system/model-actors | (none) | internal-biggs-dog (sectionName model-actors-minimax) | PathPrefix / | AgentgatewayBackend ai-system/minimax | - | Accepted, ResolvedRefs |
| ai-system/model-actors-glm | (none) | internal-biggs-dog (sectionName model-actors-glm) | PathPrefix / | AgentgatewayBackend ai-system/glm | - | Accepted, ResolvedRefs |
| ai-system/model-actors-vllm | (none) | internal-biggs-dog (sectionName model-actors-vllm) | PathPrefix / | AgentgatewayBackend ai-system/vllm | - | Accepted, ResolvedRefs |
| ai-system/vllm | vllm.biggs.dog | internal-biggs-dog | PathPrefix / | Service ai-system/vllm:8000 | - | Accepted, ResolvedRefs |
| auth/oauth2-proxy | auth.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service auth/oauth2-proxy:80 | - | Accepted, ResolvedRefs |
| auth/pocket-id | id.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service auth/pocket-id:1411 | - | Accepted, ResolvedRefs |
| biggs/biggs-dog | biggs.biggs.dog, biggs.dog | wildcard-biggs-dog | PathPrefix / | Service biggs/biggs-service:8080 | - | Accepted, ResolvedRefs |
| kritika/kritika | kritika.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service kritika/kritika:8080 | - | Accepted, ResolvedRefs |
| livekit/livekit-route | livekit.biggs.dog | wildcard-biggs-dog | PathPrefix /sfu/get | Service livekit/lk-jwt-service:8081 | - | Accepted, ResolvedRefs |
| livekit/livekit-route | livekit.biggs.dog | wildcard-biggs-dog | PathPrefix /get_token | Service livekit/lk-jwt-service:8081 | - | Accepted, ResolvedRefs |
| livekit/livekit-route | livekit.biggs.dog | wildcard-biggs-dog | PathPrefix /healthz | Service livekit/lk-jwt-service:8081 | - | Accepted, ResolvedRefs |
| livekit/livekit-route | livekit.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service livekit/livekit-service:7880 | - | Accepted, ResolvedRefs |
| matrix/continuwuity | matrix.biggs.dog | wildcard-biggs-dog | PathPrefix /_matrix | Service matrix/continuwuity-service:8080 | - | Accepted, ResolvedRefs |
| matrix/continuwuity | matrix.biggs.dog | wildcard-biggs-dog | PathPrefix /_continuwuity/ | Service matrix/continuwuity-service:8080 | - | Accepted, ResolvedRefs |
| matrix/continuwuity | matrix.biggs.dog | wildcard-biggs-dog | PathPrefix /.well-known/matrix | Service matrix/continuwuity-service:8080 | - | Accepted, ResolvedRefs |
| matrix/continuwuity-well-known | biggs.dog | wildcard-biggs-dog (sectionName biggs-dog-https) | PathPrefix /.well-known/matrix | Service matrix/continuwuity-service:8080 | - | Accepted, ResolvedRefs |
| matrix/sable | sable.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service matrix/sable-service:8080 | - | Accepted, ResolvedRefs |
| media/bookboss | bookboss.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service media/bookboss-service:8080 | - | Accepted, ResolvedRefs |
| media/bookboss-kobo | bookboss.biggs.dog | wildcard-biggs-dog | PathPrefix /kobo | Service media/bookboss-service:8080 | - | Accepted, ResolvedRefs |
| media/bookboss-oidc | bookboss.biggs.dog | wildcard-biggs-dog | PathPrefix /auth/oidc | Service media/bookboss-service:8080 | - | Accepted, ResolvedRefs |
| media/silo | silo.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service media/silo-service:8080 | - | Accepted, ResolvedRefs |
| mindwtr/mindwtr | mindwtr.biggs.dog | internal-biggs-dog | PathPrefix /health | Service mindwtr/mindwtr-cloud:8787 | - | Accepted, ResolvedRefs |
| mindwtr/mindwtr | mindwtr.biggs.dog | internal-biggs-dog | PathPrefix /v1 | Service mindwtr/mindwtr-cloud:8787 | - | Accepted, ResolvedRefs |
| mindwtr/mindwtr | mindwtr.biggs.dog | internal-biggs-dog | PathPrefix / | Service mindwtr/mindwtr-app:5173 | - | Accepted, ResolvedRefs |
| networking/cluster0-dex | dex.biggs.dog | wildcard-biggs-dog | PathPrefix / | AgentgatewayBackend networking/cluster0-dex | - | Accepted, ResolvedRefs |
| networking/cluster0-omni | omni.biggs.dog | wildcard-biggs-dog | PathPrefix / | AgentgatewayBackend networking/cluster0-omni | - | Accepted, ResolvedRefs |
| observability/grafana | grafana.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service observability/grafana:80 | - | Accepted, ResolvedRefs |
| renovate/renovate | renovate.biggs.dog | wildcard-biggs-dog | PathPrefix /webhook | Service renovate/renovate-service:8080 | - | Accepted, ResolvedRefs |
| rook-ceph/rook-ceph | rook-ceph.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service rook-ceph/rook-ceph-mgr-dashboard:7000 | - | Accepted, ResolvedRefs |
| zot/zot | zot.biggs.dog | wildcard-biggs-dog | PathPrefix / | Service zot/zot:8080 | - | Accepted, ResolvedRefs |

Route count by parent Gateway: internal-biggs-dog = 9 routes (11 rules: 8 ai-system routes with 1 rule each plus mindwtr/mindwtr with 3 rules), wildcard-biggs-dog = 19 routes (23 rules). Cutover-critical details: (a) sectionName parentRefs target listener names, not ports (model-actors-minimax/glm/vllm, biggs-dog-https); (b) the only URLRewrite filter is on ai-system/embeddings; (c) hostname-less routes only exist for the 8443-8445 listener path.

Repo cross-check: all 28 routes have repo sources under `kubernetes/apps/<ns>/...` (agentgateway-ai/app/route*.yaml, kagent/app/kagent-mcp-route.yaml, vllm/app/embeddings-route.yaml, networking/agentgateway/app/cluster0-edge.yaml, and one HTTPRoute per app namespace). No live-only or repo-only routes found in this pass.

## 6. All AgentgatewayPolicies (11)

CRD `agentgatewaypolicies.agentgateway.dev`, group `agentgateway.dev/v1alpha1`, Namespaced. All targetRefs are HTTPRoutes in the same namespace. "Attached" verified by the target route's Accepted condition (all True).

| ns/name | targetRef (sectionName) | Type | Summary | Accepted / Attached |
|---------|--------------------------|------|---------|---------------------|
| ai-system/kagent-mcp-api-key | HTTPRoute kagent-mcp | apiKeyAuthentication | mode Strict, secretRef `kagent-mcp-api-keys` (ai-system) | route Accepted=True |
| ai-system/kagent-ui-forward-auth | HTTPRoute kagent | extAuth | Service auth/oauth2-proxy:80; path "/oauth2/auth"; redirect to https://auth.biggs.dog/oauth2/start?rd=https://kagent.biggs.dog + path; allowed req headers cookie, authorization; allowed resp headers authorization, x-auth-request-user/email/groups/preferred-username | route Accepted=True |
| ai-system/model-api-key | HTTPRoute minimax | apiKeyAuthentication + rateLimit | Strict, secretRef `model-api-keys`; local rate limit 120 requests, burst 40, unit Minutes | route Accepted=True |
| ai-system/model-api-key-actors | HTTPRoute model-actors | apiKeyAuthentication + rateLimit | same as model-api-key (120/40 Minutes) | route Accepted=True |
| ai-system/model-api-key-actors-glm | HTTPRoute model-actors-glm | apiKeyAuthentication + rateLimit | same as model-api-key (120/40 Minutes) | route Accepted=True |
| ai-system/model-api-key-actors-vllm | HTTPRoute model-actors-vllm | apiKeyAuthentication + rateLimit | same as model-api-key (120/40 Minutes) | route Accepted=True |
| ai-system/model-api-key-mistral | HTTPRoute mistral | apiKeyAuthentication + rateLimit | same as model-api-key (120/40 Minutes) | route Accepted=True |
| media/bookboss-forward-auth | HTTPRoute bookboss | extAuth | Service auth/oauth2-proxy:80; redirect rd=https://bookboss.biggs.dog; same header allowlists | route Accepted=True |
| media/silo-x-forwarded-proto | HTTPRoute silo | headerModifiers | set request header X-Forwarded-Proto: https | route Accepted=True |
| mindwtr/mindwtr-forward-auth | HTTPRoute mindwtr (sectionName pwa) | extAuth | Service auth/oauth2-proxy:80; redirect rd=https://mindwtr.biggs.dog; same header allowlists. Note: targets sectionName `pwa` (rule-level attachment on the /v1 rule) | route Accepted=True |
| rook-ceph/rook-ceph-forward-auth | HTTPRoute rook-ceph | extAuth | Service auth/oauth2-proxy:80; redirect rd=https://rook-ceph.biggs.dog; same header allowlists | route Accepted=True |

Cross-namespace reference support: ReferenceGrant `auth/extauth-to-oauth2-proxy` (gateway.networking.k8s.io/v1beta1) allows AgentgatewayPolicy in namespaces `rook-ceph`, `media`, `ai-system` to reference Service `auth/oauth2-proxy`. Live == repo (`kubernetes/apps/auth/oauth2-proxy/app/reference-grant.yaml`).

Secrets referenced by policies (names only): `kagent-mcp-api-keys`, `model-api-keys` (both in ai-system).

## 7. All AgentgatewayBackends (6) + BackendTLPolicies (2)

CRD `agentgatewaybackends.agentgateway.dev`, group `agentgateway.dev/v1alpha1`, Namespaced.

| ns/name | Kind | Host | Port | pathPrefix | Auth secret (name) | TLS/SNI | AI routes (path -> action) | Status |
|---------|------|------|------|------------|--------------------|---------|---------------------------|--------|
| ai-system/minimax | ai (openai provider) | api.minimax.io | 443 | (none) | `minimax-api-key` | sni: api.minimax.io | / -> Passthrough, /v1/chat/completions -> Completions, /v1/models -> Passthrough | Accepted=True |
| ai-system/glm | ai (openai provider) | api.z.ai | 443 | /api/coding/paas/v4 | `zai-api-key` | none | same three route actions | Accepted=True |
| ai-system/mistral | ai (openai provider) | api.mistral.ai | 443 | (none) | `mistral-api-key` | none | same three route actions | Accepted=True |
| ai-system/vllm | ai (openai provider) | vllm.ai-system.svc.cluster.local | 8000 | (none) | `kagent-vllm` | none | same three route actions | Accepted=True |
| networking/cluster0-dex | static | 192.168.2.31 | 443 | (none) | (none) | via BackendTLSPolicy below | - | Accepted=True |
| networking/cluster0-omni | static | 192.168.2.31 | 443 | (none) | (none) | via BackendTLSPolicy below | - | Accepted=True |

BackendTLPolicies (gateway.networking.k8s.io/v1, namespace networking) completing the cluster0 re-encryption hop:

| ns/name | targetRef | validation |
|---------|-----------|------------|
| networking/cluster0-dex | AgentgatewayBackend cluster0-dex | hostname dex.biggs.dog, wellKnownCACertificates System |
| networking/cluster0-omni | AgentgatewayBackend cluster0-omni | hostname omni.biggs.dog, wellKnownCACertificates System |

Both live, both present in repo `networking/agentgateway/app/cluster0-edge.yaml` (live == repo, including the HTTPRoutes in the same file). The `ai` route table (`Passthrough` vs `Completions`) is the LLM-usage-metrics mechanism that feeds the dashboards in section 10; it is a 2.x-train AgentgatewayBackend schema feature and must be re-validated against the 1.x API.

AgentgatewayParameters: none exist in the cluster (0 objects).

## 8. Cilium policies governing the gateway (live + repo cross-check)

Repo file for the atenet-egress path: `kubernetes/apps/network-policies/policies/infra/ai-system.yaml`; gateway-plane policies in `policies/infra/networking.yaml`; per-app ingress allowances in `policies/apps/*.yaml`. All entries below verified live and matching the repo byte-for-byte in the fields that matter (selector, endpoints, ports).

### The atenet-egress path (substrate actors -> internal gateway)

| ns/name | Selects | Rule |
|---------|---------|------|
| ai-system/allow-egress-to-agentgateway | pods with `app=atenet-egress` | egress toEndpoints: networking pods labeled `gateway.networking.k8s.io/gateway-name=internal-biggs-dog`, ports 8443, 8444, 8445 TCP only. Deliberately keyed on gateway-NAME so the public wildcard-biggs-dog data plane stays unreachable from actors. No world egress granted. |

Return path: the ClusterIP reverse-NAT reply carries the data-plane pod identity, already allowed by ai-system/allow-ingress-from-gateway; gateway side accepts via networking/agentgateway-dataplane (fromEntities: cluster).

### Gateway plane (namespace networking)

| ns/name | Selects | Rule |
|---------|---------|------|
| networking/agentgateway | `app.kubernetes.io/name=agentgateway` (controller pod) | egress: cluster (all) + world :443 TCP; ingress: from world, cluster, host, remote-node (all ports) |
| networking/agentgateway-dataplane | `gateway.networking.k8s.io/gateway-class-name=agentgateway` (both data-plane pods) | egress: cluster (all) + world :443 TCP; ingress: from world, cluster, host, remote-node (all ports) |

### Per-app ingress allowances (gateway -> app)

All use `fromEndpoints`: networking pods with `app.kubernetes.io/name=agentgateway` OR `gateway.networking.k8s.io/gateway-class-name=agentgateway`.

| ns/name | endpointSelector | Port restriction |
|---------|------------------|------------------|
| ai-system/allow-ingress-from-gateway | {} (all ai-system pods) | none |
| auth/allow-ingress-from-gateway | {} | none |
| biggs/allow-ingress-from-gateway | {} | none |
| games/allow-ingress-from-gateway | {} | none |
| livekit/allow-ingress-from-gateway | {} | none |
| matrix/allow-ingress-from-gateway | {} | none |
| media/allow-ingress-from-gateway | {} | none |
| mindwtr/allow-ingress-from-gateway | {} | toPorts 5173, 8787 TCP |
| observability/allow-ingress-from-gateway | `app.kubernetes.io/name=grafana` | none |
| renovate/allow-ingress-from-gateway | {} | none |
| rook-ceph/allow-ingress-from-gateway | `rook_cluster=rook-ceph` | none |

### App egress back into the gateway (app -> data plane)

| ns/name | Selects | Rule |
|---------|---------|------|
| auth/allow-egress-oidc | `app.kubernetes.io/name=oauth2-proxy` | egress toFQDN id.biggs.dog:443 + toEndpoints `app.kubernetes.io/name=wildcard-biggs-dog` (networking) :443 + pocket-id:1411 |
| media/allow-egress-to-pocket-id | app in [bookboss, silo] | egress toEndpoints `app.kubernetes.io/name=agentgateway` OR gateway-class-name=agentgateway (networking) :443 |
| matrix/allow-egress-to-gateway | {} (all matrix pods) | egress toEndpoints gateway-class-name=agentgateway (networking) :443 |
| livekit/allow-egress-lk-jwt-to-matrix | `app.kubernetes.io/name=lk-jwt-service` | egress toCIDR 192.168.6.7/32 :443 + toEndpoints `app.kubernetes.io/name=wildcard-biggs-dog` :443 + toFQDN biggs.dog, matrix.biggs.dog :443 |

Cutover exposure: every policy above selects data-plane pods by the labels `gateway.networking.k8s.io/gateway-name=<gateway>` and/or `gateway.networking.k8s.io/gateway-class-name=agentgateway` (plus `app.kubernetes.io/name=<gateway-name>` in the app-egress rules). If the 1.x controller changes any of these pod labels, deployment names, or the gateway-class-name string, all 18 policies plus the VMPodScrape selector break silently.

## 9. kagent ModelConfigs referencing gateway hostnames

CRD `modelconfigs.api.kagent.dev` (group api.kagent.dev/v1alpha3, Namespaced). 2 exist, both in ai-system.

| ns/name | model | provider | baseUrl | References gateway? |
|---------|-------|----------|---------|---------------------|
| ai-system/default-model-config | qwen 3.8 - local | OpenAI (chatCompletions, stream=true) | `http://internal-biggs-dog.networking.svc.cluster.local:8445/v1` | YES: the internal gateway's cluster Service on the model-actors-vllm listener (8445). Chain: :8445 listener -> HTTPRoute model-actors-vllm -> AgentgatewayBackend ai-system/vllm -> vllm.ai-system.svc:8000 |
| ai-system/embedding-model | BAAI/bge-m3 | OpenAI (chatCompletions, stream=true) | `http://embeddings.ai-system.svc.cluster.local:7997` | No: hits the embeddings Service directly |

API key wiring: default-model-config uses secret `model-api-keys` key `editor`; embedding-model uses secret `kagent-vllm` key `OPENAI_API_KEY` (names only).

Implication: default-model-config depends on (a) the Service name `internal-biggs-dog` staying in `networking`, (b) port 8445 staying on that Service, and (c) the route/backend chain on the 8445 listener. Renaming the internal gateway or its Service breaks kagent's default model.

## 10. Observability wiring (live + repo)

| Item | Kind / location | What it references | Status |
|------|-----------------|--------------------|--------|
| agentgateway-internal | VMPodScrape `networking/agentgateway-internal` | selector `gateway.networking.k8s.io/gateway-name=internal-biggs-dog`, namespaceSelector matchNames [networking], endpoint targetPort 15020 path /metrics interval 30s, podTargetLabels [gateway.networking.k8s.io/gateway-name] | Live, matches repo `networking/agentgateway/app/vmpodscrape.yaml` |
| (controller) | pod annotation prometheus.io/scrape=true, port 9092, path /metrics on the controller pod template | no VMPodScrape/VMServicesScrape exists; relies on vmagent annotation discovery | Live |
| (data plane pods) | pod annotation prometheus.io/scrape=true, port 15020 | same as above; the internal data plane is covered twice (annotation + VMPodScrape) | Live |
| kagent dashboard | ConfigMap `observability/kagent-dashboard` (repo: `observability/dashboards/app/kagent.yaml`) | panels query `agentgateway_gen_ai_client_token_usage_sum{namespace="networking"}` (rate 5m, increase 1h) by gen_ai_request_model / gen_ai_token_type | Live, repo present |
| networking-infrastructure dashboard | ConfigMap `observability/networking-infrastructure-dashboard` (repo: `observability/dashboards/app/networking-infrastructure.yaml`) | tagged ["networking","dns","coredns","k8s-gateway","agentgateway"] | Live, repo present |
| ai-system/allow-prometheus-scraping | CNP | allows ingress from observability ns to all ai-system pods (scrape side for agent pods) | Live == repo |

Gap worth noting: the wildcard-biggs-dog data plane has no VMPodScrape (only the prometheus.io annotation), and no scrape config targets the controller Service (metrics port 9092 not on the Service). If 1.x renames the metric prefix (currently `agentgateway_gen_ai_client_token_usage_sum`), both kagent dashboard panels and the token-metrics chain break.

## 11. Flux sources and HelmReleases

Namespace correction: the two agentgateway HelmReleases live in `networking`, not `flux-system` (verified with `kubectl -A get helmrelease`).

| Object | ns | Key fields |
|--------|----|-----------|
| OCIRepository `agentgateway` | flux-system | url `oci://ghcr.io/agentgateway/charts/agentgateway`, ref tag `v2.2.1`, interval 1h |
| OCIRepository `agentgateway-crds` | flux-system | url `oci://ghcr.io/agentgateway/charts/agentgateway-crds`, ref tag `0.0.0-alpha.a655af15`, interval 1h |
| HelmRelease `agentgateway` | networking | chartRef -> OCIRepository agentgateway (flux-system); interval 3m; values: controller.extraEnv KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES="true", podSecurityContext seccomp RuntimeDefault, securityContext (allowPrivilegeEscalation false, drop ALL, seccomp RuntimeDefault) |
| HelmRelease `agentgateway-crds` | networking | chartRef -> OCIRepository agentgateway-crds (flux-system); interval 3m; no values |

Read-back status (Flux v2 status schema; there is no `lastAppliedRevision` field in this Flux version, the equivalent is `status.lastAttemptedRevision`):

| HelmRelease | Ready | lastAttemptedRevision | revision digest | history | conditions |
|-------------|-------|------------------------|-----------------|---------|------------|
| networking/agentgateway | True (reason InstallSucceeded) | v2.2.1 | sha256:f7497fcb08f73fdad9f60fb54a9623aa8e3a53a485ed78269f8cc80d38eaab94 | v1 install, deployed 2026-09-08T04:46:26Z, chart agentgateway@v2.2.1, configDigest sha256:4250c54e... | Ready=True, Released=True (InstallSucceeded) |
| networking/agentgateway-crds | True (reason InstallSucceeded) | 0.0.0-alpha.a655af15 | sha256:6cc3fdc7be0bc7604510513659482b7064f89e0a945c89688fddae66bce03358 | v1 install, deployed 2026-09-07T17:27:06Z, chart agentgateway-crds@0.0.0-alpha.a655af15 | Ready=True, Released=True (InstallSucceeded) |

Both at observedGeneration=1 / generation=1 (no drift ever recorded). CRD inventory (from HelmRelease inventory): agentgatewaybackends, agentgatewayparameters, agentgatewaypolicies (agentgateway.dev). Main release inventory: ServiceAccount, ClusterRole, ClusterRoleBinding, Service, Deployment (all in networking). Repo cross-check: `networking/agentgateway/app/helmrelease.yaml`, `agentgateway-crds/helmrelease.yaml`, and the two OCI source files all match live values exactly.

## 12. What the 1.x cutover must preserve (checklist)

Derived from sections 1-11. Each item is a breakage risk if it changes.

| # | Must preserve | Why (verified dependency) |
|---|---------------|---------------------------|
| 1 | GatewayClass name `agentgateway` and controllerName (or update in one coordinated pass) | 2 Gateways reference the class; 20 CNPs match `gateway-class-name=agentgateway`; 11 policies and 6 backends hang off this class's data plane |
| 2 | Gateway names `internal-biggs-dog` and `wildcard-biggs-dog` in ns networking, with pinned spec.addresses 192.168.6.15 / 192.168.6.7 | Service names, CNP selectors, VMPodScrape selector, ModelConfig URL, k8s-gateway DNS apex, and the UDM WAN port-forward all key on these names/VIPs |
| 3 | All 9 listeners with exact names, ports, hostnames, TLS refs | sectionName parentRefs name the listeners model-actors-minimax (8443), model-actors-glm (8444), model-actors-vllm (8445), biggs-dog-https (443); TLS certRef `biggs-dog-tls` on all HTTPS listeners; allowedRoutes from=All on every listener |
| 4 | The hostname-less HTTP listeners on 8443/8444/8445 (no TLS, no hostname) | atenet-egress rewrites Host to IP form; hostname-matched listeners would never match (documented in internal-gateway.yaml, issue #661) |
| 5 | All 28 HTTPRoutes with hostnames, parentRefs (incl. sectionNames), path prefixes, the single URLRewrite filter, and all backendRefs | every *.biggs.dog entrypoint; includes 3 multi-rule routes (livekit-route, matrix/continuwuity, mindwtr/mindwtr) and 5 AgentgatewayBackend refs |
| 6 | All 6 AgentgatewayBackends incl. AI provider hosts, glm pathPrefix `/api/coding/paas/v4`, minimax TLS SNI, auth secret names, and the ai.routes table (Passthrough/Completions/Passthrough) | LLM egress for minimax/glm/mistral/vllm; Completions action is what produces the token metrics |
| 7 | Both BackendTLPolicies (dex/omni hostname validation, System CA) | cluster0 re-encryption hop for omni.biggs.dog and dex.biggs.dog |
| 8 | All 11 AgentgatewayPolicies: 5x API-key auth on secret `model-api-keys` + rate limit 120/40 per Minutes, 1x on `kagent-mcp-api-keys`, 4x extAuth to auth/oauth2-proxy:80 with per-app redirect, 1x X-Forwarded-Proto header set, incl. the mindwtr sectionName=pwa attachment | auth for every model route, kagent UI, mcp, bookboss, mindwtr PWA, rook-ceph dashboard; silo needs the proto header |
| 9 | ReferenceGrant auth/extauth-to-oauth2-proxy (from rook-ceph, media, ai-system) | cross-namespace extAuth backendRef requires it |
| 10 | Data-plane per-Gateway deployment named after the Gateway, pod labels gateway-name / gateway-class-name, SA internal-biggs-dog / wildcard-biggs-dog, xds-token audience kgateway, ConfigMap config volume, sysctl ip_unprivileged_port_start=0, runAsUser 10101, readiness :15021 | CNP selectors, VMPodScrape, Service selectors, and the unprivileged 80/443 bind all depend on these |
| 11 | Services: internal-biggs-dog LB (ports listener-80/443/8443/8444/8445), wildcard-biggs-dog LB (80/443), controller ClusterIP 9978/9093, VIPs .6.15/.6.7 | UDM forwards WAN :80/:443 to .6.7 only (LAN-only property of .6.15 depends on the VIP set not changing); ModelConfig dials internal-biggs-dog.networking.svc:8445 |
| 12 | XDS chain: controller :9978, KGW_XDS_SERVICE_NAME=agentgateway, cert-manager agentgateway-xds-cert + CA in networking | data plane cannot receive config without it |
| 13 | All 18 gateway-related CiliumNetworkPolicies (section 8 list) with their label selectors unchanged | silent drops if pod labels/deployment names change; the atenet-egress -> gateway-name=internal-biggs-dog 8443-8445 rule is the only model egress for substrate actors |
| 14 | ModelConfig ai-system/default-model-config baseUrl http://internal-biggs-dog.networking.svc.cluster.local:8445/v1 (+ secret model-api-keys key editor) | kagent's default model endpoint; breaks on gateway/service rename or 8445 port change |
| 15 | VMPodScrape networking/agentgateway-internal (selector gateway-name=internal-biggs-dog, :15020, 30s, gateway-name pod label) and the metric name agentgateway_gen_ai_client_token_usage_sum | LLM token dashboards (kagent dashboard) and rate-limit observability |
| 16 | k8s-gateway Corefile biggs.dog zone (apex k8s-gateway.networking, explicit 192.168.2.31 hosts for omni/dex/netbird/factory) | split-horizon DNS to the gateway VIPs; separate component (k8s-gateway 1.9.2 / chart 4.0.1) that must keep resolving the same VIPs |
| 17 | Substrate atenet-egress / atenet-router (image cr.agentgateway.dev/agentgateway:v0.0.0-alpha.168b05d6, on nv-01) | built from the agentgateway repo; cutover must verify the actor egress proxy still works against the 1.x data plane |
| 18 | Flux wiring: OCIRepository tag bumps (charts agentgateway + agentgateway-crds) and HelmRelease values (KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true + security hardening) re-validated against the 1.x chart schema | current values target the v2.2.1 schema (top-level podSecurityContext/securityContext); 1.x chart keys may differ |
| 19 | Secrets by name: biggs-dog-tls (networking), model-api-keys (key editor), kagent-mcp-api-keys, minimax-api-key, zai-api-key, mistral-api-key, kagent-vllm (ai-system) | every auth path above; values never read during this inventory |
| 20 | No AgentgatewayParameters exist today (0 objects) | if 1.x expects parametersRef on the GatewayClass, decide whether to introduce them during cutover |
