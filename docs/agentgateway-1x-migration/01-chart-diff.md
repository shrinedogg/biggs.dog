# agentgateway train migration: chart render diff (2.2.1 legacy train to 1.7.0)

Issue #746 (pre-migration inventory, part of umbrella #745).
Date: 2026-11-05.

Sources:
- Legacy chart: ghcr.io/agentgateway/charts/agentgateway v2.2.1 (local copy at `inv/charts/legacy-chart/agentgateway`).
- New chart: ghcr.io/agentgateway/charts/agentgateway v1.7.0 (local copy at `inv/charts/new-chart/agentgateway`, Chart.yaml dated 2026-10-27).
- Current values: `spec.values` of `clusters/cluster1/kubernetes/apps/networking/agentgateway/app/helmrelease.yaml` (verbatim copy in `inv/values/legacy-current.yaml`).
- Mapped values: `inv/values/cutover-1.7.0.yaml` (see section 2).
- Upstream source: github.com/agentgateway/agentgateway at tag v1.7.0 (settings, deployer, embedded data-plane chart).
- Live cluster1 cross-check: `kubectl get/describe` only (KUBECONFIG biggs-dog). Rendered legacy manifest was diffed against the live controller Deployment and is identical apart from API-server defaults (strategy, revisionHistoryLimit, probe defaults) and Flux-added labels. The values copy used for rendering is therefore faithful.

Both charts are control-plane (controller) charts. Neither chart renders any GatewayClass, Gateway, or data-plane workload. The data-plane Deployments (`internal-biggs-dog`, `wildcard-biggs-dog`) are created and reconciled at runtime by the controller that owns the GatewayClass (see section 4).

## 1. Values mapping table

| Legacy 2.2.1 value (current HelmRelease) | 1.7.0 equivalent | Decision / note |
| --- | --- | --- |
| `controller.extraEnv.KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES: "true"` | `controller.extraEnv.AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES: "true"` | The 1.7.0 controller only reads `AGW_*` env vars (envconfig prefix `AGW`); `KGW_*` is silently ignored. The 1.x equivalent defaults to `true` in the controller, so the mapping preserves behavior; set explicitly to keep the intent visible. |
| `podSecurityContext.seccompProfile.type: RuntimeDefault` | same key, same value | Top-level `podSecurityContext` exists unchanged in the 1.7.0 chart. |
| `securityContext` (allowPrivilegeEscalation false, drop ALL caps, seccomp RuntimeDefault) | same key, same value | Must stay explicit. If omitted, the 1.7.0 chart injects a stricter default (`runAsNonRoot: true`, `readOnlyRootFilesystem: true`, plus the same caps/seccomp) that the legacy release deliberately did not set (controller image UID/write paths unverified). |
| (unset) `controller.replicaCount` | default `1` | Matches current single replica. |
| (unset) `image.registry` / `image.tag` | default registry `cr.agentgateway.dev`, tag defaults to chart appVersion `v1.7.0` | 1.x chart normalizes semver tags with a `v` prefix; controller image becomes `cr.agentgateway.dev/controller:v1.7.0`. |
| (unset) `controller.xds.tls.enabled: false` (legacy default, behavior: plaintext xDS) | `controller.xds.mode: plaintext` | Behavior change to map: the 1.7.0 chart defaults to `xds.mode: tls` (renders `AGW_XDS_MODE=tls`), which would switch the xDS server to TLS-only. Set `plaintext` for parity with the current data-plane `XDS_ADDRESS=http://agentgateway.networking.svc.cluster.local:9978`. |
| (unset) `resources: {}` | chart default `resources.requests: {cpu: 100m, memory: 128Mi}` | New in the 1.7.0 chart (legacy default was empty). Affects scheduling only; limits remain unset, so the `GOMEMLIMIT`/`GOMAXPROCS` fieldRefs behave as today. |
| (not a value) GatewayClass name / controllerName | `gatewayClassName: agentgateway`, `controllerName: agentgateway.dev/agentgateway` (new 1.x values, rendered as `AGW_AGENTGATEWAY_CLASS_NAME` / `AGW_CONTROLLER_NAME`) | Pinned explicitly to the exact values of the existing live GatewayClass so the new controller adopts it. Equal to the 1.x built-in defaults; pinning is defense in depth (see section 4). |

