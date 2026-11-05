# agentgateway 1.x migration: breaking-change review + canary/cutover plan

Issue #746 (pre-migration inventory), umbrella #745.
Target: unified 1.x train v1.7.0 (released 2026-10-27). Source of truth: v1.7.0 release
notes (fetched via gh api, 55 KB) + the v1.7.0 source clone at
`/Users/shrinedogg/.hermes/cache/scratch/inv/agentgateway-v170` + live cluster state
(read-only) + biggs.dog repo manifests.

Note on upgrade docs: the v1.7.0 clone has no docs/ directory and no upgrade or migration
document since 1.0 (checked: no files matching upgrade/migrate/breaking/changelog at repo
level). The release notes "Breaking changes" and "Other behavior changes" sections are the
authoritative change list. This is recorded as a finding, not a gap: the notes cover the
delta we need.

## 1. Current state (verified live, read-only)

- Legacy train: Flux HelmRelease `agentgateway` (ns networking) from
  `oci://ghcr.io/agentgateway/charts/agentgateway` tag v2.2.1.
  Controller `cr.agentgateway.dev/controller:v2.2.1` (1 replica), one data plane
  Deployment per Gateway on `cr.agentgateway.dev/agentgateway:0.12.0`
  (`wildcard-biggs-dog`, `internal-biggs-dog`), 1 replica each.
- CRDs: HelmRelease `agentgateway-crds` from
  `oci://ghcr.io/agentgateway/charts/agentgateway-crds` tag `0.0.0-alpha.a655af15`
  (1.x-era commit, 2026-06-26). Serves 3 CRDs (AgentgatewayBackend, AgentgatewayParameters,
  AgentgatewayPolicy), all agentgateway.dev/v1alpha1. No AgentgatewayModel CRD today.
- Gateways (ns networking, class `agentgateway`, controllerName `agentgateway.dev/agentgateway`):
  - `wildcard-biggs-dog`, VIP 192.168.6.7 (only UDM WAN-forwarded address): 4 listeners
    (*.biggs.dog + biggs.dog on 80/443), wildcard biggs-dog-tls cert. 18 routes attached
    to the wildcard listener (kagent, oauth2-proxy, pocket-id, biggs, kritika, livekit,
    continuwuity x2, sable, bookboss, silo, omni, dex, grafana, renovate, rook-ceph, zot).
  - `internal-biggs-dog`, VIP 192.168.6.15 (LAN/VPN only, not WAN-forwarded): wildcard
    80/443 + hostname-less HTTP listeners model-actors-minimax 8443, model-actors-glm 8444,
    model-actors-vllm 8445 (kagent substrate actors, Host rewritten to IP form). Routes:
    minimax, mistral, vllm, embeddings, mcp, model-actors x3, mindwtr.
- AgentgatewayBackends (ai-system): minimax (api.minimax.io:443, openai), glm
  (api.z.ai:443, openai, pathPrefix /api/coding/paas/v4), mistral (api.mistral.ai:443,
  openai), vllm (vllm.ai-system.svc.cluster.local:8000, openai, in-cluster, plaintext,
  kagent-vllm auth). All use `policies.auth.secretRef` + `policies.ai.routes` maps
  (Completions / Passthrough).
- AgentgatewayBackends (networking): cluster0-omni, cluster0-dex (spec.static
  192.168.2.31:443 + BackendTLSPolicy SNI omni/dex.biggs.dog).
- Policies: apiKeyAuthentication mode Strict (kagent-mcp-api-key, model-api-key,
  model-api-key-actors x3, kagent-ui forward auth, bookboss/mindwtr/rook-ceph forward auth
  via oauth2-proxy extAuth), one request-based rateLimit (120/min burst 40 on the minimax
  route), one headerModifiers (silo X-Forwarded-Proto set). No promptGuard of any kind,
  no webhook guardrails, no OIDC/token-exchange policies, no mirrors, no
  dynamicForwardProxy, no AgentgatewayModel. Verified by repo grep (zero promptGuard
  matches) and live `kubectl get agentgatewaypolicy -A`.
