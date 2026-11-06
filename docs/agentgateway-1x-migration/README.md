# agentgateway 1.x train migration: pre-migration inventory

Issue: #746 (pre-migration inventory), umbrella #745.
Date: 2026-11-05. Method: read-only live-cluster read-backs, chart renders
(legacy v2.2.1 with the current HelmRelease values, 1.7.0 with mapped values),
CRD chart diff, v1.7.0 source inspection (cloned at tag), and repo manifest
review. No cluster state was changed during this work.

## Files

| File | Contents |
|---|---|
| [01-chart-diff.md](01-chart-diff.md) | Values-mapping table, paste-ready cutover values, rendered-manifest diff, 12 risks, data-plane ownership answer |
| [02-crd-diff.md](02-crd-diff.md) | CRD inventory (3 -> 4), field-level diff, live-cluster drift check, per-manifest verdicts, read-back commands for #747 |
| [03-live-inventory.md](03-live-inventory.md) | Everything the cutover must preserve: Gateways/listeners, 28 HTTPRoutes, 11 policies, 6 backends, CNPs, ModelConfigs, observability, Flux state, 20-item preservation checklist |
| [04-breaking-changes-and-cutover-plan.md](04-breaking-changes-and-cutover-plan.md) | v1.7.0 release-note changes mapped to this cluster (verdicts), canary plan, cutover sequence, rollback, registry recommendation |
| [values-cutover-1.7.0.yaml](values-cutover-1.7.0.yaml) | Final-state values for the 1.7.0 HelmRelease (what #748 will paste) |
| [values-legacy-current.yaml](values-legacy-current.yaml) | Verbatim copy of the live v2.2.1 HelmRelease values |

Note: the cutover values pin `gatewayClassName: agentgateway` /
`controllerName: agentgateway.dev/agentgateway` for the final 1.x HelmRelease.
During the canary phase (04, section 3) the canary HelmRelease instead runs
under `agentgateway-canary` so both controllers can coexist; the class rebrand
back to the original names is the optional commit C.

## Headline findings

1. The cutover is controller-led. Neither chart renders a GatewayClass or any
   data-plane workload; the controller owns both data-plane Deployments at
   runtime. Both trains use the same class name (`agentgateway`) and
   controllerName (`agentgateway.dev/agentgateway`), so the 1.7.0 controller
   adopts the existing Gateways and rolls both data planes once (1 replica
   each, seconds per gateway, in-flight LLM streams cut).
2. No biggs.dog manifest needs changes. Every CRD field the repo uses is
   unchanged in v1.7.0; the only schema-breaking change anywhere (promptGuard
   googleModelArmor auth restructure) is unused here. The CRD bump is additive
   (adds the `agentgatewaymodels` CRD) and safe before the controller change.
3. The v1.7.0 chart defaults that must be overridden for parity:
   `controller.xds.mode: tls` -> set `plaintext`; `securityContext` omission
   -> keep the explicit legacy hardening; `KGW_ENABLE_GATEWAY_API_EXPERIMENTAL_FEATURES`
   is a silent no-op on 1.x -> rename to `AGW_ENABLE_EXPERIMENTAL_GATEWAY_API_FEATURES`.
4. v1.7.0 does NOT contain the LLM array-content parser fix (#3729, merged
   2026-11-03, after the 2026-10-27 tag). The GLM non-streaming 503 persists
   until the first 1.x release after v1.7.0 (tracked in #751). What 1.x does
   fix is #704 (API-key auth failing open on missing Secrets) - the canary
   plan includes a fail-closed 401 proof before cutover.
5. Flux charts stay on ghcr.io (v1.7.0 tags verified anonymously pullable;
   cr.agentgateway.dev 401s anonymous). Pod images stay on
   cr.agentgateway.dev; the only hard unknown is the preflight node pull gate
   (P1): a v1.7.0 tag is absent from each node's image cache until that node's
   first pull, and IfNotPresent never re-verifies a tag it has already cached.
6. Breakage audit: nothing in the v1.7.0 breaking-change list affects this
   stack except the env-var rename (behavior-preserving by default) and
   redacted error bodies (ops note). MCP session encryption and the ToolOutput
   prompt-guard scope change are not-affecting because our MCP is raw HTTP
   passthrough and no promptGuard is configured.
7. One extra surface discovered: the substrate atenet-egress/atenet-router
   pods run a 0.x-era agentgateway-repo build and must be re-verified against
   the 1.x data plane during cutover (they are the only model egress for
   substrate actors, via the hostname-less 8443-8445 listeners).