Values with no legacy counterpart that stay at 1.7.0 defaults (intentionally not set): `rbac.create` (true), `rbac.gatewayNamespaces` (empty = cluster-wide deployer writes, as today), `istio.*` (RBAC discovery on, mesh integration off), `monitoring.*` (disabled; requires Prometheus Operator), `inferenceExtension.enabled` (false, as legacy), `xBackend.enabled` (false), `agentgatewayModels.enabled` (true, new AgentgatewayModel API; see risks), HPA/VPA (empty), `podLabels`, `commonLabels`, `topologySpreadConstraints`, `dnsConfig`, `controller.extraContainers/InitContainers/Volumes`.

## 2. Paste-ready cutover values for the 1.7.0 HelmRelease

Replace the entire `spec.values` block in `helmrelease.yaml` with:

```yaml
  values:
    # Cutover values: agentgateway 2.2.1 (legacy train) -> 1.7.0 chart.
    #
    # controller.xds.mode: the 1.7.0 chart defaults to "tls"
    # (AGW_XDS_MODE=tls, TLS-only xDS). The legacy 2.2.1 controller served
    # plaintext xDS. Set "plaintext" for behavior parity at cutover.
    # Revisit TLS xDS as a follow-up change.
    controller:
      xds:
        mode: plaintext
      extraEnv:
        # Legacy KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES="true" is a no-op
        # on 1.x (controller reads AGW_* only). The 1.x equivalent defaults to
        # true; set explicitly to preserve intent.
        AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES: "true"
    # Same keys and values as the legacy HelmRelease. Kept explicit because
    # omitting securityContext would make the 1.7.0 chart inject a stricter
    # default (runAsNonRoot, readOnlyRootFilesystem, drop ALL,
    # allowPrivilegeEscalation false) that the legacy release deliberately
    # did not set.
    podSecurityContext:
      seccompProfile:
        type: RuntimeDefault
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop:
          - ALL
      seccompProfile:
        type: RuntimeDefault
    # Data-plane ownership: the 1.x controller creates and manages a
    # GatewayClass named "agentgateway" with controllerName
    # "agentgateway.dev/agentgateway". Identical to the existing live
    # GatewayClass, so the new controller adopts it and takes over the
    # existing data-plane deployments. Values equal the chart defaults.
    gatewayClassName: agentgateway
    controllerName: agentgateway.dev/agentgateway
```

Companion Flux source changes (verified anonymously pullable from GHCR, no registry credentials needed):
- `agentgateway` OCIRepository: tag `v2.2.1` -> `v1.7.0` (same URL `oci://ghcr.io/agentgateway/charts/agentgateway`).
- `agentgateway-crds` OCIRepository: tag `0.0.0-alpha.a655af15` -> `v1.7.0` (same URL). The v1.7.0 CRD chart ships 4 CRDs vs 3 in the legacy chart: it adds `agentgatewaymodels.agentgateway.dev` (required because `AGW_ENABLE_AGENTGATEWAY_MODELS` defaults to true) and updates the schemas of `agentgatewaybackends`, `agentgatewayparameters`, `agentgatewaypolicies`. Apply the CRDs before the controller cutover.
- Do not switch the chart source to `cr.agentgateway.dev`: that registry 401s anonymous (checked 2026-11-05), GHCR does not. Container images (controller and data plane) remain on `cr.agentgateway.dev`; cluster1 already pulls those images today without imagePullSecrets, so node-level registry credentials are assumed (see risks).

## 3. Rendered manifest diff

Rendered with `helm template agentgateway <chart> -n networking -f <values>` (release name and namespace as in the live HelmRelease). Rendered outputs: `inv/rendered/legacy-2.2.1.yaml`, `inv/rendered/new-1.7.0.yaml`; machine diff: `inv/diff_rendered.py`.

### 3.1 Per-resource summary

