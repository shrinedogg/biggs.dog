# agent-substrate (cluster1, ai-system)

The substrate control plane (kagent-dev substrate) runs in `ai-system` on
cluster1, deployed by the `substrate` HelmRelease (chart 0.7.0-alpha2, the
substrate 1.0 line) with kagent 1.0.0-alpha11. Re-enabled by the substrate-
stack migration (issue #594, PR #597) on 2026-10-10.

## Layout

- `app/helmrelease.yaml` — the release. PostRenderers pin the Deployments to
  the GPU node and point the node-local atelet at the release-local api
  Service (the chart defaults to the canonical `ate-system` namespace).
  `values` disables the bundled rustfs and pins the B2 object-store env on
  `objectStorePlugin.extraEnv`, which the 0.7.0 chart's storage.env helper
  renders onto both objectstore-plugin init containers (the S3 readers).
- `app/external-secrets.yaml` — BYO postgres connection strings
  (cnpg-substrate) + `substrate-b2-object-store` (S3 key pair).
- OCIRepository: `clusters/cluster1/flux-system/sources/substrate-oci.yaml`.

## Snapshot storage: Backblaze B2 (issue #598)

The substrate S3 backend is pointed at the durable B2 endpoint shared with
CNPG/Barman and volsync (`s3.eu-central-003.backblazeb2.com`), not the chart's
default in-cluster rustfs (disabled via `values.rustfs.enabled: false`). The
`b2-object-store-keys` 1Password item is scoped to the `biggs-dog` bucket, so
all substrate objects live under a dedicated prefix:

- `biggs-dog/substrate/gvisor.tar.zstd` — the gVisor runtime asset the node
  objectstore-plugin downloads for the sandbox runtimes. Since the 0.7.0
  cutover it must hold the 20261019.0 x86_64 release tarball (the chart's
  own sha256 pin; the pre-0.7 seed was the 2026-09-02 nightly and no longer
  matches), so it is reseeded before the 0.7.0 merge (runbook in PR #865).
  Durable, so it survives cluster rebuilds (no re-upload step after the
  reseed).
- `biggs-dog/substrate/kagent/atespaces/...` — golden actor snapshots,
  written by the node-side objectstore-plugin. The location is set per-
  Harness in `kagent/app/harnesses.yaml` (`snapshotPolicy.location`).

The 0.7.0 chart does the S3 I/O in the objectstore-plugin init containers
(node mode in the atelet DaemonSet, control mode in the ate-api-server pod);
both take their env from `values.objectStorePlugin.extraEnv` (the chart's
storage.env helper), so the five AWS_* vars (endpoint, region, path-style,
key pair) live there in `app/helmrelease.yaml`. The pre-0.7 pins (the
`atelet.extraEnv` on the atelet container and a postRenderer env patch on
the ate-api-server container) no longer reach the 0.7 S3 readers and are
retired.

Egress: `allow-egress-atelet-registries` (world:443) covers the atelet;
`allow-egress-substrate-b2` (toFQDNs the S3 endpoint) covers ate-api-server.
Both in `network-policies/policies/infra/ai-system.yaml`.

## History

Torn down on 2026-10-09, re-enabled 2026-10-10 (issue #594):

- substrate v0.5.0-alpha2 + kagent 1.0.0-alpha11 (API group
  `kagent.dev/v1alpha2` -> `api.kagent.dev/v1alpha3`; `SandboxAgent` ->
  `Agent` + `Harness`).
- The pre-migration re-enable procedure (rebuild the digest-pinned `ateapi`
  fork, recreate the CRD sources + KSs, re-enable the kagent substrate
  wiring, worker pod-identity story) is preserved in this file's git
  history.
- 0.7.0-alpha2 cutover (2026-11-15, PR #865): S3 I/O moved into the
  objectstore-plugin init containers (env via `objectStorePlugin.extraEnv`);
  the pre-squash cnpg-substrate database is recreated on the cutover
  (migrations through v0.6.0 are squashed into `000001_initial.sql`); the
  gVisor asset reseed is the 20261019.0 tarball. Cutover watch: the 0.7.0
  chart renders k8s NetworkPolicies into ai-system (default-deny-ingress +
  per-workload allows; client namespaces need the `ate.dev/api-access=true`
  label) -- verify kagent agent + kagent-mcp ingress still flow after apply.
