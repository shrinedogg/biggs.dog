# agent-substrate (cluster1, ai-system)

The substrate control plane (kagent-dev substrate) runs in `ai-system` on
cluster1, deployed by the `substrate` HelmRelease (chart v0.5.0-alpha2) with
kagent 1.0.0-alpha11. Re-enabled by the substrate-stack migration (issue
#594, PR #597) on 2026-10-10.

## Layout

- `app/helmrelease.yaml` — the release. PostRenderers pin the Deployments to
  the GPU node, point the node-local atelet at the release-local api Service
  (the chart defaults to the canonical `ate-system` namespace), and pin the
  B2 object-store env on `ate-api-server`. `values` disables the bundled
  rustfs and points `atelet.extraEnv` at B2.
- `app/external-secrets.yaml` — BYO postgres connection strings
  (cnpg-substrate) + `substrate-b2-object-store` (S3 key pair).
- OCIRepository: `clusters/cluster1/flux-system/sources/substrate-oci.yaml`.

## Snapshot storage: Backblaze B2 (issue #598)

The substrate S3 backend is pointed at the durable B2 endpoint shared with
CNPG/Barman and volsync (`s3.eu-central-003.backblazeb2.com`), not the chart's
default in-cluster rustfs (disabled via `values.rustfs.enabled: false`). The
`b2-object-store-keys` 1Password item is scoped to the `biggs-dog` bucket, so
all substrate objects live under a dedicated prefix:

- `biggs-dog/substrate/gvisor.tar.zstd` — the gVisor runtime asset the golden
  actors download. Seeded once from the upstream nightly 2026-09-02 tarball;
  the pinned sha256 is the chart's own, so a re-seed must be the same bytes.
  Durable, so it survives cluster rebuilds (no re-upload step).
- `biggs-dog/substrate/kagent/atespaces/...` — golden actor snapshots, written
  by the node-local atelet. The location is set per-Harness in
  `kagent/app/harnesses.yaml` (`snapshotPolicy.location`).

Both S3 readers need the same five AWS_* env (endpoint, region, path-style,
key pair): the atelet DaemonSet via `atelet.extraEnv`, the ate-api-server
Deployment via a postRenderer patch (the chart has no env value hook for it).
They are pinned identically in `app/helmrelease.yaml`; if they drift, snapshot
reads fail at restore.

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