- MCP: mcp.biggs.dog HTTPRoute (internal gateway) is plain HTTP passthrough to
  kagent-controller:8083/mcp. Deliberately NOT appProtocol mcp (route comment: MCP mode
  re-mangles the path). So the gateway is a byte proxy for MCP; no native MCP targets,
  no MCP session handling today.
- Legacy data plane pods carry no SESSION_KEY env and no session-key Secret exists in ns
  networking (checked pod env + secret list). Legacy MCP sessions were unencrypted.
- Data plane metrics port 15020 (VMPodScrape `agentgateway-internal`); still the 1.7.0
  default (crates/agentgateway/src/config.rs:362).
- HelmRelease values (app/helmrelease.yaml): top-level podSecurityContext
  (seccompProfile RuntimeDefault), top-level securityContext (allowPrivilegeEscalation
  false, drop ALL capabilities, seccomp RuntimeDefault), controller.extraEnv
  KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES="true".
- No docker-registry pull secrets anywhere in Flux. Gateway objects have no finalizers.
  GatewayClass is not in the repo (created imperatively by the controller).

## 2. Breaking changes (v1.7.0 release notes) mapped to this cluster

Verdicts: AFFECTS-US / NOT-AFFECTED. Severity: none / low / med / high.

### 2.1 Standalone always encrypts MCP sessions
K8s behavior in 1.x: the controller deployer creates a per-Gateway Secret
`<gateway-name>-session-key` (32 random bytes hex, created once, never overwritten) and
injects it as the SESSION_KEY env on the data plane pod, so MCP session IDs are encrypted.
- Our MCP traffic (mcp.biggs.dog -> kagent-controller) is raw HTTP passthrough, not
  agentgateway native MCP, so session encryption does not apply to it.
- Legacy data plane had no SESSION_KEY (verified), so there is no key continuity question:
  nothing migrates.
- Verdict: NOT-AFFECTED (our traffic). Severity: none today.
- Required action: none. Awareness items: (a) new Secrets appear in ns networking at
  cutover (wildcard-biggs-dog-session-key, internal-biggs-dog-session-key); (b) if we ever
  adopt native MCP, sessions are encrypted by default, sessions established before an
  upgrade are rejected once (clients re-establish; undecodable session IDs return 404
  instead of 400 in 1.7.0, which helps clients recover), and `config.session.key: disabled`
  is the opt-out for standalone only.

### 2.2 Prompt guards inspect tool outputs by default
1.7.0: all prompt guards except webhooks honor scope; default scope now includes ToolOutput.
- Confirmed: there is no promptGuard configuration in this cluster. Repo grep across
  clusters/ returns zero matches; the live policy list contains only apiKeyAuthentication,
  extAuth, rateLimit, headerModifiers policies. No vendor guardrail (OpenAI Moderation,
  Model Armor, Azure Content Safety), no webhook guardrail, no regex guard.
- Verdict: NOT-AFFECTED. Severity: none.
- Required action: none. Future note: when a guardrail is added, set scope explicitly
  (SystemPrompt, Messages) to retain 1.6 behavior if tool output must not be sent to
  vendor guardrail APIs.

### 2.3 CEL header lookups return every value of a repeated header
- Only CEL in the whole config set is the mindwtr-forward-auth extAuth redirect
  (string concatenation on request.path). No `request.headers[...]` or
  `response.headers[...]` lookups anywhere (repo grep).
- Verdict: NOT-AFFECTED. Severity: none. Required action: none.

### 2.4 Dynamic backends cannot connect to loopback or link-local
1.7.0 code check: the denial (crates/agentgateway/src/client/mod.rs, check_not_loopback)
applies only when the backend is `Backend::Dynamic` (the dynamicForwardProxy kind) and
`config.backend.allowDynamicLoopback` is false. AI backends (`Backend::AI`) and static
host backends (`Backend::Opaque`) are not in the denied path. Even setting that aside,
none of our targets resolve to loopback (127.0.0.0/8, ::1), link-local (169.254.0.0/16,
fe80::/10), or unspecified (0.0.0.0, ::).
Per-backend classification:
- minimax (api.minimax.io:443): AI backend, public DNS to public IPs. NOT-AFFECTED.
- glm (api.z.ai:443): AI backend, public DNS. NOT-AFFECTED.
- mistral (api.mistral.ai:443): AI backend, public DNS. NOT-AFFECTED.
- vllm (vllm.ai-system.svc.cluster.local:8000): the one in-cluster backend. Resolves via
  cluster DNS to a ClusterIP in the 10.x pod network, not loopback or link-local.
  NOT-AFFECTED. Keep in mind for any future localhost-shaped target.
