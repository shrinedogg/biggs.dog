# agentgateway CRD diff: legacy pin 0.0.0-alpha.a655af15 vs v1.7.0

Pre-migration inventory for issue #746 (umbrella #745). Compares the CRD schemas shipped by the
`agentgateway-crds` chart at the legacy pin (commit a655af15, 2026-06-26) and at v1.7.0, cross-checks
against what is actually installed in cluster1, and assesses every biggs.dog manifest that uses these
CRDs.

Inputs:

- Legacy chart: `/Users/shrinedogg/.hermes/cache/scratch/inv/charts/legacy-crds/agentgateway-crds` (version `0.0.0-alpha.a655af15`)
- New chart: `/Users/shrinedogg/.hermes/cache/scratch/inv/charts/new-crds/agentgateway-crds` (version `v1.7.0`)
- Live CRDs: `kubectl get crd -o yaml` from cluster1 (read-only), snapshot under `live/`
- Manifests: `~/Code/biggs.dog/clusters/cluster1`
- Method: recursive walk of each CRD's `openAPIV3Schema` (v1alpha1), comparing every path's type, enum,
  default, min/max, pattern, required, list type, and CEL validations. Raw machine-readable diff in
  `crd_diff.json`; scripts in `scripts/`.

## 1. CRDs in each chart version

| CRD | Legacy chart 0.0.0-alpha.a655af15 | v1.7.0 chart | Installed in cluster1 |
|---|---|---|---|
| `agentgatewaybackends.agentgateway.dev` | yes | yes | yes |
| `agentgatewaypolicies.agentgateway.dev` | yes | yes | yes |
| `agentgatewayparameters.agentgateway.dev` | yes | yes | yes |
| `agentgatewaymodels.agentgateway.dev` | no | yes (new) | no |

All CRDs are Namespaced with a single version `v1alpha1` (served and storage) in both chart versions.
No version, scope, subresource, or printer-column changes. `agentgatewaymodels` is the only new CRD.

## 2. Per-CRD field-level diff (v1alpha1)

Raw change counts from the full schema walk:

| CRD | Added paths | Removed paths | Changed paths | Description-only changes |
|---|---|---|---|---|
| agentgatewaybackends | 859 | 254 | 275 | 363 |
| agentgatewaypolicies | 374 | 127 | 190 | 251 |
| agentgatewayparameters | 18 | 0 | 1 | 5 |

### 2.1 Fields used by biggs.dog (verified unchanged)

Every field path referenced by a biggs.dog manifest was checked against the diff index. None appears in
the added, removed, or changed sets. These are byte-identical between the two chart versions:

| CRD | Path (all subpaths verified) | biggs.dog usage |
|---|---|---|
| agentgatewaybackends | `spec.static.{host,port}` | cluster0-edge backends |
| agentgatewaybackends | `spec.ai.provider.{openai,host,port,pathPrefix}` | glm, minimax, mistral, vllm backends |
| agentgatewaybackends | `spec.policies.auth.secretRef.name` | glm, minimax, mistral, vllm backends |
| agentgatewaybackends | `spec.policies.tls.sni` | minimax backend |
| agentgatewaybackends | `spec.policies.ai.routes` (map, incl. `Completions` and `Passthrough` handlers) | all four AI backends |
| agentgatewaypolicies | `spec.targetRefs[].{group,kind,name,sectionName}` | all policies |
| agentgatewaypolicies | `spec.traffic.apiKeyAuthentication.{mode,secretRef.name,location}` | 6 policies |
| agentgatewaypolicies | `spec.traffic.rateLimit.local[].{requests,unit,burst}` | 5 policies |
| agentgatewaypolicies | `spec.traffic.extAuth.{backendRef,http.{path,allowedRequestHeaders,allowedResponseHeaders,redirect}}` | 4 forward-auth policies |
| agentgatewaypolicies | `spec.traffic.headerModifiers.request.set[].{name,value}` | silo X-Forwarded-Proto policy |
| agentgatewayparameters | (no fields used) | CRD installed, no manifest references it |

Verdict: **no field used by any biggs.dog manifest is added, removed, or changed.**

### 2.2 Removed fields