| Resource | Legacy 2.2.1 render | 1.7.0 render | Change |
| --- | --- | --- | --- |
| ServiceAccount `agentgateway` | present | present | Labels only (chart/app version). |
| ClusterRoleBinding `agentgateway-role-networking` | present | present | Identical. |
| ClusterRole `agentgateway-networking` | present, read+write mixed | present, reads only | Restructured (details below). |
| ClusterRole `agentgateway-networking-deployer` | absent | present | NEW. Carries the deployer write verbs (configmaps, secrets, serviceaccounts, services, daemonsets, deployments, HPAs, PDBs: create/delete/patch/update; events create/patch). |
| ClusterRoleBinding `agentgateway-write-role-networking` | absent | present | NEW. Binds the SA to the deployer ClusterRole (cluster-wide, since `rbac.gatewayNamespaces` is empty; matches current effective write scope). |
| Role `agentgateway-networking-local` | absent | present | NEW. Namespaced writes: coordination leases (leader election), secrets create (xDS TLS cert secret), JWKS cache. |
| RoleBinding `agentgateway-local-role-networking` | absent | present | NEW. Binds SA to the local Role. |
| Deployment `agentgateway` | present | present | Image and env changed (details below); ports, probes, securityContext, SA, strategy unchanged. |
| Service `agentgateway` | ports `grpc-xds-agw` 9978, `health` 9093 | same, plus `metrics` 9092 | Metrics port added to the Service. |
| HPA / VPA / PodDisruptionBudget / monitoring resources | none (no templates in legacy chart) | templates exist but render nothing at defaults | No new objects at cutover values. |

### 3.2 ClusterRole `agentgateway-networking` rule-level changes

| Area | Legacy 2.2.1 | 1.7.0 |
| --- | --- | --- |
| Core reads (namespaces, nodes, pods, services, configmaps, secrets, endpointslices) | split across rules, included `endpoints` | consolidated read-only rule; `endpoints` gone, `pods`/`services`/`configmaps`/`secrets` readable |
| `agentgateway.dev` resources | backends, parameters, policies (+ status) | backends, models, parameters, policies (+ status). `agentgatewaymodels` added. |
| Gateway API watch | gateways, grpcroutes, httproutes, tcproutes, tlsroutes, backendtlspolicies, referencegrants | same plus `listenersets` (standard GA resource) |
| `gateway.networking.x-k8s.io/xlistenersets` | watched (incl. status write) | removed |
| `certificates.k8s.io/clustertrustbundles` | absent | watched (new) |
| Istio | destinationrules, serviceentries, workloadentries + `security.istio.io` authorizationpolicies | serviceentries, workloadentries only (gated on `istio.enabled`, default true) |
| Write verbs on configmaps/secrets/serviceaccounts/services/deployments/HPAs/PDBs/events | in this ClusterRole | moved to `agentgateway-networking-deployer` |
| `apps/daemonsets` | absent | watched (1.x supports DaemonSet workloads) |
| status writes, tokenreviews create, gatewayclasses create/get/list/patch/update/watch | present | present (unchanged) |

### 3.3 Deployment `agentgateway` (controller) detail

| Field | Legacy 2.2.1 render | 1.7.0 render |
| --- | --- | --- |
| image | `cr.agentgateway.dev/controller:v2.2.1` | `cr.agentgateway.dev/controller:v1.7.0` |
| imagePullPolicy | IfNotPresent | IfNotPresent |
| container env (name = value) | `GOMEMLIMIT` (fieldRef limits.memory), `GOMAXPROCS` (fieldRef limits.cpu), `KGW_LOG_LEVEL=info`, `KGW_XDS_SERVICE_NAME=agentgateway`, `KGW_AGENTGATEWAY_XDS_SERVICE_PORT=9978`, `KGW_DEFAULT_IMAGE_REGISTRY=cr.agentgateway.dev`, `KGW_DEFAULT_IMAGE_TAG=v2.2.1`, `KGW_DEFAULT_IMAGE_PULL_POLICY=IfNotPresent`, `KGW_DISCOVERY_NAMESPACE_SELECTORS=[]`, `KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES=true`, `KGW_ENABLE_AGENTGATEWAY=true`, `KGW_ENABLE_ENVOY=false`, `KGW_GATEWAY_CLASS_PARAMETERS_REFS={}`, `POD_NAMESPACE` (fieldRef) | `GOMEMLIMIT`, `GOMAXPROCS` (same fieldRefs), `AGW_PROXY_IMAGE_REGISTRY=cr.agentgateway.dev`, `AGW_PROXY_IMAGE_REPOSITORY=agentgateway`, `AGW_LOG_LEVEL=info`, `AGW_XDS_SERVICE_NAME=agentgateway`, `AGW_AGENTGATEWAY_XDS_SERVICE_PORT=9978`, `AGW_DISCOVERY_NAMESPACE_SELECTORS=[]`, `AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES=true` (from cutover values), `AGW_ENABLE_AGENTGATEWAY_MODELS=true`, `AGW_XDS_MODE=plaintext` (from cutover values), `AGW_AGENTGATEWAY_CLASS_NAME=agentgateway`, `AGW_CONTROLLER_NAME=agentgateway.dev/agentgateway`, `AGW_GATEWAY_CLASS_PARAMETERS_REFS={}`, `POD_NAMESPACE` (fieldRef) |
| env semantics lost | `KGW_ENABLE_AGENTGATEWAY=true` / `KGW_ENABLE_ENVOY=false` | gone: 1.x has a single (agentgateway) data-plane mode, no env toggle. `KGW_DEFAULT_IMAGE_TAG/PULL_POLICY` gone: the 1.x controller derives the proxy image from `AGW_PROXY_IMAGE_REGISTRY/REPOSITORY` + its built-in tag. |
| env semantics gained | absent | `AGW_ENABLE_AGENTGATEWAY_MODELS=true` (new AgentgatewayModel API on by default), proxy image registry/repository envs. |
| resources | `{}` | requests `cpu: 100m`, `memory: 128Mi` (new chart default; no limits) |
| ports | 9978 grpc-xds-agw, 9093 health, 9092 metrics | same |
| probes | readiness+startup on 9093 `/readyz` | same |
| container securityContext | APE false, drop ALL, seccomp RuntimeDefault | same (explicit cutover values) |
| pod securityContext | seccomp RuntimeDefault | same |
| serviceAccountName | `agentgateway` | `agentgateway` |
| strategy/replicas/revisionHistoryLimit | K8s defaults, 1 replica | same |