- cluster0-omni, cluster0-dex (192.168.2.31:443, spec.static): static -> Opaque backend,
  not subject to the check at all; 192.168.0.0/16 is private, not loopback/link-local.
  NOT-AFFECTED.
- All plain Service backends (zot, mindwtr-cloud/app, kagent-controller, oauth2-proxy,
  etc.): controller-resolved endpoint addresses, static. NOT-AFFECTED.
- No dynamicForwardProxy backends exist in the repo (verified).
- Verdict: NOT-AFFECTED for every backend. Severity: none.
- Required action: none. If a future backend must dial 127.0.0.1/169.254.x/fe80::, set
  config.backend.allowDynamicLoopback: true (data plane config key; not a Helm value in
  the 1.7.0 chart, reachable via AgentgatewayParameters/controller config).

### 2.5 Error responses no longer include internal details
- AFFECTS-US (observability only). Severity: low.
- Client-visible error bodies become generic ("connection refused" instead of
  "upstream tcp call failed: tcp connect to 10.12.4.7:5432 failed: Connection refused",
  "policy failed" instead of the CEL expression, etc.). Status codes unchanged; full error
  is still logged by the data plane.
- Our own comments reference legacy error strings (backend.yaml documents the old
  "backends required DNS resolution which failed" 503 text). Troubleshooting will need
  pod logs after cutover.
- Required action: none before cutover. Note for runbook: check data plane logs for
  upstream failures after migration.

### 2.6 Removed: AGENTGATEWAY_MESSAGES_PREFER_COMPLETIONS
- Env var is not set anywhere in our values (only the KGW_ flag exists). We do not use
  the Anthropic Messages API (all backends are OpenAI-compatible Completions/Passthrough).
- Verdict: NOT-AFFECTED. Severity: none.

### 2.7 Other behavior changes (release notes, item by item)
- Normalized service tier (llm.serviceTier standard/flex/priority/reserved): no
  serviceTier usage or CEL comparisons anywhere. NOT-AFFECTED, severity none.
- Request log database migration (standalone SQLite/Postgres backfill): standalone only;
  we are on the K8s xDS train. NOT-AFFECTED, severity none.
- Bedrock tool_choice now honored: no Bedrock backends. NOT-AFFECTED, severity none.
- Token rate limits now count Embeddings/Rerank/Decisions/SystemOne: our one rateLimit is
  request-based (120/min, burst 40), not token-based. NOT-AFFECTED, severity none.
  Future note: token-based limits would also count embeddings traffic (embeddings route).
- 32 MiB LLM request buffer applied before request policies: our requests are far below
  the limit; no route sets buffer policies. NOT-AFFECTED, severity low (info).
- Webhook guardrail pass responses with extra fields are now errors: no webhook
  guardrails. NOT-AFFECTED, severity none.
- Google Model Armor non-success is a guard failure: not used. NOT-AFFECTED, severity none.
- Backend mirrors run after backend policies: no mirrors configured. NOT-AFFECTED,
  severity none.
- AgentgatewayModel exact-name wildcard precedence: no AgentgatewayModel resources (CRD
  not even installed yet; v1.7.0 CRDs add it, unused). NOT-AFFECTED, severity none.
- MCP OpenAPI path override and non-JSON MCP response typing: no native MCP targets.
  NOT-AFFECTED, severity none.
- MCP session errors return 404 instead of 400: covered under 2.1 (native MCP only).
  NOT-AFFECTED, severity none.
- gRPC health: only server-side gRPC errors mark a backend unhealthy: no gRPC backends
  through the gateway (kagent MCP is HTTP). NOT-AFFECTED, severity none.
- gRPC policy calls failing before the service report UNAVAILABLE instead of UNKNOWN:
  no gRPC policy calls (extAuth is HTTP forward auth). NOT-AFFECTED, severity none.