| CRD | Subtree (path prefix) | What was removed | Risk verdict |
|---|---|---|---|
| agentgatewaybackends | `spec.policies.ai.promptGuard.{request,response}[].googleModelArmor.policies.auth` (under both `spec.policies.ai` and `spec.ai.groups[].providers[].policies.ai`) | The whole legacy auth set: `aws`, `azure`, `key`, `location`, `passthrough`, `secretRef` (was required). Replaced by a single `gcp` field with CEL enforcing exactly-`gcp` | **Breaking** for any manifest configuring googleModelArmor guardrail auth with a non-GCP method. biggs.dog: **not used, no impact** |
| agentgatewaybackends | `spec.policies.ai.promptGuard.{request,response}[].bedrockGuardrails.policies.auth` | `azure`, `gcp`, `passthrough` (remaining: `aws`, `key`, `location`, `secretRef`) | **Breaking** for those auth kinds only. biggs.dog: not used, no impact |
| agentgatewaybackends | `spec.policies.ai.promptGuard.{request,response}[].openAIModeration.policies.auth` | `azure`, `gcp`, `passthrough` | **Breaking** for those auth kinds only. biggs.dog: not used, no impact |
| agentgatewaypolicies | `spec.backend.ai.promptGuard...` (127 paths) | Same guardrail auth restructure mirrored into the policy's `backend.ai` section. No removals anywhere under `spec.traffic` or `spec.frontend` | **Breaking** for `backend.ai.promptGuard` users only. biggs.dog policies use `spec.traffic` exclusively, **no impact** |

All 381 removed paths are inside prompt-guard auth blocks. There are no removals in any subtree that
biggs.dog touches (`spec.static`, `spec.ai.provider`, `spec.policies.{auth,tls,ai.routes}`,
`spec.traffic.*`).

### 2.3 Type, default, and constraint changes

| Change | Affected fields | Risk verdict |
|---|---|---|
| Explicit schema `default` values dropped (codegen change; runtime defaults remain in controller/data-plane code) | `spec.ai.provider.bedrock.region` ("us-east-1"), `spec.ai.provider.vertexai.region` ("global"), `spec.policies.ai.promptCaching.{cacheMessageOffset,cacheMessages,cacheSystem,cacheTools,minTokens}`, `promptGuard.regex.action` ("Mask"), `spec.backend.mcp.authentication.mode` ("Strict"), `mcp.authorization.action` ("Allow"), `spec.frontend.networkAuthorization.action` ("Allow"), `frontend.proxyProtocol.{mode,version}`, `frontend.accessLog.otlp.protocol` ("GRPC"), `frontend.tracing.protocol`, `extProc.processingOptions.*`, `health.eviction.duration` ("3s"), `spec.traffic.apiKeyAuthentication.mode` ("Strict"), `traffic.basicAuthentication.mode`, `traffic.jwtAuthentication.mode`, `traffic.retry.attempts` (default added: 1) | **Low.** Schema no longer advertises defaults; behavior for manifests that omit the fields is unchanged. biggs.dog sets `apiKeyAuthentication.mode: Strict` explicitly, so the dropped "Strict" default is irrelevant here |
| New duration format constraint: `pattern ^([0-9]{1,5}(h|m|s|ms)){1,4}$` + `maxLength 32` | `tcp.connectTimeout`, `tcp.keepalive.{time,interval}`, `http.requestTimeout`, `health.eviction.duration`, `frontend.tls.handshakeTimeout`, `frontend.http.{http1IdleTimeout,http2KeepaliveInterval,http2KeepaliveTimeout,maxConnectionDuration}`, `spec.traffic.timeouts.request`, jwks `cacheDuration` | **Low.** Only rejects already-malformed values. biggs.dog: no duration fields set |
| `tls.caCertificateRefs[].name`: default `""` dropped, `minLength 1`, `required: [name]`, plus new `key`/`kind` fields | all `*.policies.tls.caCertificateRefs` (backend and policy sides) | **Medium** for hypothetical users passing empty names; they would now fail admission. biggs.dog: not used |
| `jwksPath` maxLength 2000 to 1024 | `mcp.authentication.jwks.jwksPath`, `traffic.jwtAuthentication.providers[].jwks.remote.jwksPath` | **Low.** Only paths over 1024 chars affected. biggs.dog: not used |
| `transformations[].field`: `allOf` replaced by `minLength 1`; list now typed as map keyed on `field` | `spec.policies.ai.transformations`, `spec.backend.ai.transformations` | **Low.** Rejects empty field names only. biggs.dog: not used |
| `spec.traffic.rateLimit.local[].burst`: `minimum: 0` added | all local rate limits | **None.** Pure lower bound; biggs.dog uses `burst: 40` |
| `spec.traffic.retry.attempts`: minimum 1 to 0, default 1 | retry policy | **Low.** Not used by biggs.dog |
| Relaxed requirements (now optional, alternatives added) | `*.policies.tunnel` (required `backendRef` dropped, `mode`/`url` added), `mcp.authentication.jwks` (required dropped, `url` added), `spec.traffic.rateLimit.global` + `rateLimit.conditional[].policy.global` (required `backendRef` dropped, `url` added), `policies.auth.azure.managedIdentity` (required dropped) | **None.** Strictly more permissive |
| Enum extensions (values added, none removed) | `spec.policies.ai.routes` handlers (+`Decisions`, `GeminiCountTokens`, `GenerateContent`, `SystemOne`; `Completions` and `Passthrough` kept), `custom.formats[].type` (+`Decisions`), `mcp.authentication.provider` and `jwtAuthentication.mcp.provider` (+`Authentik`, `Descope`, `Entra`, ...), `promptGuard.regex.action` (+`Audit`) | **None.** Additive; the handlers biggs.dog uses are present in both versions |
| `spec.mcp.targets`: `maxItems` 32 to 128, `targets[].condition` added | MCP backends | **None.** More permissive |

