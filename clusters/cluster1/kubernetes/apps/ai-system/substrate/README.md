# agent-substrate (cluster1, ai-system) — suspended pending migration

agent-substrate was torn down from cluster1 on 2026-10-09:

- HelmRelease `substrate` uninstalled (no orphans; postgres + rustfs data
  deleted by hand).
- The four `ate.dev` CRDs (`workerpools`, `sandboxconfigs`, `actortemplates`,
  `csidriverconfigs`) removed with the `substrate-crds` release.
- kagent substrate wiring disabled (`controller.substrate.enabled: false`,
  `substrateWorkerPool.create: false`); the `kagent-default` WorkerPool and the
  `kagent-ate-api-env-sources` RBAC were pruned by the kagent upgrade.
- `kagent/substrate-agents` (5 dead SandboxAgent CRs) removed.
- `csi-driver/app/clusterissuer.yaml` (`substrate-podcert-selfsigned`) removed;
  nothing consumed it after the WorkerPool went away.

This directory (`substrate/app`) + the `substrate` OCIRepository
(`clusters/cluster1/flux-system/sources/substrate-oci.yaml`) are kept as the
re-enable starting point for the substrate-stack migration workstream.

## Re-enable procedure (the migration)

The substrate stack upgrades only as a whole set (renovate group
`substrate-stack`, automerge:false). To bring it back:

1. Choose the target version. As of 2026-10-09:
   - substrate (kagent-dev) latest = `v0.5.0-alpha2` (2026-10-08); last of the
     0.0.x line = `v0.0.30`; live before teardown was `v0.0.21`.
   - kagent latest = `v1.0.0-alpha10` (2026-10-09); this cluster ran
     `v0.10.3`. kagent 1.0.0-alpha renamed `substrateWorkerPool.ateomImage`
     to `workerImage` and the CRDs renamed `WorkerPool.spec.ateomImage` to
     `spec.workerImage` (from substrate 0.0.22), so a kagent chart bump is
     part of this migration, not just the substrate charts.
2. Rebuild the digest-pinned `shrinedogg/ateapi` fork against the target
   substrate version (the `--client-jwt-jwks-url` patch set, see
   `.wip/substrate-jwks-url/`). The fork MUST track the control-plane version
   or the ateletpb RunRequest wire breaks ("string field contains invalid
   UTF-8").
3. Re-create `clusters/cluster1/flux-system/sources/substrate-crds-oci.yaml`
   (tag = target version) and re-list it in `flux-system/sources/
   kustomization.yaml`.
4. Bump `substrate-oci.yaml` tag to the target version; recreate
   `clusters/cluster1/kubernetes/apps/ai-system/substrate-crds/` (KS + Helm
   Release) and re-list it in `apps/ai-system/kustomization.yaml`.
5. Recreate this directory's `ks.yaml` (path `./app`, dependsOn
   `substrate-crds`) and re-list it in `apps/ai-system/kustomization.yaml`.
   Re-verify the `app/helmrelease.yaml` postRenderers against the new chart:
   the `ate-system` namespace Role workaround, the `--ateapi-conn-spec` dial
   address, the valkey `cluster-announce-ip` fix, and the ateapi fork digest
   all need re-checking per version.
6. Bump kagent to the matching 1.0.0-alpha chart (new `kagent-oci.yaml` tag),
   set `substrateWorkerPool.workerImage` (renamed from `ateomImage`) to the
   matching ateom-gvisor tag, and flip `controller.substrate.enabled: true`
   + `substrateWorkerPool.create: true` in `kagent/app/helmrelease.yaml`.
   Re-add the `substrate-crds` dependsOn to `kagent/ks.yaml`.
7. Recreate `kagent/substrate-agents/` (the 5 SandboxAgent CRs) + its KS and
   re-list it in `apps/ai-system/kustomization.yaml`.
8. Decide the worker pod-identity story: v0.0.12+ workers hard-require an
   atunnel credential bundle at
   `/run/podidentity.podcert.ate.dev/credential-bundle.pem` (PodCertificate
   projection, mtls mode); this cluster ran jwt-mode on Talos, which lacks
   the ClusterTrustBundle/PodCertificateRequest gates. Either run the new
   version in jwt mode if still supported, or re-add the
   cert-manager-CSI-based podidentity init-container patch (formerly
   `kagent-podcert-patch`) against the new mechanism.
9. Commit to main; Flux reconciles substrate-crds -> substrate -> kagent ->
   substrate-agents (dependsOn ordering).