Verification: the legacy render matches the live `networking/agentgateway` Deployment exactly except for API-server-injected defaults (strategy, revisionHistoryLimit, probe field defaults, fieldRef `apiVersion`) and Flux-managed labels. No hand-edits have drifted the release.

## 4. GatewayClass name and controller ownership (data-plane pod ownership)

Neither chart renders a GatewayClass; the controller creates and reconciles it at runtime.

| | Legacy 2.2.1 controller | 1.7.0 controller |
| --- | --- | --- |
| GatewayClass name managed | `agentgateway` | `agentgateway` (settings default `AgentgatewayClassName`, env `AGW_AGENTGATEWAY_CLASS_NAME`) |
| `spec.controllerName` written | `agentgateway.dev/agentgateway` (verified on the live GatewayClass) | `agentgateway.dev/agentgateway` (settings default `ControllerName`, env `AGW_CONTROLLER_NAME`, `wellknown.DefaultAgwControllerName`) |

Live state (verified 2026-11-05): GatewayClass `agentgateway` with `controllerName: agentgateway.dev/agentgateway`, accepted condition from the kgateway controller. Both Gateways (`internal-biggs-dog`, `wildcard-biggs-dog`, namespace `networking`) reference class `agentgateway`; their data-plane Deployments are owned by the Gateway objects.

Consequence: the 1.7.0 controller adopts the existing GatewayClass as-is (name and controllerName are identical, and the cutover values pin both explicitly). It takes over reconciliation of both Gateways and their data-plane Deployments. No Gateway API object changes are needed for cutover. Because the controllerName does not change, the old 2.2.1 Deployment must not run alongside the new one (two controllers reconciling one GatewayClass); the HelmRelease upgrade replaces the Deployment in place with a rolling update, so the overlap is the brief old-pod/new-pod coexistence window (see risks).

## 5. Data-plane deployment: does the 1.x train change how `internal-biggs-dog-*` / `wildcard-biggs-dog-*` pods are deployed?

The chart itself never deploys data-plane pods. The controller's built-in deployer (1.7.0: `controller/pkg/deployer` + embedded chart `controller/pkg/helm/agentgateway`) renders them. Comparison of the live 2.2.1-rendered Deployments against the 1.7.0 deployer output (base and TLS cases in `controller/test/deployer/testdata`):