### 2.4 Added fields (all optional, no removal of existing behavior)

| CRD | Subtree | Added leaf fields | Notes |
|---|---|---|---|
| agentgatewaybackends | `spec.ai` | 323 | Per-provider `auth` expansion (`credentials`, `crossAppAccess`, `jwtSign`, `oauthTokenExchange`), `aws.assumeRole.{externalId,sessionName,sessionNameExpression,tags}`, `azure.{scopes,workloadIdentity}`, `tls.certificateSource`, `tunnel.{mode,url}`, `ai.groups[].providers[]` +`copilot` provider, `bedrock.endpointPreference`, `promptGuard` request/response `scope`, `finalTransformations`, `policies.authorization` |
| agentgatewaybackends | `spec.mcp` | 218 | MCP server backend expansion: target static policies auth, guardrails `processors[].expression`/`remote.url`, session fields |
| agentgatewaybackends | `spec.policies` | 318 | Same expansion as the `spec.ai.groups` copy: auth, tls, tunnel, promptGuard, `extAuth.url` |
| agentgatewaypolicies | `spec.backend` | 318 | Mirror of the backends `spec.policies` expansion (backend-side policies) |
| agentgatewaypolicies | `spec.traffic` | 40 | New `delay` traffic policy, `apiKeyAuthentication.configMapSelector`, `extAuth.url` (direct URL ext-auth backend), `extProc.{failureMode,metadataContext,requestAttributes,responseAttributes,url}`, `rateLimit.*.url` + `local[].key`, `timeouts.responseIdle` |
| agentgatewaypolicies | `spec.frontend` | 14 | `accessLog.otlp.{attributes,filter,url}`, `http.maxConcurrentRequests`, `tcp.maxConnections`, `tracing.{parentNotSampled,url}` |
| agentgatewaypolicies | `spec.targetRefs[]` / `spec.targetSelectors[]` | 1 + 1 | `port` on targets (frontend policies can attach to a Gateway port) |
| agentgatewayparameters | `spec.daemonSet` | 7 | Overrides for the generated DaemonSet |
| agentgatewayparameters | `spec.spiffe` | 9 | SPIFFE integration: gateway sources TLS identity (X.509-SVID) and trust bundle from the local Workload API |
| agentgatewayparameters | `spec.workload` | 2 | Selects the data-plane workload kind (Deployment if unset) |

Verdict for all additions: **none.** Every added field is optional; no required-ness was imposed on
any existing field except `tls.caCertificateRefs[].name` (see 2.3).

### 2.5 CEL validation (x-kubernetes-validations) changes