- Invalid OAuth token exchange / CAA config no longer rejects the whole xDS update; the
  policy fails closed with Accepted=False: we run no agentgateway OIDC/token-exchange
  policies (forward auth to oauth2-proxy is a different mechanism). NOT-AFFECTED,
  severity none.
- Client anthropic-version header forwarded instead of replaced: no Anthropic clients.
  NOT-AFFECTED, severity none.

### 2.8 Changes beyond the release notes that matter for this migration (found in code/charts)
- Env var rename: KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES ->
  AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES. The 1.x controller does not read the
  KGW_ prefix (grep of the v1.7.0 tree: zero hits). The 1.x default for
  EnableExperimentalGatewayAPIFeatures is true (controller/api/settings/settings.go),
  which matches our current explicit true, so behavior is preserved by default.
  AFFECTS-US (config), severity low. Action: in the 1.x HelmRelease values, drop the KGW_
  var or rename it to AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES: "true" (explicit is
  better; experimental Gateway API features are what BackendTLSPolicy and friends ride on).
- GatewayClass name / controllerName: no change. 1.x defaults are class name
  "agentgateway" and controllerName "agentgateway.dev/agentgateway"
  (settings.go AgentgatewayClassName/ControllerName), identical to the legacy train and to
  the live GatewayClass. AFFECTS-US: none. Required action: none; verification: after
  cutover the GatewayClass stays Accepted=True and both Gateways report
  Programmed=True (read back, do not infer).
- xDS transport: legacy data plane env XDS_ADDRESS is http://agentgateway...:9978
  (plaintext). The 1.7.0 chart default is controller.xds.mode: tls; the 1.x controller
  generates its own xDS CA (well-known secret name kgateway-xds-cert, which will coexist
  with the legacy agentgateway-xds-cert / agentgateway-xds-ca-secret in ns networking)
  and the data plane chart mounts the CA. Transparent change; verify via Gateway
  Programmed status and controller logs.
- Data plane workloads: the 1.x deployer renders one Deployment+Service per Gateway named
  after the Gateway (same as today), so at cutover the existing wildcard-biggs-dog and
  internal-biggs-dog Deployments are adopted and rolled to
  cr.agentgateway.dev/agentgateway:1.7.0 in place. No orphaned resources. Rolling
  update with 1 replica: expect a seconds-long interruption per gateway; in-flight LLM
  streams are cut; kagent actors and MCP clients reconnect. Schedule the cutover in a
  low-activity window.
- Image registry: the 1.7.0 chart defaults image.registry to cr.agentgateway.dev for both
  the controller and the data plane (deployer default AGW_PROXY_IMAGE_REGISTRY is also
  cr.agentgateway.dev). The data plane pods are created by the deployer with no
  imagePullSecrets support in its internal chart; the only pod-level path is the
  imagePullSecrets on the ServiceAccount (one per gateway, same name as the gateway, in
  ns networking). See section 6 for the pull-verification gate.
- Chart values shape: the 1.7.0 chart keeps top-level podSecurityContext / securityContext
  and controller.extraEnv, so our hardening values port unchanged (except the env rename).
  New options we do not need: rbac.create=false, proxy.image overrides,
  gatewayClassName/controllerName (multi-controller, used by the canary),
  agentgatewayModels.enabled (default true), xBackend (default false).
- CRD compatibility (verified by diffing the pinned a655af15 CRDs against the v1.7.0 CRDs
  chart, pulled from ghcr): v1.7.0 adds the AgentgatewayModel CRD; on the three shared
  CRDs there are no newly required fields and no removed enum values on any path our
  manifests use (ai.routes values Completions/Passthrough still valid; new enum values
  Decisions/SystemOne/Detect added; AgentgatewayParameters gains optional daemonSet,
  spiffe, workload fields; several CEL validation rules were rewritten but
  semantically equivalent). The CRD bump is additive and safe to apply before the
  controller change, and safe to keep during any rollback of the controller.
- Metrics: data plane metrics port stays 15020; VMPodScrape needs no change.

## 3. Canary plan

Goal: prove the 1.7.0 data plane with real routes before any production listener moves.
Mechanism: run the 1.x controller in parallel under its own GatewayClass identity. This
is a supported pattern (the 1.7.0 chart ships gatewayClassName + controllerName values
documented for "running multiple agentgateway controllers"), and it is the only way a
canary data plane can exist before cutover, because the legacy controller v2.2.1 cannot
deploy the 1.7.0 data plane.