| Aspect | Live today (2.2.1 deployer) | 1.7.0 deployer | Change? |
| --- | --- | --- | --- |
| image | `cr.agentgateway.dev/agentgateway:0.12.0` | `cr.agentgateway.dev/agentgateway:v1.7.0` (controller built-in default tag, `v`-normalized; overridable via `proxy.image.*` values -> `AGW_PROXY_IMAGE_TAG`) | Yes: big jump 0.12.0 to 1.7.0. |
| args | `-f /config/config.yaml` | same | No |
| env | `XDS_ADDRESS=http://agentgateway.networking.svc.cluster.local:9978`, `NODE_NAME` from `metadata.name` (wrong field, yields pod name), `GATEWAY`, `NAMESPACE`, `INSTANCE_IP`, `SERVICE_ACCOUNT`, `CPU_LIMIT`, `RUST_LOG=info`, `RUST_BACKTRACE=1`, termination deadlines | same set, plus `SESSION_KEY` (secretKeyRef to controller-managed Secret `<gateway>-session-key`); `NODE_NAME` fixed to `spec.nodeName`; `XDS_ADDRESS` same host/port while `xds.mode: plaintext` | Yes: session key added, NODE_NAME bug fixed. |
| xds-token audience (projected SA token) | `kgateway` | `agentgateway` | Yes (self-consistent within the 1.x train; the 1.x control plane validates its own audience). |
| ports | 15020 metrics exposed; probes on 15021 `/healthz/ready` | same | No |
| volumes | `config-volume` (ConfigMap `<gateway>`), `tmp` emptyDir, `xds-token` projected | same, plus `/etc/xds-tls` CA volume only in TLS xDS mode (not with cutover values) | No at plaintext |
| resources | `{}` (no requests) | default requests `cpu: 100m`, `memory: 128Mi` | Yes: data-plane pods get resource requests. |
| container securityContext | runAsUser 10101, runAsNonRoot, readOnlyRootFilesystem, drop ALL, APE false | same defaults | No |
| pod securityContext | sysctl `net.ipv4.ip_unprivileged_port_start=0` | same (still required: listeners on 80/443 as non-root) | No |
| ServiceAccount automount | false | false (explicit in 1.x deployer) | No |
| labels | `app.kubernetes.io/managed-by: kgateway`, `kgateway: kube-gateway`, version `v2.2.1` | `app.kubernetes.io/managed-by: agentgateway`, no `kgateway` label, version `v1.7.0` | Yes (label/selector-compatible: selectors unchanged, so in-place pod replacement works). |
| annotations | `checksum/config`, prometheus scrape 15020 | same plus `checksum/session-key` | Yes (session key). |
| replicas | Gateway `spec.replicas` (unset today, effectively 1 each) | same mechanism (deployer honors Gateway `spec.replicas`) | No |
| ownerReference | Gateway object | same | No |
| new per-gateway objects | none | Secret `<gateway>-session-key` (controller-managed) | Yes. |
| no-listener behavior | n/a | new `NoListenersDummyPort` 443 keeps a Service port when a Gateway has zero listeners | n/a here (both Gateways have listeners). |

Because the rendered pod template differs (session key env, checksum annotation, labels, requests), the 1.7.0 controller will roll both data-plane Deployments once after takeover. At the default RollingUpdate 25%/25% with 1 replica each, maxUnavailable floors to 0 and maxSurge to 1: the replacement pod is created first and the old pod keeps serving until the new one passes /healthz/ready, so the expected failure mode is a stuck rollout (image pull failure, missing session-key Secret), not a brief availability gap.

## 6. Risks