| CRD | Change | Risk verdict |
|---|---|---|
| agentgatewaybackends | "exactly one of [ai static dynamicForwardProxy mcp aws a2a]" rewritten from `.filter().size()` to `(has(x)?1:0)+...==1`. Semantically identical | None |
| agentgatewaypolicies | Same rewrite for "exactly one of [targetRefs targetSelectors]". "frontend can only target a Gateway" rule drops `!has(sectionName)`; the listener prohibition moves to new rules scoped to `frontend.{tcp,networkAuthorization,tls,http,proxyProtocol,connect}` (other frontend sub-policies like `accessLog` may now target a listener) | **Low.** Strictly broader for biggs.dog (no frontend policies exist) |
| agentgatewaypolicies | New rules: `Service` `sectionName` must be a numeric port 1 to 65535; `backend.sessionAffinity` must target the whole AgentgatewayBackend, not a section; `port` on targets allowed only for frontend-only policies | **None.** biggs.dog targets HTTPRoutes only, never Services, and sets no `port` |

### 2.6 AgentgatewayParameters

Purely additive: `+daemonSet`, `+spiffe`, `+workload` (18 leaf fields), 0 removed, 1 changed node
(`spec` props + validations). No biggs.dog manifest uses this CRD (the only repo reference is a comment
in `backend-mistral.yaml`: "no AgentgatewayParameters"). It updates in place as part of the chart with no
manifest action.

## 3. New CRDs in v1.7.0

| CRD | Description |
|---|---|
| `agentgatewaymodels.agentgateway.dev` (Namespaced, v1alpha1) | Declares LLM models for the unified train: a concrete model (provider config for openai/bedrock/azure/vertexai/custom, `baseURL`, `match` conditions, `visibility`) or a virtual model doing request-time routing among concrete models (`failover`, `weighted`, `conditional`, `callout`), attached to Gateway, ListenerSet, or HTTPRoute parents via `parentRefs` |

No other new CRDs. The update is otherwise additive and backward-compatible (see 2.2 for the only
breaking subtree, which biggs.dog does not use).

## 4. Live-cluster cross-check (cluster1)

| Check | Result |
|---|---|
| Installed CRDs | `agentgatewaybackends`, `agentgatewayparameters`, `agentgatewaypolicies` (3 of 3; `agentgatewaymodels` not installed yet) |
| Served / storage version | `v1alpha1` on all three; `status.storedVersions: [v1alpha1]` |
| Spec vs legacy chart pin | **Identical.** Full spec-structure comparison (versions, schemas, subresources, conversion, printer columns) of each installed CRD against the 0.0.0-alpha.a655af15 chart template reports zero differences |
| Only textual difference | API server sets `spec.conversion.strategy: None` while the chart omits the field entirely. Expected API-server normalization, not drift |
| Install provenance | Annotations `meta.helm.sh/release-name: agentgateway-crds`, `meta.helm.sh/release-namespace: networking`, `controller-gen.kubebuilder.io/version: v0.20.0`. Consistent with the Flux HelmRelease in `clusters/cluster1/kubernetes/apps/networking/agentgateway/agentgateway-crds/helmrelease.yaml` consuming `oci://ghcr.io/agentgateway/charts/agentgateway-crds` tag `0.0.0-alpha.a655af15` (OCIRepository in `clusters/cluster1/flux-system/sources/agentgateway-crds-oci.yaml`) |

Drift note: **no drift.** The installed CRDs are exactly the legacy pin. The migration in #747 is a clean
in-place schema update of three CRDs plus creation of the fourth; no manual CRD repair is needed first.

## 5. Manifest verdicts (cluster1)