Commit A (canary + CRDs, one commit, revertable as a unit):

1. CRDs first: bump OCIRepository agentgateway-crds (flux-system) tag
   0.0.0-alpha.a655af15 -> v1.7.0. Verified additive; the legacy controller keeps
   running against it (same v1alpha1, superset schema).
2. New OCIRepository agentgateway-canary (flux-system):
   url oci://ghcr.io/agentgateway/charts/agentgateway, tag v1.7.0.
3. New HelmRelease agentgateway-canary (ns networking), chartRef agentgateway-canary,
   nameOverride: agentgateway-canary, values:
   - gatewayClassName: agentgateway-canary
   - controllerName: agentgateway.dev/agentgateway-canary
   - controller.extraEnv: AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES: "true"
   - the same podSecurityContext/securityContext hardening as the production HR.
   The controller creates GatewayClass agentgateway-canary (Accepted=True expected).
   Its own resources are named agentgateway-canary-* (no collision with the legacy
   agentgateway-* resources).
4. New Gateway agentgateway-canary (ns networking), gatewayClassName agentgateway-canary:
   single listener:
   - name: canary-https, port: 443, protocol: HTTPS, hostname: "*.biggs.dog",
     tls: Terminate, certificateRefs: [Secret biggs-dog-tls].
   The listener hostname must be the wildcard *.biggs.dog (not a literal
   canary.biggs.dog) because Gateway API only attaches a route when the route hostname
   matches the listener hostname, and the canary routes we attach keep their real
   hostnames (zot.biggs.dog, mindwtr.biggs.dog). The existing wildcard cert covers it.
   The controller creates a LoadBalancer Service named agentgateway-canary; UDM assigns a
   LAN IP (next free .6.x). No UDM WAN forward is added for that IP, so the canary is
   LAN/VPN-only by default, matching the internal-gateway pattern.
5. Temporarily attach 1-2 low-risk existing routes by adding a second parentRef
   (name: agentgateway-canary, namespace: networking) to:
   - zot (ns zot, zot.biggs.dog, public gateway today): no gateway-level auth, plain
     in-cluster Service backend, low traffic (registry API). Least-risk functional proof.
   - mindwtr (ns mindwtr, mindwtr.biggs.dog, internal gateway today): low traffic, and
     covers three auth shapes at once: /health (no auth), /v1 (bearer enforced by
     mindwtr-cloud itself, no gateway policy), pwa rule (extAuth forward auth to
     oauth2-proxy, which also exercises the 1.x extAuth path).
   Both routes remain served by their original gateway meanwhile, so there is zero
   production impact from the attachment itself.
   Not chosen: model-actor routes (8443/8444/8445, in-production kagent actors), minimax
   (paid upstream + rate limit), MCP (session state), cluster0-edge (second TLS hop).

Canary validation (all read-back, none inferred):

Status:
- kubectl get gateway agentgateway-canary -n networking -o yaml: listener canary-https
  Accepted=True, Programmed=True, ResolvedRefs=True, Conflicted=False,
  attachedRoutes=2.
- GatewayClass agentgateway-canary Accepted=True.
- Data plane pod agentgateway-canary-*: Running, image
  cr.agentgateway.dev/agentgateway:1.7.0, SESSION_KEY env present, no restarts.
- Controller pod agentgateway-canary-*: Ready; controller logs show no xDS errors, no
  translation errors for zot/mindwtr.
- New Secrets present: agentgateway-canary-session-key, kgateway-xds-cert (ns networking).
- Legacy gateways untouched: wildcard-biggs-dog and internal-biggs-dog still on
  0.12.0 data plane images, status unchanged.

Functional (from a LAN/VPN host, CANARY_IP = EXTERNAL-IP of the
agentgateway-canary Service; or in-cluster against its ClusterIP):
- curl -sS --resolve zot.biggs.dog:443:$CANARY_IP https://zot.biggs.dog/v2/ -> expect 200
  and an empty/JSON body from the registry API; verify the served cert is the
  biggs-dog-tls wildcard cert (openssl s_client -connect $CANARY_IP:443 -servername
  zot.biggs.dog | openssl x509 -noout -subject).