1. xDS mode default flip (mitigated in cutover values). The 1.7.0 chart defaults `controller.xds.mode` to `tls`; the cutover values set `plaintext`. If that line is dropped during review, the control plane serves TLS-only xDS and the data plane is redeployed with `https://` XDS plus a CA mount. It would still work (the controller generates `kgateway-xds-cert`), but it is a silent behavior change. Keep the line; treat TLS xDS as a deliberate follow-up.
2. The parser bug is NOT fixed in 1.7.0. The 503 on non-streaming LLM responses with array content (known 0.12.0 bug) was fixed upstream in PR #3729 merged 2026-11-03, which postdates the v1.7.0 tag (2026-10-27). The first 1.x release containing the fix is the one after v1.7.0. Cutover to 1.7.0 therefore does not resolve that bug; verify after cutover and plan a bump to the next 1.x release for the fix. (Benefit: #704, API-key auth failing open on missing Secrets, is fixed by 1.x controllers.)
3. `KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES` silently becomes a no-op if the legacy values are carried over verbatim. No break (1.x default is also true), but the cutover values translate it to `AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES` explicitly.
4. Data-plane rollout on takeover. The 1.x deployer renders a different pod template, so both data-plane Deployments roll once (1 replica each, default RollingUpdate 25%/25%, which at 1 replica rounds to maxUnavailable 0 / maxSurge 1: the replacement pod is created first and the old pod keeps serving until the new one passes /healthz/ready). `wildcard-biggs-dog` fronts `biggs.dog` and `*.biggs.dog`; the expected failure mode is a stuck rollout (replacement pod ImagePullBackOff on cr.agentgateway.dev, or a missing `<gateway>-session-key` Secret) with the old pods still serving, not a brief per-gateway gap. Watch `kubectl -n networking rollout status deploy/internal-biggs-dog deploy/wildcard-biggs-dog` and the pod events for a stuck rollout; do not read a quiet window as health. No extra mitigation available with read-only access (no pre-scale of data plane).
5. Two-controller overlap during the controller rolling update. Both the 2.2.1 and 1.7.0 controllers reconcile controllerName `agentgateway.dev/agentgateway`. During the HelmRelease rolling update, old and new controller pods coexist until the old pod terminates; if both win/hold leader election in that window, GatewayClass/data-plane reconciliation could flap. Window is bounded (new pod ready once `/readyz` passes; startup probe max 120s). Watch controller and data-plane events through the rollout.
6. cr.agentgateway.dev registry auth for images. Charts stay on GHCR (anonymous pull verified for both v1.7.0 tags). Images remain on cr.agentgateway.dev, which 401s anonymous; cluster1 pulls today's images without imagePullSecrets, so node-level credentials exist. If those credentials are rotated or expire between now and cutover, both the controller and data-plane pulls fail. Verify an image pull (e.g. `crictl pull cr.agentgateway.dev/agentgateway:v1.7.0` on a worker) right before cutover.
7. CRD schema changes. The v1.7.0 CRD chart updates three existing CRDs and adds `agentgatewaymodels`. Validate that existing `AgentgatewayBackend`/`AgentgatewayParameters`/`AgentgatewayPolicy` objects (check what biggs.dog defines under the agentgateway.dev API) still validate against the new schemas before applying; apply CRDs before the controller cutover because the controller watches `agentgatewaymodels` and has that API enabled by default.
8. `agentgatewayModels.enabled` defaults to true. New API surface (CRD, RBAC, env `AGW_ENABLE_AGENTGATEWAY_MODELS=true`). Low risk, but if the API is unwanted it can be set to false in the cutover values (the CRD is still installed by the CRD chart).
9. Data-plane resource requests added (100m/128Mi per data-plane pod). Scheduling-only impact; negligible on cluster1 but changes pod QoS (Burstable instead of BestEffort) and eviction scoring.
10. `NODE_NAME` data-plane env changes from pod name to node name (fieldRef fix). Any consumer that relied on the old (buggy) value would see node names after cutover; no known consumers in biggs.dog manifests.
11. Controller gets resource requests (100m/128Mi) from the new chart default. Scheduling-only; acceptable.
12. Service exposes the metrics port 9092 now. Harmless; no NetworkPolicy changes required (cluster has none for this Service today).

## 7. Cutover sequence implied by this diff (for the follow-up issue)

1. Bump `agentgateway-crds` OCIRepository tag to `v1.7.0`; confirm the 4 CRDs are present and existing agentgateway.dev objects still validate.
2. Verify a node can pull `cr.agentgateway.dev/controller:v1.7.0` and `cr.agentgateway.dev/agentgateway:v1.7.0`.
3. Bump `agentgateway` OCIRepository tag to `v1.7.0` and replace the HelmRelease `spec.values` with section 2.
4. Watch: controller Deployment rollout, GatewayClass conditions (new controller takes over), both data-plane Deployments rolling once, `internal-biggs-dog`/`wildcard-biggs-dog` PROGRAMMED staying true, and the non-streaming LLM response behavior (parser bug expected to persist until the next 1.x release).

## Appendix: artifact locations

- `inv/values/legacy-current.yaml` - verbatim copy of the live HelmRelease `spec.values`.
- `inv/values/cutover-1.7.0.yaml` - mapped 1.7.0 values (same as section 2, with comments).
- `inv/rendered/legacy-2.2.1.yaml`, `inv/rendered/new-1.7.0.yaml` - full `helm template` outputs.
- `inv/rendered/live-controller-deploy.yaml` - live controller Deployment (read-only capture).
- `inv/diff_rendered.py` - structured render-vs-render diff script.
- `inv/compare_live.py` - rendered-vs-live verification script (result: only API-server defaults and Flux labels differ).
- `inv/crds-legacy/agentgateway-crds/` - extracted legacy CRD chart (3 CRDs) for comparison.