| Manifest | Kind(s) | Fields used | Verdict |
|---|---|---|---|
| `ai-system/agentgateway-ai/app/backend.yaml` (minimax) | AgentgatewayBackend | `spec.ai.provider.{openai,host,port}`, `policies.auth.secretRef`, `policies.tls.sni`, `policies.ai.routes` | Compatible as-is |
| `ai-system/agentgateway-ai/app/backend-glm.yaml` | AgentgatewayBackend | same + `provider.pathPrefix` | Compatible as-is |
| `ai-system/agentgateway-ai/app/backend-mistral.yaml` | AgentgatewayBackend | `spec.ai.provider.{openai,host,port}`, `policies.auth.secretRef`, `policies.tls`, `policies.ai.routes` | Compatible as-is |
| `ai-system/agentgateway-ai/app/backend-vllm.yaml` | AgentgatewayBackend | `spec.ai.provider.{openai,host,port}`, `policies.auth.secretRef`, `policies.ai.routes` | Compatible as-is |
| `ai-system/agentgateway-ai/app/route.yaml` | HTTPRoute (Gateway API) | references AgentgatewayBackend in `backendRefs` only | Compatible as-is (not an agentgateway CRD) |
| `ai-system/agentgateway-ai/app/route-actors-glm.yaml` | HTTPRoute | backendRef to AgentgatewayBackend/glm | Compatible as-is |
| `ai-system/agentgateway-ai/app/route-actors-minimax.yaml` | HTTPRoute | backendRef to AgentgatewayBackend/minimax | Compatible as-is |
| `ai-system/agentgateway-ai/app/route-actors-vllm.yaml` | HTTPRoute | backendRef to AgentgatewayBackend/vllm | Compatible as-is |
| `ai-system/agentgateway-ai/app/route-mistral.yaml` | HTTPRoute | backendRef to AgentgatewayBackend/mistral | Compatible as-is |
| `ai-system/agentgateway-ai/app/model-api-key-policy.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.apiKeyAuthentication.{mode,secretRef}`, `traffic.rateLimit.local` | Compatible as-is (mode set explicitly, unaffected by dropped schema default) |
| `ai-system/agentgateway-ai/app/model-api-key-actors-policy.yaml` | AgentgatewayPolicy | same | Compatible as-is |
| `ai-system/agentgateway-ai/app/model-api-key-actors-glm-policy.yaml` | AgentgatewayPolicy | same | Compatible as-is |
| `ai-system/agentgateway-ai/app/model-api-key-actors-vllm-policy.yaml` | AgentgatewayPolicy | same | Compatible as-is |
| `ai-system/agentgateway-ai/app/model-api-key-mistral-policy.yaml` | AgentgatewayPolicy | same | Compatible as-is |
| `ai-system/kagent/app/kagent-mcp-auth-policy.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.apiKeyAuthentication.{mode,secretRef}` | Compatible as-is |
| `ai-system/kagent/app/kagent-ui-auth-policy.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.extAuth.{backendRef,http.*}` | Compatible as-is (new `extAuth.url` is additive) |
| `rook-ceph/rook-ceph/cluster/rook-ceph-auth-policy.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.extAuth.{backendRef,http.*}` | Compatible as-is |
| `mindwtr/mindwtr/app/auth-policy.yaml` | AgentgatewayPolicy | `targetRefs` (with `sectionName: pwa`), `traffic.extAuth.{backendRef,http.*}` | Compatible as-is (target is an HTTPRoute, not a Service, so the new Service-sectionName rule does not apply) |
| `media/bookboss/app/bookboss-auth-policy.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.extAuth.{backendRef,http.*}` | Compatible as-is |
| `media/silo/app/silo-x-forwarded-proto.yaml` | AgentgatewayPolicy | `targetRefs`, `traffic.headerModifiers.request.set` | Compatible as-is |
| `networking/agentgateway/app/cluster0-edge.yaml` | 2x AgentgatewayBackend + BackendTLSPolicy (Gateway API) | `spec.static.{host,port}`; BackendTLSPolicy targets the backends | Compatible as-is |
| `auth/oauth2-proxy/app/reference-grant.yaml` | ReferenceGrant (Gateway API) | grants AgentgatewayPolicy cross-namespace refs to oauth2-proxy | Compatible as-is (group/kind unchanged) |
| (none) | AgentgatewayParameters | not referenced by any manifest | No action; CRD updates in place with the chart |

Notes:

- All 16 biggs.dog manifests that use the agentgateway CRDs directly (6 AgentgatewayBackends, 11
  AgentgatewayPolicies) are compatible as-is, as are the 5 HTTPRoutes and 1 ReferenceGrant that reference
  them. No manifest change is required for the CRD update in #747.