- curl -sS --resolve mindwtr.biggs.dog:443:$CANARY_IP https://mindwtr.biggs.dog/health
  -> expect the mindwtr-cloud health response (200).
- curl -sS --resolve mindwtr.biggs.dog:443:$CANARY_IP -H "Authorization: Bearer <real
  sync token>" https://mindwtr.biggs.dog/v1/data -o /dev/null -w "%{http_code}" ->
  expect the app's 2xx/4xx (never a gateway 401 or 503). Operator supplies the token;
  never print it.
- curl -sS -o /dev/null -w "%{http_code} %{redirect_url}" --resolve
  mindwtr.biggs.dog:443:$CANARY_IP https://mindwtr.biggs.dog/ -> expect 302 to
  https://auth.biggs.dog/oauth2/start (proves extAuth forward auth works on 1.7.0).
- curl -sS -o /dev/null -w "%{http_code}" --resolve nope.biggs.dog:443:$CANARY_IP
  https://nope.biggs.dog/ -> expect 404 (unknown host on the canary).

Issue #704 fail-closed proof (safe, canary-scoped, no production secret touched):
- Create a throwaway HTTPRoute canary-auth-test (hostname test.biggs.dog, PathPrefix /,
  backendRef any simple Service, parentRef agentgateway-canary) and an AgentgatewayPolicy
  canary-auth-test with traffic.apiKeyAuthentication mode Strict and secretRef to a
  non-existent Secret, in ns networking.