- Out of scope but adjacent: `clusters/cluster0/kubernetes/apps/omni/image-factory/app/ratelimit-policy.yaml`
  (cluster0) uses `traffic.rateLimit.local` with the same fields (requests/burst/unit Minutes). Those fields
  are unchanged in v1.7.0, so cluster0 would also be schema-compatible if/when it moves trains.
- The only schema-breaking change in the whole diff (googleModelArmor guardrail auth restructure, 2.2)
  affects zero biggs.dog resources.

## 6. Read-back and validation commands for issue #747

Run after the CRDs are updated (HelmRelease `agentgateway-crds` repointed to `v1.7.0`). All commands are
read-only; `--dry-run=server` validates against the new CRD schemas without mutating anything. No secrets
are printed.

```sh
export KUBECONFIG=~/.kube/biggs-dog-kubeconfig.yaml
cd ~/Code/biggs.dog

# 1. Flux converged on the new chart
flux get ocirepository agentgateway-crds -n flux-system
flux get helmrelease agentgateway-crds -n networking

# 2. All four CRDs present with v1alpha1 as storage version
kubectl get crd | grep '\.agentgateway\.dev$'
kubectl get crd agentgatewaybackends.agentgateway.dev agentgatewayparameters.agentgateway.dev \
  agentgatewaypolicies.agentgateway.dev agentgatewaymodels.agentgateway.dev \
  -o jsonpath='{range .items[*]}{.metadata.name}  storage={.spec.versions[?(@.storage==true)].name}  storedVersions={.status.storedVersions}{"\n"}{end}'

# 3. Spot-check that v1.7.0 schema content actually landed
kubectl get crd agentgatewaypolicies.agentgateway.dev \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.traffic.properties.delay.type}'; echo
kubectl get crd agentgatewaybackends.agentgateway.dev \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.policies.properties.ai.properties.routes.additionalProperties.enum}' | grep -o Decisions
kubectl get crd agentgatewayparameters.agentgateway.dev \
  -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.spiffe.type}'; echo

# 4. Read back existing CR instances (must survive the CRD update unchanged)
kubectl -n ai-system get agentgatewaybackends
kubectl -n ai-system get agentgatewaypolicies
kubectl -n networking get agentgatewaybackends
kubectl get agentgatewaypolicies -A
kubectl -n ai-system get agentgatewaybackend glm -o yaml

# 5. Server-side validation of every biggs.dog manifest against the new CRDs
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/ai-system/agentgateway-ai/app
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/ai-system/kagent/app/kagent-mcp-auth-policy.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/ai-system/kagent/app/kagent-ui-auth-policy.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/rook-ceph/rook-ceph/cluster/rook-ceph-auth-policy.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/mindwtr/mindwtr/app/auth-policy.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/media/bookboss/app/bookboss-auth-policy.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/media/silo/app/silo-x-forwarded-proto.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/networking/agentgateway/app/cluster0-edge.yaml
kubectl apply --dry-run=server -f clusters/cluster1/kubernetes/apps/auth/oauth2-proxy/app/reference-grant.yaml

# 6. Flux Kustomizations that deploy these CRs converge
for k in agentgateway-ai kagent mindwtr bookboss silo rook-ceph-operator; do
  flux get kustomization "$k" -n flux-system
done

# 7. Data plane health and model-route smoke tests (LAN-only endpoints)
kubectl -n networking get deploy agentgateway
kubectl -n networking logs deploy/agentgateway --tail=200 | grep -iE 'error|fail' || echo "no data-plane errors"
TOKEN=*** -n ai-system get secret model-api-keys -o jsonpath='{.data.apiKey}' | base64 -d)
curl -sS -o /dev/null -w 'minimax /v1/models -> %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://minimax.biggs.dog/v1/models
curl -sS -o /dev/null -w 'mistral /v1/models -> %{http_code}\n' \
  -H "Authorization: Bearer $TOKEN" https://mistral.biggs.dog/v1/models
```

Expected outcomes: step 2 lists four CRDs all with `v1alpha1` storage; step 3 prints `object`,
`Decisions`, `object`; step 5 succeeds with no validation errors; step 4 shows the same objects as
before the update; step 7 returns 200 for both model routes (the routes serve `/v1/models` via the
`Passthrough` handler).