- curl --resolve test.biggs.dog:443:$CANARY_IP https://test.biggs.dog/ -> expect 401
  (fail closed). On the legacy train this exact setup is fail-open (issue #704); on 1.x
  controllers (agentgateway#1245, v1.0.1+) it must be 401. This is the direct
  verification we want before cutover.
- Delete both throwaway objects.

Retirement: the canary Gateway and the two extra parentRefs are removed in the cutover
commit (section 4, step 4d), i.e. after cutover and only after the full post-cutover
route verification sweep passes. The canary HelmRelease is NOT deleted then: it becomes
the permanent 1.x controller (optionally rebranded in a follow-up commit, section 4
step 6). The canary and the legacy CRD tag are retained until all verification gates
pass, per the standing convention.

## 4. Cutover sequence

Preflight gates (all must pass before commit B):
- P1. Image pull gate: the canary data plane pod already proves that
  cr.agentgateway.dev/agentgateway:1.7.0 can be pulled on at least one node. Data plane
  pods have no node affinity, so confirm the pull also works on every node that will run
  the production data plane pods (or check the nodes' registry credentials). If any node
  cannot pull, create a docker-registry pull secret in ns networking and wire it:
  imagePullSecrets value on the 1.x HelmRelease (controller pod) plus the secret attached
  to the ServiceAccounts agentgateway-canary (becomes agentgateway), wildcard-biggs-dog
  and internal-biggs-dog (data plane pods; the deployer has no per-pod imagePullSecrets
  value, the SA is the only hook). Same for the controller:1.7.0 image.
- P2. Canary validation section fully green, including the #704 401 proof.
- P3. Pick a low-activity window: cutover restarts both production data plane deployments
  (in-flight LLM streams cut, seconds each, actors/MCP clients auto-reconnect).

Commit A (already applied and validated during the canary phase):
CRDs source -> v1.7.0; canary source; canary HelmRelease; canary Gateway; zot + mindwtr
extra parentRefs.

Commit B (the cutover, one commit so it is a single git revert):
1. Edit clusters/cluster1/kubernetes/apps/networking/agentgateway/app/gateway.yaml and
   internal-gateway.yaml: gatewayClassName agentgateway -> agentgateway-canary.
   (The 1.x controller adopts both Gateways; the legacy controller stops managing them.
   No finalizers on the objects, verified; class flip is clean.)
2. Delete clusters/cluster1/kubernetes/apps/networking/agentgateway/app/helmrelease.yaml
   (legacy HelmRelease, controller v2.2.1). Keep the agentgateway-crds HelmRelease
   (now on v1.7.0) and keep the legacy OCIRepository agentgateway source object for now
   (it is inert; removed in cleanup after the verification gates pass).
3. Manual, same window: kubectl -n networking delete gatewayclass agentgateway (the
   legacy-created class; not in the repo, so it cannot be a git delete). This prevents the
   legacy controller from re-adopting anything during the rollout.
4. Delete the canary Gateway (app/gateway-canary.yaml) and revert the zot and mindwtr
   HTTPRoutes to their single original parentRef. All in commit B.
5. Wait for Flux reconciliation, then read back live state (never infer from YAML):
   - Both Gateways: all listeners Accepted=True, Programmed=True, ResolvedRefs=True,
     Conflicted=False; attachedRoutes counts match pre-cutover (wildcard listener 18,
     biggs-dog-https 2, internal wildcard 6, model-actors-* 7 each).
   - Data plane deployments: image cr.agentgateway.dev/agentgateway:1.7.0, 1/1 Available.
   - Controller: 1.x only (no agentgateway-<legacy-hash> pods left), Ready.
   - GatewayClass agentgateway-canary Accepted=True; no agentgateway class.
   - New session-key Secrets: wildcard-biggs-dog-session-key, internal-biggs-dog-session-key.
   - Full route sweep (functional curls, operator-supplied tokens, never printed):
     * public: zot /v2/, bookboss, grafana, omni + dex (cluster0-edge re-encryption with
       BackendTLSPolicy SNI), kagent UI (SSO redirect), livekit, matrix (sable,
       continuwuity + .well-known), silo (X-Forwarded-Proto set still applied), renovate,
       rook-ceph, biggs.dog apex.
     * LAN-only: minimax + mistral (model token, expect upstream behavior, e.g. 401 from
       the provider with a bad token and success with the good one), vllm (/v1/models
       with kagent-vllm key), embeddings (silo path), mcp (mcp.biggs.dog initialize +
       one tools/call with the Pocket-ID token), mindwtr /health + /v1 + PWA SSO redirect.
     * actors: model-actors-minimax/glm/vllm on 8443/8444/8445 with the shared model
       token (http://internal-biggs-dog.networking.svc.cluster.local:84xx/v1/models),
       Host-rewrite catch-all behavior intact.
     * auth negatives: bad model token -> 401 (not fail-open), no token -> 401; the #704
       fail-closed result from the canary carries over to the 1.x controller now in
       production.
     * errors: confirm the redacted error-body change (section 2.5) does not break any
       client we run (none parse upstream error text; verify kagent UI + silo behavior).
6. Optional follow-up (commit C, only after all gates are green for a soak period):
   rebrand the 1.x controller back to the original class name so the repo stays clean:
   set gatewayClassName: agentgateway and controllerName: agentgateway.dev/agentgateway
   in the (former canary) HelmRelease; the controller deletes the agentgateway-canary
   GatewayClass and creates agentgateway; then flip both Gateways' gatewayClassName back
   to agentgateway. Low risk (single controller, no parallel controllers left) but it is
   its own change. If skipped, the production class name stays agentgateway-canary
   forever, which is functional but ugly.

## 5. Rollback

Single revert: git revert <commit B> and push. Flux reconciles:
- The two Gateways revert to gatewayClassName agentgateway.
- The legacy HelmRelease (v2.2.1 controller) reappears; the legacy controller reconciles
  both Gateways and rolls the data plane Deployments back to
  cr.agentgateway.dev/agentgateway:0.12.0. That image is already on the nodes (58 days of
  cache, pullPolicy IfNotPresent), so no new pull is needed for the rollback itself.
- The canary Gateway and the extra route parentRefs are re-added (they are part of
  commit B's deletion), so the canary comes back too.
- CRDs stay at v1.7.0 (the CRD bump lives in commit A and is NOT reverted): verified
  safe for the legacy controller (same v1alpha1, superset schema) and for the 1.x
  controller.
- Legacy sources (OCIRepository agentgateway v2.2.1, legacy CRD tag 0.0.0-alpha.a655af15
  still present in the registry, verified via crane ls) remain in place for the duration,
  per the standing convention: legacy sources are retained until all verification gates
  pass. Do not delete the legacy OCIRepository during the soak window.
- Manual step on rollback: confirm the agentgateway GatewayClass exists (the legacy
  controller recreates it; if it does not within a couple of reconcile intervals, apply
  it by hand). The agentgateway-canary class and the 1.x controller keep running
  untouched.
- MCP/LLM state: sessions and in-flight requests do not survive a rollback any more than
  a cutover; clients reconnect. No data is stored by the gateway that needs restoring.
- If rollback is triggered by a bad image pull (P1 failure on production nodes), first
  add the pull secret (SA attachment + chart value) and re-attempt the forward path;
  rolling back to 0.12.0 avoids the pull only because that image is cached.

If commit A itself must be undone (canary phase, before cutover): git revert commit A.
This removes the canary source, canary HelmRelease, canary Gateway, the two parentRefs,
and the CRD tag bump together (back to 0.0.0-alpha.a655af15, which the legacy controller
already runs on). No production route is ever affected by commit A or its revert.

## 6. Flux source registry recommendation

Decision: use ghcr.io/agentgateway/charts for both OCIRepository sources (agentgateway
v1.7.0, agentgateway-crds v1.7.0). cr.agentgateway.dev is the official registry named in
the release notes, but for this cluster it is the worse choice.

Verified facts:
- cr.agentgateway.dev rejects anonymous access outright: GET /v2/ -> 401 UNAUTHORIZED
  and no anonymous token is issued (/token -> UNAUTHORIZED). Chart pulls from Flux would
  require registrySecrets on both OCIRepositories (a new Flux credential path we do not
  have today).
- ghcr.io/agentgateway/charts publishes the identical 1.x charts and is anonymously
  pullable: crane ls works unauthenticated, and helm pull of
  agentgateway:v1.7.0, agentgateway-crds:v1.7.0 and legacy agentgateway:v2.2.1 all
  succeeded without credentials. Tag v1.7.0 exists in both chart repos (crane ls).
- The legacy sources already point at ghcr.io/agentgateway/charts, so the cutover
  changes only the tag, not the registry or auth model.
- Rollback safety: the old tags (v2.2.1, 0.0.0-alpha.a655af15) are still published on
  ghcr (crane ls shows 344 alpha tags for the CRDs chart including the pinned one), so a
  single-commit revert of the cutover can re-fetch the legacy chart from the same
  registry.
- Chart content parity: the ghcr v1.7.0 charts are the released 1.7.0 charts
  (Chart.yaml version v1.7.0, appVersion v1.7.0; pulled and inspected).

The pull-secret requirement (call out): pulling the chart from ghcr.io does not remove
the need to pull pod images, because the 1.7.0 chart defaults image.registry to
cr.agentgateway.dev for the controller (controller:1.7.0) and the deployer defaults the
data plane to cr.agentgateway.dev/agentgateway:1.7.0, and the registry rejects anonymous
pulls (verified 401). Today the nodes run cr.agentgateway.dev images without any
pod-level imagePullSecrets, which means either node-level registry credentials exist or
the images are simply cached (pullPolicy IfNotPresent). The 1.7.0 tags force real pulls
on the nodes, so the preflight P1 gate (section 4) is mandatory: verify a fresh-tag pull
from a production node before cutover, and if it fails, create a docker-registry secret
in ns networking and wire it via imagePullSecrets on the HelmRelease (controller pod)
and via attachment to the data plane ServiceAccounts (agentgateway-canary/agentgateway,
wildcard-biggs-dog, internal-biggs-dog). The alternative (mirror the two images to a
registry the nodes can reach and set proxy.image.registry + controller.image.registry)
works but adds a mirror-maintenance step for no benefit. If org policy ever requires the
official registry for charts too, the cost is a Flux registrySecret for cr.agentgateway.dev
plus the image pull secrets above.

## 7. Open items / things to confirm at execution time

- P1 node pull verification (the only hard unknown; everything else is verified).
- UDM-assigned IP of the canary Service (read from EXTERNAL-IP after reconcile; not
  predictable from the repo).
- Whether the legacy controller auto-recreates the GatewayClass after a rollback (test
  during the cutover window, or apply it manually per the rollback note).
- Soak duration before deleting the legacy OCIRepository and before the optional commit C
  class rebrand (recommend at least one week covering a normal usage cycle: agent runs,
  MCP sessions, image pulls from zot, cluster0 SSO).
