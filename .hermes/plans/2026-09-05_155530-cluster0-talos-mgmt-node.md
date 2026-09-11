# cluster0 on-prem Talos management node via knr-ops local-talos: Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task. Every task that touches a live cluster is gated on explicit user approval (biggs.dog golden rule 1, knr-ops golden rule 1).

**Goal:** Replace the UpCloud `cluster0` VM with a single-node on-prem Talos machine that is bootstrapped and self-managed with the knr-ops kind -> Flux -> CAPI -> pivot pattern, carries every existing cluster0 workload (Cilium, cert-manager, external-secrets, agentgateway, Dex, NetBird, Omni, Image Factory, network policies), and then re-creates `cluster1` from the self-hosted Omni with its data disks retained.

**Architecture:** The CAPI management tree lives in biggs.dog under `clusters/cluster0/capi/` (knr-ops component layout: `kustomization.yaml` + `flux-ks.yaml` per component). `knr-bootstrap` (knr-ops `bootstrap-rs`) runs from the biggs.dog checkout with `BOOTSTRAP_CONFIG=bootstrap.toml`, syncing `clusters/cluster0/capi` on the kind bootstrap cluster, creating the Talos node through CAPT + Tinkerbell (Tinkerbell hosted temporarily on cluster1), pivoting, then the FluxInstance path is widened once to `clusters/cluster0` so the full workload tree reconciles. Cilium is installed at cluster creation by a ClusterResourceSet and adopted by the existing Cilium HelmRelease. cluster1 is rebuilt through self-hosted Omni (Path B) with only OS disks wiped.

**Tech Stack:** knr-ops bootstrap-rs (`knr-bootstrap`), CAPI v1.14 operator, CAPT fork `shrinedogg/cluster-api-provider-tinkerbell` v0.7.1, sidero-community CABPT v0.7.6 + CACPPT v0.6.4, Tinkerbell (Smee/Tink/Tootles via `tinkerbell/charts` v0.25.0), Talos v1.14 + Image Factory (self-hosted at `factory.biggs.dog`), Flux Operator 0.58.0 / Flux 2.9.0, Cilium 1.20.1, Omni v1.10.4, SOPS + age, External Secrets + 1Password Connect.

---

## 0. Decisions already made (from the design conversation, 2026-09-05)

| Decision | Value |
|---|---|
| Placement | New Talos node **becomes cluster0**; UpCloud VM retired after cutover |
| CAPI tree location | biggs.dog `clusters/cluster0/capi/`; bootstrapped by `knr-bootstrap` with `BOOTSTRAP_CONFIG` |
| Tinkerbell host for first boot | Temporarily on existing cluster1 (same LAN), relocated to cluster0 before cluster1 is wiped |
| cluster1 data | Retain disks: Talos install only to the OS disk; re-adopt rook-ceph OSDs and the ZFS pool; risk documented in section 9 |
| CNI on the management node | Cilium via ClusterResourceSet at create time, adopted by the cluster0 Cilium HelmRelease |
| WAN DNS | external-dns on cluster0 with the existing Cloudflare token (Task 14b); no manual A-record step |
| cluster1 Talos version at rebuild | Stay on v1.13.5; upgrade through Omni later once the nvidia-open extension exists for 1.14 in the local factory catalog |
| SideroLink reach | LAN only; Omni advertises the node address 192.168.2.31; no UDP 50180 forward |
| Pruning | `prune: true` for every Kustomization under `clusters/cluster0/capi/`; `prune: false` for the rest of cluster0 |
| Management node | MAC `24:4b:fe:5c:d9:4a`, IP `192.168.2.31`, install disk `/dev/nvme0n1`, Intel NIC, no BMC (manual power-on; Rufio disabled) |

## 1. Verified facts this plan depends on

- knr-ops `mgmt/local-talos` (commit 7110f78 on main) has never run end to end (`docs/bootstrap-cli.md:213`). The tree is management-only, no addons, GitHub sync, `talosVersion: v1.14`, Kubernetes `v1.36.0`, Talos node `allowSchedulingOnControlPlanes`.
- `knr-bootstrap` reads `bootstrap.toml` from `BOOTSTRAP_CONFIG` or `./bootstrap.toml` (`bootstrap-rs/src/config.rs:161-175`), env knobs `GIT_REPO_URL`, `GITHUB_TOKEN`, `GITHUB_USER`, `AGE_KEY_FILE`, `KNR_OPS_PROFILE`, `BOOTSTRAP_PIVOT`, `PIVOT_SKIP_DELETE`, `MGMT_READY_TIMEOUT`, `BOOTSTRAP_KUBECONTEXT`. `provider-manifests` are `kubectl apply -f <path>` relative to the working directory (`main.rs:1833`).
- Pivot Phase 3 installs imperatively into the target: `cert-manager` (release `cert-manager`, ns `cert-manager`, `crds.enabled=true`) and `capi-operator` (release `capi-operator`, ns `capi-operator-system`, `cert-manager.enabled=false`), then applies `provider-manifests` (`main.rs:1760-1840`). Phase 5 seeds `flux-operator` + secrets `flux-github-pat` / `sops-age` + a FluxInstance named `flux` via the `flux-instance` chart with `instance.sync.path = <sync-path>` and `pullSecret = flux-github-pat` (`main.rs:1198-1290`, `2080-2135`). `sync-path` is used for BOTH the kind cluster and the target.
- CAPT fork v0.7.1 = upstream main c3ee56d + commit 6036952 (installer-image mirror). Release assets and image `ghcr.io/shrinedogg/cluster-api-provider-tinkerbell:v0.7.1` exist; `metadata.yaml` 0.7 -> contract v1beta2; unit tests pass locally. Upstream PR tinkerbell#604 still open.
- CABPT v0.7.6 consumes `status.installerImage` (`controllers/installer_image.go`, `talosconfig_controller.go:410-417`) and patches `machine.install.image`.
- **Gap:** CAPT's default Workflow template is Ubuntu/cloud-init shaped (`controller/machine/template.go:30-100`: `oci2disk` + cloud-init `writefile` + `kexec`). It cannot install Talos. Template precedence (`template.go:186-214`): `TinkerbellMachine.spec.templateOverride` -> Hardware annotation `hardware.tinkerbell.org/capt-template-override` -> `TinkerbellCluster.spec.templateOverride` / `templateOverrideRef` -> default. A Talos workflow template committed on the `TinkerbellCluster` closes the gap with no provider change (section 4, Task 12).
- CAPT writes the CABPT bootstrap secret (a Talos machine config) into `Hardware.spec.userData`; Tootles (the metadata server in the current Tinkerbell stack, Hegel successor) serves it at `http://<tinkerbell-ip>:7080/2009-04-04/user-data` (port 7080: the consolidated Tinkerbell HTTP server; legacy Hegel used 50061). Talos `metal` reads `talos.config=<url>` from the kernel command line.
- CAPT supports an external Tinkerbell cluster via `--external-kubeconfig` mounted from Secret `external-tinkerbell-kubeconfig` in `capt-system` (`main.go:368-370`, `config/manager/manager.yaml:47-59`, `docs/REMOTE-TINKERBELL-KUBECONFIG.md`). Hardware `list` needs a ClusterRole in the Tinkerbell cluster.
- biggs.dog cluster0 today: single UpCloud node, public IP `87.58.147.51` used as Cilium L2 pool (`/32`), `externalIPs` on `omni-siderolink` and `netbird-stun`, `--siderolink-wireguard-advertised-addr=87.58.147.51:50180`, NetBird PVC on `upcloud-block-storage-maxiops`, Omni PVCs with no storageClass, FluxInstance `prune: false` patch, pullSecret `flux-system`, root sync autodetects the whole `clusters/cluster0` tree (no root `kustomization.yaml`).
- Hosted Omni cluster etcd backups (B2 `biggs-dog/cf16d71c-4f23-4a26-9edf-1da46673b7b7/`, 12h schedule) are age-format encrypted (`nacl_v1` recipient) with a per-cluster `EtcdBackupEncryption` key generated and held only by hosted Omni; SaaS denies `EtcdBackupEncryption`, `ClusterSecrets`, and full machine configs (PermissionDenied, verified 2026-09-05), and the support bundle ships redacted configs only. Local SOPS age keys and cluster0's omni.asc do NOT decrypt the snapshots (tested). Consequence: snapshots are usable ONLY by hosted Omni itself (bootstrapSpec restore on biggs-dog); they are a SaaS-side rollback, NOT an input to the rebuild (decision 2026-09-05, no Sidero support ticket).
- UpCloud cluster0 was found DOWN 2026-09-05 (k3s API TLS EOF; omni.biggs.dog unreachable). Task 1 freeze is moot while it stays down; Task 23 revised accordingly.
- biggs.dog cluster0 Kustomization graph: `cilium`, `cert-manager` -> `issuers`, `external-secrets` -> `secretstore`, `onepassword-connect` (SOPS), `gateway-api-crds` -> `agentgateway-crds` -> `agentgateway`, `dex` <- {secretstore, issuers, agentgateway}, `omni` / `netbird` / `image-factory` <- {secretstore, issuers, dex, agentgateway}, `network-policies-{apps,infra}`.
- cluster1 (hosted Omni; live 2026-09-05: Talos v1.13.8, k8s v1.36.3, Omni backend v1.10.6): rook OSDs on `/dev/nvme0n1` of worker-01..04; install disks per `.omni/cluster1/omni-export/cluster-template.yaml`: worker-01/04 `/dev/nvme1n1`, worker-02/03 `/dev/sda`, control-01 `/dev/nvme0n1`, nv-01 `/dev/nvme0n1`. ZFS pool `tank` (openebs zfs-localpv). openebs hostpath `basePath: /var/mnt/host-path`. CNPG depends on openebs (node-local). Import into self-hosted Omni is blocked (no os:admin), so Path B applies.

## 2. Site values (fill in before Task 1; every occurrence is marked `SITE:`)

| Key | Placeholder used below | Notes |
|---|---|---|
| Management node MAC | `24:4b:fe:5c:d9:4a` | Confirmed 2026-09-05; Tinkerbell Hardware CR and UDM DHCP reservation |
| Management node IP | `192.168.2.31` | Confirmed; static UDM reservation on the node VLAN (`192.168.2.0/24`, same L2 as cluster1 nodes; cluster1 nodes use .25-.30) |
| Management node install disk | `/dev/nvme0n1` | Confirmed (nvme0); re-check the exact node name with `talosctl disks` in maintenance mode before Task 12 |
| cluster0 LB address (Cilium L2 pool) | `192.168.2.31/32` | Replaces `87.58.147.51/32`. Decision 2026-09-05: the LB address IS the node's own IP (no separate VIP), same effective pattern as the old externalIPs. The UDM reservation serves double duty |
| Home WAN IP | discovered at runtime | external-dns (Task 14b) publishes it to Cloudflare for `omni`, `dex`, `netbird`, `factory`; no static value needed |
| Tinkerbell (Smee/Tootles) IP while on cluster1 | `192.168.2.30` (control-01 host network) | Smee runs hostNetwork on one cluster1 node; see Task 9 |
| Tinkerbell IP after relocation to cluster0 | `192.168.2.31` (host network) | Task 27 |
| Talos version (mgmt node) | `v1.14` (`talosVersion`), image `v1.14.0` | knr-ops pin; Intel NIC so the schematic needs `siderolabs/intel-ucode`, no realtek-firmware |
| Talos version (cluster1 rebuild) | `v1.13.5` | Decision 2026-09-05; upgrade via Omni later |
| Kubernetes version (mgmt node) | `v1.36.0` | knr-ops pin |
| GitHub PAT for Flux | 1Password `biggs-dog` vault, item `flux-github-pat` (create if absent) | Read-only Contents on `shrinedogg/biggs.dog` |

## 3. Phase overview and gates

| Phase | Content | Live impact | Gate before next phase |
|---|---|---|---|
| A | Freeze UpCloud cluster0 sync; repo work on `main` via stacked PRs | None on UpCloud after freeze | `kubectl kustomize` renders; `knr-bootstrap` parses the config |
| B | Tinkerbell stack on cluster1, Hardware CR, CAPT remote RBAC | cluster1 gains ns `tinkerbell` | Target machine PXE-reaches Smee (idle, no workflow) |
| C | Talos workflow template bench test on the target machine | Wipes the target machine only | Talos boots from disk with the Tootles-served config |
| D | `knr-bootstrap local-talos` bootstrap (no pivot), then pivot | kind on laptop; target machine installed | `kubectl get nodes` on target: 1 Ready node; Cluster Available; kind deleted |
| E | Widen FluxInstance path; full cluster0 workload reconcile; state copy from UpCloud; DNS cutover | New cluster0 serves `*.biggs.dog` edge; UpCloud idle | All cluster0 Kustomizations Ready; Omni UI login works |
| F | Relocate Tinkerbell to cluster0; CAPT to local mode | cluster1 loses ns `tinkerbell` | CAPT Ready without the external secret |
| G | cluster1 Path B rebuild through Omni with retained disks | Full cluster1 outage | Rook HEALTH_OK, ZFS imported, CNPG restored, Flux Ready |
| H | Retire UpCloud, docs, knr-ops upstream PRs | UpCloud VM deleted | Docs merged |

---

## Phase A: Freeze UpCloud and build the tree (repo work)

### Task 1: Freeze UpCloud cluster0 reconciliation (live, approval required)

**Objective:** Make edits to `clusters/cluster0` on `main` safe while the UpCloud node is still serving.

**Step 1:** Suspend the source so every Kustomization keeps its last artifact:

```sh
kubectl --context shrinedogg-biggs-dog-cluster0 -n flux-system annotate fluxinstance/flux fluxcd.controlplane.io/reconcile=disabled --overwrite
flux --context shrinedogg-biggs-dog-cluster0 suspend source git flux-system -n flux-system
```

(Confirm the kubeconfig context name for UpCloud first: `kubectl config get-contexts`.)

**Step 2:** Verify: `flux get sources git -n flux-system` shows `Suspended: True`; `flux get kustomizations -A` all still `Ready`.

**Step 3:** Record in `docs/NOTES.md` under a new "cluster0 migration 2026-09" heading that UpCloud is frozen at commit `<sha>`.

### Task 2: Create the knr-ops worktree and build `knr-bootstrap`

**Files:** none in biggs.dog.

```sh
cd ~/Code/knr-ops && git worktree add ../knr-ops-wt-biggs-bootstrap origin/main
cd ../knr-ops-wt-biggs-bootstrap
mise install && mise -E local-talos install          # kubectl, kind, helm, flux, clusterctl, sops, age, talosctl
cargo build --release --locked --manifest-path bootstrap-rs/Cargo.toml
ls -l bootstrap-rs/target/release/knr-bootstrap
```

Expected: binary present; `knr-bootstrap --help` prints the positional profile and `--recreate`.

### Task 3: biggs.dog branch and PR plan

Work on branch `cluster0-onprem-capi`. Stacked PRs (pause for user review + merge after each, per user rule):

1. PR A1: `clusters/cluster0/capi/` tree + `bootstrap.toml` + `.sops.yaml` rule + cert-manager/source relocation (Tasks 4-8, 12-13).
2. PR A2: cluster0 workload adjustments for on-prem (Tasks 14-16).
3. PR B1: cluster1 Tinkerbell stack (Tasks 9-11).
4. Later PRs per phase (E, F, G, H).

Validation for every PR: `kubectl kustomize clusters/cluster0/capi`, `kubectl kustomize clusters/cluster0/kubernetes/apps/<ns>` for each touched ns, plus the Python multi-doc parse from AGENTS.md.

### Task 4: `clusters/cluster0/capi/` root and infrastructure components

**Objective:** A Flux root that is valid standalone (kind bootstrap syncs it) and also a subtree of `clusters/cluster0` (target syncs the parent). Single definitions only: objects defined here are removed from the apps tree in Task 8.

**Files:**
- Create: `clusters/cluster0/capi/kustomization.yaml`
- Create: `clusters/cluster0/capi/sources/kustomization.yaml`
- Move: `clusters/cluster0/flux-system/sources/cert-manager-repo.yaml` -> `clusters/cluster0/capi/sources/cert-manager-repo.yaml`
- Create: `clusters/cluster0/capi/sources/capi-operator-repo.yaml`
- Create: `clusters/cluster0/capi/infrastructure/flux-ks.yaml`
- Create: `clusters/cluster0/capi/infrastructure/capi-operator/kustomization.yaml`, `helmrelease.yaml`

`clusters/cluster0/capi/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
# Root of the CAPI management subtree. Synced standalone by the kind
# bootstrap cluster (bootstrap.toml sync-path) and as part of
# clusters/cluster0 by the management node after the pivot (Task 22).
resources:
  - sources
  - infrastructure/flux-ks.yaml
  - capi-providers/flux-ks.yaml
  - clusters/flux-ks.yaml
```

`clusters/cluster0/capi/sources/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - cert-manager-repo.yaml
  - capi-operator-repo.yaml
```

`clusters/cluster0/capi/sources/capi-operator-repo.yaml`:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: capi-operator
  namespace: flux-system
spec:
  interval: 1h
  url: https://kubernetes-sigs.github.io/cluster-api-operator
```

`clusters/cluster0/capi/infrastructure/flux-ks.yaml` (biggs.dog ks label conventions; `prune: true` for every Kustomization under `capi/` per decision 2026-09-05, the rest of cluster0 stays `prune: false`):

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app cert-manager
  namespace: flux-system
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./clusters/cluster0/kubernetes/apps/cert-manager/cert-manager/app
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 3m
  retryInterval: 1m
  timeout: 5m
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: &app capi-operator
  namespace: flux-system
spec:
  commonMetadata:
    labels:
      app.kubernetes.io/name: *app
  path: ./clusters/cluster0/capi/infrastructure/capi-operator
  prune: true
  sourceRef:
    kind: GitRepository
    name: flux-system
  wait: true
  interval: 3m
  retryInterval: 1m
  timeout: 5m
  dependsOn:
    - name: cert-manager
```

`clusters/cluster0/capi/infrastructure/capi-operator/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - helmrelease.yaml
```

`namespace.yaml`: Namespace `capi-operator-system` with `pod-security.kubernetes.io/enforce: baseline` labels (copy label block from `clusters/cluster0/kubernetes/apps/auth/namespace.yaml`).

`helmrelease.yaml` (namespace and release name MUST equal the pivot's imperative install so Flux adopts it):

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: capi-operator
  namespace: capi-operator-system
spec:
  interval: 10m
  chart:
    spec:
      chart: cluster-api-operator
      version: "0.28.0"
      sourceRef:
        kind: HelmRepository
        name: capi-operator
        namespace: flux-system
  install:
    remediation:
      retries: 3
  upgrade:
    cleanupOnFail: true
    remediation:
      strategy: rollback
      retries: 3
  values:
    cert-manager:
      enabled: false
```

**Verify:** `kubectl kustomize clusters/cluster0/capi` renders (it will still fail until Tasks 5-7 add the other referenced files; run at the end of Task 7).

### Task 5: CAPI providers

**Files (copy from knr-ops `mgmt/local-talos/capi-providers/`, then edit paths):**
- Create: `clusters/cluster0/capi/capi-providers/flux-ks.yaml`
- Create: `clusters/cluster0/capi/capi-providers/{capi-system,cabpt-system,cacppt-system,capt-system}/{kustomization.yaml,namespace.yaml,provider(s).yaml}`
- Create: `clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml` (Task 11 produces the content)

Copy verbatim:

```sh
cp -R ~/Code/knr-ops-wt-biggs-bootstrap/mgmt/local-talos/capi-providers/* clusters/cluster0/capi/capi-providers/
sed -i '' 's#./mgmt/local-talos/#./clusters/cluster0/capi/#g' clusters/cluster0/capi/capi-providers/flux-ks.yaml
```

Edits to `flux-ks.yaml`:
- Keep `prune: true` on all four Kustomizations (capi/ decision).
- `capt-system` Kustomization gains:
  ```yaml
    decryption:
      provider: sops
      secretRef:
        name: sops-age
  ```
- Keep `dependsOn: [capi-operator]` on `capi-system` (name matches Task 4) and `dependsOn: [capi-system]` on the three provider Kustomizations. Keep the CRD `healthChecks`.

`capt-system/kustomization.yaml` adds `- external-tinkerbell-kubeconfig.sops.yaml` after `namespace.yaml`.

Pins stay as in knr-ops: CoreProvider `cluster-api` v1.14.0, kubeadm providers v1.14.0 (ride along), CABPT `talos` v0.7.6 + CACPPT `talos` v0.6.4 from sidero-community `fetchConfig`, CAPT `tinkerbell-tinkerbell` v0.7.1 from `https://github.com/shrinedogg/cluster-api-provider-tinkerbell/releases`. Add `# renovate:` comments only if biggs.dog `renovate.json` gains a matching regex manager (Task 31).

### Task 6: Management cluster definition

**Files:**
- Create: `clusters/cluster0/capi/clusters/flux-ks.yaml` (copy knr-ops `mgmt/local-talos/clusters/flux-ks.yaml`; rename Kustomization to `cluster0-management`, path `./clusters/cluster0/capi/clusters/management`, keep `prune: true`, `dependsOn` cabpt/cacppt/capt, `healthChecks` on Cluster `cluster0`)
- Create: `clusters/cluster0/capi/clusters/kustomization.yaml` -> `resources: [management]`
- Create: `clusters/cluster0/capi/clusters/management/kustomization.yaml` -> `resources: [cluster.yaml, cilium-crs.yaml, talos-workflow-template.yaml]`
- Create: `clusters/cluster0/capi/clusters/management/cluster.yaml`

`cluster.yaml` (from knr-ops `cluster.yaml`, renamed and patched for Cilium + Talos site values):

```yaml
---
apiVersion: cluster.x-k8s.io/v1beta2
kind: Cluster
metadata:
  name: cluster0
  namespace: default
  labels:
    biggs.dog/cluster: cluster0
spec:
  clusterNetwork:
    pods:
      cidrBlocks: ["10.244.0.0/16"]
    services:
      cidrBlocks: ["10.96.0.0/12"]
    serviceDomain: cluster.local
  controlPlaneEndpoint:
    host: 192.168.2.31        # SITE
    port: 6443
  controlPlaneRef:
    apiVersion: controlplane.cluster.x-k8s.io/v1beta1
    kind: TalosControlPlane
    name: cluster0
  infrastructureRef:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: TinkerbellCluster
    name: cluster0
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: TinkerbellCluster
metadata:
  name: cluster0
  namespace: default
spec:
  # Talos-aware provisioning workflow (Task 12). CAPT's default template is
  # Ubuntu/cloud-init and cannot install Talos.
  templateOverrideRef:
    name: talos-metal
    namespace: default
---
apiVersion: controlplane.cluster.x-k8s.io/v1beta1
kind: TalosControlPlane
metadata:
  name: cluster0
  namespace: default
spec:
  replicas: 1
  version: "v1.36.0"
  infrastructureTemplate:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: TinkerbellMachineTemplate
    name: cluster0
  controlPlaneConfig:
    controlplane:
      generateType: controlplane
      talosVersion: v1.14
      strategicPatches:
        - |
          cluster:
            allowSchedulingOnControlPlanes: true
            apiServer:
              certSANs:
                - 192.168.2.31      # SITE
            network:
              cni:
                name: none          # Cilium via ClusterResourceSet (cilium-crs.yaml)
            proxy:
              disabled: true        # Cilium kubeProxyReplacement
          machine:
            install:
              disk: /dev/nvme0n1    # SITE: raw image is written by the workflow; this governs upgrades
            features:
              kubePrism:
                enabled: true
                port: 7445
            kubelet:
              extraMounts:
                - destination: /var/mnt/host-path
                  type: bind
                  source: /var/mnt/host-path
                  options: [rbind, rshared, rw]
---
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: TinkerbellMachineTemplate
metadata:
  name: cluster0
  namespace: default
spec:
  template:
    spec:
      hardwareName: talos-mgmt-01
      bootOptions:
        bootMode: netboot
```

Notes:
- Pod/Service CIDRs deliberately differ from cluster1 (`10.244.0.0/16` vs the Talos defaults on cluster1) so a future Cilium clustermesh does not collide; confirm cluster1's live CIDRs with `kubectl cluster-info dump | grep -m1 cluster-cidr` and adjust.
- `TalosControlPlane` uses the v1beta1 API and puts `talosVersion` under `controlPlaneConfig.controlplane` (knr-ops comment).
- `hostname` is not set here; the Hardware CR (Task 10) carries `metadata.instance.hostname: cluster0-cp-01` for Tootles, and Talos takes the DHCP hostname. If a fixed hostname is required add a `HostnameConfig` document with `$patch: delete` on `auto` (NOTES.md pitfall).

### Task 7: Cilium ClusterResourceSet

**Objective:** Install Cilium onto the new node before it can go Ready, with Helm ownership metadata so the committed HelmRelease adopts it.

**Files:**
- Create: `clusters/cluster0/capi/clusters/management/cilium-crs.yaml` (ConfigMap + ClusterResourceSet)
- Create: `clusters/cluster0/capi/clusters/management/cilium-values.yaml` (input only, not applied; listed in `.gitattributes`? no, plain file, excluded from `kustomization.yaml`)

**Step 1:** Extract values from the committed HelmRelease and set the Talos-specific keys:

```sh
yq '.spec.values' clusters/cluster0/kubernetes/apps/kube-system/cilium/app/helmrelease.yaml > clusters/cluster0/capi/clusters/management/cilium-values.yaml
yq -i '.k8sServiceHost = "localhost" | .k8sServicePort = 7445 | .ipam.mode = "kubernetes" | .cluster.name = "cluster0" | .cluster.id = 2' clusters/cluster0/capi/clusters/management/cilium-values.yaml
```

**Step 2:** Render with Helm adoption metadata and wrap into the ConfigMap:

```sh
helm repo add cilium https://helm.cilium.io >/dev/null
helm template cilium cilium/cilium --version 1.20.1 -n kube-system \
  -f clusters/cluster0/capi/clusters/management/cilium-values.yaml \
| yq '(.metadata.labels."app.kubernetes.io/managed-by") = "Helm"
    | (.metadata.annotations."meta.helm.sh/release-name") = "cilium"
    | (.metadata.annotations."meta.helm.sh/release-namespace") = "kube-system"' \
> /tmp/cilium-rendered.yaml
wc -c /tmp/cilium-rendered.yaml   # must be < 1000000 (ConfigMap limit)
kubectl create configmap cluster0-cilium -n default --from-file=cilium.yaml=/tmp/cilium-rendered.yaml --dry-run=client -o yaml > clusters/cluster0/capi/clusters/management/cilium-crs.yaml
cat >> clusters/cluster0/capi/clusters/management/cilium-crs.yaml <<'EOF'
---
apiVersion: addons.cluster.x-k8s.io/v1beta1
kind: ClusterResourceSet
metadata:
  name: cluster0-cilium
  namespace: default
spec:
  clusterSelector:
    matchLabels:
      biggs.dog/cluster: cluster0
  strategy: ApplyOnce
  resources:
    - kind: ConfigMap
      name: cluster0-cilium
EOF
```

**Step 3:** Update the committed HelmRelease `clusters/cluster0/kubernetes/apps/kube-system/cilium/app/helmrelease.yaml` values to the same `k8sServiceHost: localhost` / `k8sServicePort: 7445` (replacing `auto`) so the adopted release does not drift. Add a comment: "Rendered copy for first boot lives in capi/clusters/management/cilium-crs.yaml; regenerate it (Task 7 Step 2) on every Cilium version or values change."

**Step 4:** Add a check script `clusters/cluster0/capi/clusters/management/check-cilium-crs.sh` that re-renders and diffs against the ConfigMap; run it in Task 3 validation.

**Verify:** `kubectl kustomize clusters/cluster0/capi | kubectl apply --dry-run=client -f -` (needs CRDs absent, so use `--validate=false`); render succeeds.

### Task 8: Remove duplicate definitions from the apps tree

**Files:**
- Modify: `clusters/cluster0/kubernetes/apps/cert-manager/cert-manager/ks.yaml`: delete the first document (Kustomization `cert-manager`); keep `issuers` with `dependsOn: [cert-manager]`.
- Modify: `clusters/cluster0/flux-system/sources/kustomization.yaml`: remove `cert-manager-repo.yaml` (moved in Task 4).

**Verify:** `grep -rn 'name: &app cert-manager$' clusters/cluster0` returns exactly one hit (in `capi/infrastructure/flux-ks.yaml`).

### Task 12: Talos Tinkerbell workflow template (the missing artifact)

**Objective:** A Tinkerbell `Template` that writes the Talos raw image to the install disk and reboots, with the machine config fetched from Tootles via `talos.config`.

**Files:**
- Create: `clusters/cluster0/capi/clusters/management/talos-workflow-template.yaml`

Design:
1. The Image Factory schematic for the management node bakes `talos.config=http://192.168.2.30:7080/2009-04-04/user-data` (SITE: Tinkerbell IP) and `talos.platform=metal` into `customization.extraKernelArgs`, plus system extensions `siderolabs/util-linux-tools` and `siderolabs/intel-ucode` (Intel NIC/CPU; no realtek-firmware needed). Create it on `factory.biggs.dog` (`curl -X POST https://factory.biggs.dog/schematics -d @schematic.yaml`) and record the schematic ID as `SITE:SCHEMATIC`.
2. Workflow actions: `image2disk` streams `https://factory.biggs.dog/image/SITE:SCHEMATIC/v1.14.0/metal-amd64.raw.zst` (verify `image2disk` accepts zstd; fall back to `.raw.xz`), then a reboot action (`quay.io/tinkerbell/actions/reboot` if present in the pinned actions release; otherwise `cexec` with `reboot`). No cloud-init, no kexec.
3. After reboot Talos boots from disk, fetches the config from Tootles (the CABPT-generated control plane config that CAPT placed in `Hardware.spec.userData`), and bootstraps etcd. CABPT's `install.image` from `status.installerImage` is then used for upgrades only.

```yaml
apiVersion: tinkerbell.org/v1alpha1
kind: Template
metadata:
  name: talos-metal
  namespace: default
spec:
  data: |
    version: "0.1"
    name: talos-metal
    global_timeout: 3600
    tasks:
      - name: "install-talos"
        worker: "{{.device_1}}"
        volumes:
          - /dev:/dev
          - /dev/console:/dev/console
        actions:
          - name: "write-talos-raw-image"
            image: quay.io/tinkerbell/actions/image2disk:latest
            timeout: 900
            environment:
              IMG_URL: https://factory.biggs.dog/image/SITE:SCHEMATIC/v1.14.0/metal-amd64.raw.zst
              DEST_DISK: /dev/nvme0n1
              COMPRESSED: "true"
          - name: "reboot"
            image: quay.io/tinkerbell/actions/reboot:latest
            timeout: 90
            pid: host
```

Pin both action images to a release tag/digest once the bench test (Task 17) passes; CAPT's own template pins `oci2disk` unpinned upstream, so a pin here is an improvement to upstream later (Task 32).

Note on `templateOverrideRef`: CAPT reads `spec.data` of the referenced Template and creates a per-machine Template from it; the referenced Template must exist in the **Tinkerbell** cluster namespace CAPT looks in (`template.go:158-175`, check whether it reads via the external client or the local client; if local, the Template must be applied to the kind/management cluster and requires the Tinkerbell CRDs there). Resolve this in Task 17 and, if local, replace `templateOverrideRef` with `templateOverride: |` inline on the TinkerbellCluster (same data, no CRD dependency).

### Task 13: `bootstrap.toml` and `.sops.yaml` for biggs.dog

**Files:**
- Create: `bootstrap.toml` (repo root of biggs.dog)
- Modify: `sops.yaml` -> the repo's SOPS rules file is named `sops.yaml`; knr-ops `mise run sops-encrypt` expects `.sops.yaml`. Encrypt with `sops --config sops.yaml -e -i <file>` instead; no rename.

`bootstrap.toml`:

```toml
# knr-bootstrap configuration for biggs.dog cluster0 (on-prem Talos management
# node). Consumed with BOOTSTRAP_CONFIG=bootstrap.toml from this checkout by the
# knr-ops bootstrap-rs binary. Environment name and kind mirror knr-ops
# local-talos so the binary's environment-kind logic applies unchanged.

[bootstrap]
default-environment = "local-talos"
git-branch = "main"
kind-cluster = "mgmt"
kind-context = "kind-mgmt"
registry-name = "knr-registry"
flux-namespace = "flux-system"
github-pat-secret = "flux-github-pat"
sops-age-secret = "sops-age"
mgmt-namespace = "default"
mgmt-context = "cluster0"

[charts]
flux-operator = "0.58.0"
cert-manager = "1.21.1"
capi-operator = "0.28.0"

[environments.local-talos]
kind = "local-talos"
sync = "github"
# CAPI-only subtree: the kind bootstrap cluster must not deploy the cluster0
# workloads. The management node widens the path to clusters/cluster0 after
# the pivot (plan Task 22).
sync-path = "clusters/cluster0/capi"
mgmt-cluster = "cluster0"
mgmt-ready-timeout = "30m"
infra-provider-namespace = "capt-system"
infra-provider-name = "tinkerbell-tinkerbell"
provider-manifests = [
  "clusters/cluster0/capi/capi-providers/capi-system/namespace.yaml",
  "clusters/cluster0/capi/capi-providers/capi-system/providers.yaml",
  "clusters/cluster0/capi/capi-providers/cabpt-system/namespace.yaml",
  "clusters/cluster0/capi/capi-providers/cabpt-system/provider.yaml",
  "clusters/cluster0/capi/capi-providers/cacppt-system/namespace.yaml",
  "clusters/cluster0/capi/capi-providers/cacppt-system/provider.yaml",
  "clusters/cluster0/capi/capi-providers/capt-system/namespace.yaml",
  "clusters/cluster0/capi/capi-providers/capt-system/provider.yaml",
]

[environments.local-talos.teardown]
capi-workloads = []
hardware-release = true
```

Compare field names against knr-ops `bootstrap.toml` and `bootstrap-rs/src/config.rs` structs before committing (`grep -n 'rename\|serde' bootstrap-rs/src/config.rs`); the file above mirrors the checked-in knr-ops keys.

**Verify parse without side effects** (fails after config load on the missing Git URL):

```sh
cd ~/Code/biggs.dog
env -u GIT_REPO_URL BOOTSTRAP_CONFIG=bootstrap.toml ~/Code/knr-ops-wt-biggs-bootstrap/bootstrap-rs/target/release/knr-bootstrap local-talos
```

Expected: error text `GIT_REPO_URL must be set` (proves the TOML parsed and the environment resolved). Any TOML error appears first instead.

### Task 14: cluster0 workloads for on-prem (PR A2)

**Files and edits (all under `clusters/cluster0/`):**
- `flux-system/flux-operator/app/flux-instance.yaml`: `pullSecret: "flux-github-pat"`. Keep `path: clusters/cluster0`, `prune: false` patch, helm-controller feature gate.
- `flux-system/sources/flux-system-git.yaml`: `secretRef.name: flux-github-pat`.
- `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`: `k8sServiceHost: localhost`, `k8sServicePort: 7445` (Task 7 Step 3).
- `kubernetes/apps/networking/agentgateway/app/cilium-lb-ip-pool.yaml`: `cidr: 192.168.2.31/32` (SITE).
- `kubernetes/apps/omni/omni/app/deployment.yaml`: `--siderolink-wireguard-advertised-addr=192.168.2.31:50180`. Decision: LAN only, no remote Talos machines; `--machine-api-advertised-url` and `--advertised-kubernetes-proxy-url` also switch to `https://192.168.2.31:8090/` and `https://192.168.2.31:8100/` since those ports are no longer forwarded from the WAN (LAN clients resolve omni.biggs.dog to the WAN CNAME via Cloudflare unless lan-dns overrides it, so the IP form avoids hairpin). Keep `--advertised-api-url=https://omni.biggs.dog/` (browser UI, forwarded 443).
- `kubernetes/apps/omni/omni/app/siderolink-service.yaml`: replace `externalIPs: [87.58.147.51]` with `type: LoadBalancer` + annotation `lbipam.cilium.io/ips: 192.168.2.31` and `lbipam.cilium.io/sharing-key: cluster0-edge` (Cilium LB-IPAM shares one VIP across Services with the same key; agentgateway's Service needs the same annotation). If sharing across TCP+UDP on one VIP misbehaves, fall back to `externalIPs: [192.168.2.31]` (node IP), which is the current pattern.
- `kubernetes/apps/netbird/netbird/app/services.yaml`: same treatment for `netbird-stun` (UDP 3478).
- `kubernetes/apps/netbird/netbird/app/server-deployment.yaml:93`: `storageClassName: host-path`.
- New `kubernetes/apps/openebs/` (ns `openebs`): copy `clusters/cluster1/kubernetes/apps/openebs/openebs/{ks.yaml,app/helmrelease.yaml}` minus `volumes/` and ZFS; keep `basePath: /var/mnt/host-path`; add `storageclass.kubernetes.io/is-default-class: "true"` on `host-path`. Add the OpenEBS HelmRepository to `flux-system/sources/` if cluster1's source file is not already present in cluster0 sources. Register in a new `kubernetes/apps/openebs/kustomization.yaml`.
- `kubernetes/apps/omni/omni/ks.yaml`, `image-factory/ks.yaml`, `netbird/ks.yaml`: add `- name: openebs` to `dependsOn`.
- `kubernetes/apps/network-policies/policies/infra/kube-system.yaml` (create if absent): CNPs for `openebs` namespace egress to kube-apiserver; and a new `policies/infra/capi.yaml` allowing `capi-operator-system`, `capi-system`, `cabpt-system`, `cacppt-system`, `capt-system` egress to kube-apiserver + DNS + world:443 (provider manifests fetched from GitHub releases by the operator; CAPT reaches the external Tinkerbell API on cluster1 at `192.168.2.30:6443`). Register the file in `network-policies/infra-ks.yaml`'s kustomization.
- `docs/NOTES.md`, `README.md`: cluster0 description updated in Task 33 (not here).

**Verify:** `kubectl kustomize clusters/cluster0/kubernetes/apps/{kube-system,networking,omni,netbird,openebs,network-policies}` render; `grep -rn '87.58.147.51' clusters/cluster0` returns only comments or nothing.

### Task 14b: external-dns on cluster0 (PR A2)

**Objective:** Publish the home WAN IP to Cloudflare for the four edge hostnames automatically, replacing the manual A-record step and covering ISP address changes.

**Files:**
- Create: `clusters/cluster0/kubernetes/apps/networking/external-dns/{ks.yaml,app/helmrelease.yaml,app/external-secret.yaml}`; register in `networking/kustomization.yaml`; `dependsOn: [secretstore, gateway-api-crds]`.
- Create: `clusters/cluster0/flux-system/sources/external-dns-repo.yaml` (HelmRepository `https://kubernetes-sigs.github.io/external-dns/`), registered in `sources/kustomization.yaml`.
- Modify: `clusters/cluster0/kubernetes/apps/networking/agentgateway/app/gateway.yaml`: annotate `cluster0-gateway` with `external-dns.alpha.kubernetes.io/target: <placeholder>`? No: use the chart's `--gateway-...` sources and a WAN-IP detection sidecar is not available upstream. Use this pattern instead: external-dns `sources: [gateway-httproute]` publishes the Gateway's `status.addresses` (the LAN VIP) by default, which is wrong for public DNS. So set on each public HTTPRoute (omni, dex, netbird, image-factory) the annotation `external-dns.alpha.kubernetes.io/target: home.biggs.dog` (CNAME target) and let a tiny DDNS job keep `home.biggs.dog` -> WAN IP.
- Create: `clusters/cluster0/kubernetes/apps/networking/ddns/{ks.yaml,app/cronjob.yaml,app/external-secret.yaml}`: CronJob every 5 min running `ghcr.io/favonia/cloudflare-ddns` (pinned tag, non-root, read-only FS) with `DOMAINS=home.biggs.dog`, `IP6_PROVIDER=none`, `PROXIED=false`, token from the same 1Password item cert-manager uses (`cloudflare-api-token`, property `api-token`; confirm the token has Zone:DNS:Edit).
- CNP: `network-policies/policies/infra/networking.yaml` gains egress `world:443` for pods labelled `app.kubernetes.io/name: external-dns` and `app.kubernetes.io/name: cloudflare-ddns`, plus DNS.

external-dns HelmRelease values:

```yaml
values:
  provider: { name: cloudflare }
  sources: [gateway-httproute]
  domainFilters: [biggs.dog]
  policy: sync
  txtOwnerId: cluster0
  txtPrefix: extdns-
  env:
    - name: CF_API_TOKEN
      valueFrom: { secretKeyRef: { name: cloudflare-api-token, key: api-token } }
  extraArgs:
    - --cloudflare-proxied=false
    - --gateway-namespace=networking
```

`policy: sync` with `txtOwnerId` means external-dns only deletes records it created (TXT ownership), so the existing UpCloud A records are NOT removed automatically: they are replaced by CNAMEs on first sync only if the existing record has no owner TXT. Cloudflare rejects a CNAME where an A exists, so Task 24 deletes the four old A records by hand right before enabling this Kustomization (keep `ks.yaml` `suspend: true` until Task 24).

**Verify (Task 24):** `kubectl -n networking logs deploy/external-dns` shows `CREATE omni.biggs.dog CNAME home.biggs.dog`; `dig +short omni.biggs.dog @1.1.1.1` returns the WAN IP.

### Task 15: LAN DNS and NAT prep (no cutover yet)

- Cloudflare: confirm the four records `omni`, `dex`, `netbird`, `factory` are DNS-only (grey cloud) and note their current values for rollback. Do not change them yet (Task 24).
- cluster1 `lan-dns` (`clusters/cluster1/kubernetes/apps/networking/lan-dns/app/`): add a `hosts` block (or `template` plugin) mapping `omni.biggs.dog`, `dex.biggs.dog`, `netbird.biggs.dog`, `factory.biggs.dog` -> `192.168.2.31`, placed **before** the k8s-gateway forward for `biggs.dog`. Commit in PR A2 but keep the four names commented out until Task 24 (cluster1 reconciles `main` live).
- UDM: prepare (do not enable) port forwards `80,443/tcp` and `3478/udp` (NetBird STUN) -> `192.168.2.31`. SideroLink ports (8090/8091/8100/tcp, 50180/udp) are LAN-only by decision and are NOT forwarded. DHCP reservation `24:4b:fe:5c:d9:4a` -> `192.168.2.31`.

### Task 16: 1Password item for the Flux PAT

Create `flux-github-pat` in the `biggs-dog` vault (account `J62CI757MRAKJACFBVNEJ26B4I`) with fields `username=shrinedogg`, `password=<fine-grained PAT, Contents read on shrinedogg/biggs.dog>`. The bootstrap reads it from the shell env (`GITHUB_TOKEN`, `GITHUB_USER`); after Flux is up, cluster0 does not need an ExternalSecret for it because `knr-bootstrap` seeds the Secret directly.

---

## Phase B: Tinkerbell on cluster1 (PR B1)

### Task 9: Tinkerbell stack in cluster1

**Files:**
- Create: `clusters/cluster1/kubernetes/apps/tinkerbell/{kustomization.yaml,namespace.yaml}`
- Create: `clusters/cluster1/kubernetes/apps/tinkerbell/tinkerbell/{ks.yaml,app/helmrelease.yaml}`
- Create: `clusters/cluster1/flux-system/sources/tinkerbell-oci.yaml` (OCIRepository `oci://ghcr.io/tinkerbell/charts/tinkerbell`, pin the current chart tag; register in `sources/kustomization.yaml`)
- Create: `clusters/cluster1/kubernetes/apps/network-policies/policies/infra/tinkerbell.yaml` (register in the infra list)
- Modify: `clusters/cluster1/kubernetes/apps/kustomization.yaml` (if a top-level list exists) to include `tinkerbell`.

Namespace: `pod-security.kubernetes.io/enforce: privileged` (hostNetwork).

HelmRelease values (chart `oci://ghcr.io/tinkerbell/charts/tinkerbell` v0.25.0; schema verified against `helm show values` 2026-09-05; the checked-in copy in PR B1 is authoritative). Key points: `deployment.hostNetwork: true` + `nodeSelector` control-01, `deployment.init.enabled: false` (macvlan relay not needed with hostNetwork), `deployment.envs.globals.publicIpv4: 192.168.2.30`, `deployment.envs.smee.dhcpMode: proxy` (UDM keeps issuing leases; Smee only answers PXE clients), iPXE hosts and `ipxeScriptTinkServerAddrPort` set to `192.168.2.30(:42113)`, Rufio/Secondstar/UI disabled (no BMC), `service.enabled: false` and `optional.kubevip.enabled: false` (hostNetwork replaces the LB).

Ports on control-01's host network: 67/udp (proxyDHCP), 69/udp (TFTP), 7080/tcp (smee iPXE http + Tootles metadata `/2009-04-04/user-data`), 42113/tcp (Tink gRPC). The legacy 50061/7171 ports do not exist in chart v0.25.0. Confirm nothing on cluster1 already binds these (`kubectl -n kube-system get pods -o wide` + Talos `talosctl -n 192.168.2.30 netstat`; the biggs.dog gateways use LB VIPs, not host ports).

CNP (`tinkerbell.yaml`): hostNetwork pods are outside Cilium endpoint policy, so only the Tink server + controller (if not hostNetwork) need egress to kube-apiserver and DNS, plus ingress on 42113 from `world` (the target machine's `tink-worker` connects over gRPC). Follow the L7 DNS convention from the flux-gitops-patterns skill.

**Verify:** `flux get kustomization tinkerbell`, `kubectl -n tinkerbell get pods -o wide` all Running on control-01; `kubectl get crd hardware.tinkerbell.org`.

### Task 10: Hardware CR for the management node

**Files:** `clusters/cluster1/kubernetes/apps/tinkerbell/hardware/{ks.yaml,app/talos-mgmt-01.yaml}`, registered in `tinkerbell/kustomization.yaml`, `dependsOn: [tinkerbell]`, `healthChecks` none.

```yaml
apiVersion: tinkerbell.org/v1alpha1
kind: Hardware
metadata:
  name: talos-mgmt-01
  namespace: default             # CAPT lists Hardware cluster-wide; keep the name = TinkerbellMachineTemplate.hardwareName
  annotations:
    # Consumed by the CAPT fork -> TinkerbellMachine.status.installerImage -> CABPT machine.install.image (upgrades).
    hardware.tinkerbell.org/installer-image: factory.biggs.dog/metal-installer/SITE:SCHEMATIC:v1.14.0
spec:
  disks:
    - device: /dev/nvme0n1       # SITE
  metadata:
    instance:
      hostname: cluster0-cp-01
      id: 24:4b:fe:5c:d9:4a
    facility:
      facility_code: home
  interfaces:
    - dhcp:
        arch: x86_64
        hostname: cluster0-cp-01
        ip:
          address: 192.168.2.31  # SITE (must equal the UDM reservation)
          gateway: 192.168.2.1
          netmask: 255.255.255.0
        lease_time: 86400
        mac: 24:4b:fe:5c:d9:4a
        name_servers: ["192.168.2.1"]
        uefi: true
      netboot:
        allowPXE: true
        allowWorkflow: true
```

Talos v1.14 installer refs on a self-hosted factory use `<factory-host>/metal-installer/<schematic>:<version>` (v1.10+ naming); confirm on `https://factory.biggs.dog/` before committing.

### Task 11: CAPT remote-Tinkerbell ServiceAccount and SOPS secret

**Objective:** CAPT (running in kind, later on the management node) talks to cluster1's Tinkerbell API.

**Files:**
- Create: `clusters/cluster1/kubernetes/apps/tinkerbell/capt-remote/{ks.yaml,app/rbac.yaml}`: ServiceAccount `capt-remote` (ns `tinkerbell`), ClusterRole for `hardware` (get/list/patch) + ClusterRoleBinding, Role/RoleBinding in ns `default` for `templates` (get/create/delete), `workflows` (get/list/watch/create/delete), `jobs.bmc.tinkerbell.org` (get/list/watch/create). Copy the YAML from `~/Code/capt-fork/docs/REMOTE-TINKERBELL-KUBECONFIG.md`.
- Create (encrypted): `clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml`.

**Steps (after PR B1 reconciles):**

```sh
TOKEN=$(kubectl -n tinkerbell create token capt-remote --duration=8760h)
CA=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
cat > /tmp/capt-kubeconfig <<EOF
apiVersion: v1
kind: Config
clusters: [{name: cluster1, cluster: {server: https://192.168.2.30:6443, certificate-authority-data: $CA}}]
users: [{name: capt-remote, user: {token: $TOKEN}}]
contexts: [{name: capt, context: {cluster: cluster1, user: capt-remote}}]
current-context: capt
EOF
kubectl create secret generic external-tinkerbell-kubeconfig -n capt-system \
  --from-file=kubeconfig=/tmp/capt-kubeconfig --dry-run=client -o yaml \
  > clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml
sops --config sops.yaml -e -i clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml
grep -c 'ENC\[' clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml   # > 0
rm /tmp/capt-kubeconfig
```

The token is a one-year bound token; note the expiry in `docs/NOTES.md`. Because the cluster1 API cert will change when cluster1 is rebuilt (Phase G), this secret is replaced in Task 27 anyway.

`sops.yaml` must contain a creation rule matching `clusters/cluster0/capi/.*\.sops\.yaml` with the deployed age recipient; extend the existing rule's `path_regex` if needed.

**Verify PXE reach (gate for Phase C):** with the target machine set to network boot (UEFI, PXE first), power it on with **no** Workflow present: Smee logs (`kubectl -n tinkerbell logs deploy/tinkerbell-smee`) show the DHCP proxy offer for `24:4b:fe:5c:d9:4a` and an iPXE script fetch; the machine sits in HookOS (Tinkerbell's in-memory OS) waiting for a workflow. Power it off.

---

## Phase C: Bench test the Talos workflow (target machine only)

### Task 17: Manual Workflow run without CAPI

**Objective:** Prove Task 12's template installs Talos and that Talos fetches its config from Tootles, before any CAPI object exists.

1. Generate a throwaway control plane config: `talosctl gen config bench https://192.168.2.31:6443 --output-dir /tmp/bench --install-disk /dev/nvme0n1 --with-docs=false --with-examples=false`.
2. Patch the Hardware with the config as userData: `kubectl patch hardware talos-mgmt-01 --type merge -p "$(jq -n --rawfile ud /tmp/bench/controlplane.yaml '{spec:{userData:$ud}}')"`.
3. Apply the Template from Task 12 (`kubectl apply -f clusters/cluster0/capi/clusters/management/talos-workflow-template.yaml`) and a Workflow:
   ```yaml
   apiVersion: tinkerbell.org/v1alpha1
   kind: Workflow
   metadata: {name: bench-talos, namespace: default}
   spec:
     templateRef: talos-metal
     hardwareRef: talos-mgmt-01
     hardwareMap: {device_1: "24:4b:fe:5c:d9:4a"}
     bootOptions: {toggleAllowNetboot: true, bootMode: netboot}
   ```
4. Power on. Watch `kubectl get workflow bench-talos -w` to `STATE_SUCCESS`, then the reboot.
5. Verify Talos: `talosctl -n 192.168.2.31 --talosconfig /tmp/bench/talosconfig version` (needs `talosctl bootstrap` first for etcd; run it, then `talosctl kubeconfig`), `talosctl -n 192.168.2.31 get machineconfig -o yaml | grep talos.config` shows the Hegel URL was used (`talosctl dmesg | grep talos.config`).
6. Record results in `docs/NOTES.md`: image2disk compression accepted, reboot action used, time to Ready. Decide `templateOverrideRef` vs inline `templateOverride` (Task 12 note) by reading `~/Code/capt-fork/controller/machine/template.go:158-180` for which client resolves the ref.
7. Reset: `talosctl -n 192.168.2.31 reset --graceful=false --reboot --system-labels-to-wipe STATE,EPHEMERAL`; delete the bench Workflow; clear `spec.userData` on the Hardware (`kubectl patch hardware talos-mgmt-01 --type json -p '[{"op":"remove","path":"/spec/userData"}]'`); set `allowPXE: true` again if the workflow toggled it off.

Gate: steps 4-5 succeed twice in a row (idempotent template).

---

## Phase D: Bootstrap and pivot

### Task 18: Environment for `knr-bootstrap`

```sh
cd ~/Code/biggs.dog && git checkout main && git pull --ff-only     # PRs A1, A2, B1 merged
export BOOTSTRAP_CONFIG=bootstrap.toml
export KNR_OPS_PROFILE=local-talos
export GIT_REPO_URL=https://github.com/shrinedogg/biggs.dog
export GITHUB_USER=shrinedogg
export GITHUB_TOKEN=$(op read 'op://biggs-dog/flux-github-pat/password' --account J62CI757MRAKJACFBVNEJ26B4I)
export AGE_KEY_FILE=age.agekey
export MGMT_READY_TIMEOUT=45m
export PATH="$HOME/Code/knr-ops-wt-biggs-bootstrap/bootstrap-rs/target/release:$PATH"
kubectl config use-context kind-mgmt 2>/dev/null || true
```

Preflight expectations from `main.rs:581-735`: tools `kind helm kubectl clusterctl flux` present; `age.agekey` valid (the biggs.dog key, whose public key is in `sops.yaml`); GitHub repo reachable with the PAT.

### Task 19: Bootstrap without pivot (approval required)

```sh
BOOTSTRAP_PIVOT=0 knr-bootstrap local-talos
```

What happens: kind cluster `mgmt` -> flux-operator + secrets `flux-github-pat`, `sops-age` -> FluxInstance syncing `clusters/cluster0/capi` -> cert-manager, capi-operator, providers (CAPT gets the SOPS-decrypted external kubeconfig), Cluster `cluster0` -> CAPT claims `talos-mgmt-01`, writes userData, creates the Workflow from `talos-metal` -> Smee boots the machine -> image2disk -> reboot -> Talos fetches config -> CACPPT bootstraps etcd -> CRS applies Cilium -> node Ready -> Cluster Available.

No BMC on the machine: power it on by hand once `kubectl get workflow -A` (cluster1) shows the Workflow in `STATE_PENDING`, and again after the image2disk reboot only if it does not come back on its own (UEFI boot order: disk first, PXE second, so the reboot lands on the freshly written Talos disk; Smee's proxyDHCP only answers when `allowPXE` is true, which CAPT clears after the workflow).

Watch in a second shell:

```sh
kubectl --context kind-mgmt get kustomizations -n flux-system -w
kubectl --context kind-mgmt get cluster,taloscontrolplane,tinkerbellmachine,machine -A -w
kubectl -n tinkerbell logs -f deploy/tinkerbell-smee            # on cluster1
kubectl get workflow -A -w                                       # on cluster1
```

Expected end state: `Cluster/cluster0` `Available=True`; `clusterctl --kubeconfig ~/.kube/config get kubeconfig cluster0 > ~/.kube/cluster0.yaml`; `kubectl --kubeconfig ~/.kube/cluster0.yaml get nodes` -> 1 Ready node; `kubectl --kubeconfig ~/.kube/cluster0.yaml -n kube-system get pods` shows cilium + cilium-operator Running.

Failure triage order: Smee logs (no offer -> MAC/VLAN), Workflow status (image2disk URL/compression), Tootles logs (`/2009-04-04/user-data` 200), `talosctl -n 192.168.2.31 --insecure dmesg` (maintenance mode = config never applied), CACPPT logs, CRS status (`kubectl describe clusterresourceset cluster0-cilium`).

### Task 20: Pre-seed the target before the pivot

The pivot's Phase 3 applies the CAPT provider CR in the target with no Flux there yet; CAPT must find its external kubeconfig or it starts in local mode without Tinkerbell CRDs.

```sh
KC=~/.kube/cluster0.yaml
kubectl --kubeconfig $KC create ns capt-system
sops --config sops.yaml -d clusters/cluster0/capi/capi-providers/capt-system/external-tinkerbell-kubeconfig.sops.yaml | kubectl --kubeconfig $KC apply -f -
kubectl --kubeconfig $KC apply -f clusters/cluster0/capi/clusters/management/talos-workflow-template.yaml   # only if Task 17 decided the ref is resolved locally
```

Also create the `default` namespace label expectations if any (none today).

### Task 21: Pivot (approval required)

```sh
knr-bootstrap local-talos          # BOOTSTRAP_PIVOT defaults to 1; reuses kind; runs Phases 0-6
```

Expected: cert-manager and capi-operator installed in the target, provider CRs applied, `clusterctl move` completes, FluxInstance `flux` on the target syncing `clusters/cluster0/capi`, `kubectl --kubeconfig $KC get kustomizations -n flux-system` all Ready, kind deleted. Use `PIVOT_SKIP_DELETE=1` on the first attempt to keep kind for inspection; delete it manually with `kind delete cluster --name mgmt` after Task 22 succeeds.

Verify self-management: `kubectl --kubeconfig $KC get cluster cluster0 -n default` `Available=True`; `kubectl --kubeconfig $KC -n capt-system logs deploy/capt-controller-manager | grep tinkerbellClientMode` shows `external`.

---

## Phase E: Full cluster0 workloads, state, cutover

### Task 22: Widen the FluxInstance path (one imperative bootstrap step)

```sh
kubectl --kubeconfig $KC -n flux-system patch fluxinstance flux --type merge -p '{"spec":{"sync":{"path":"clusters/cluster0"}}}'
flux --kubeconfig $KC reconcile source git flux-system -n flux-system
flux --kubeconfig $KC get kustomizations -A --watch
```

Flux then applies the committed `flux-instance.yaml` (same path, `prune: false`, pullSecret `flux-github-pat`, helm-controller feature gate). The helm release `flux` (flux-instance chart) stays as inert history; do NOT `helm uninstall` it (that deletes the FluxInstance). Optional: `kubectl -n flux-system delete secret -l name=flux,owner=helm` to drop the history only.

Expected converged set (compare with section 1 graph): `cilium` (adopts the CRS-applied resources; if Helm reports `invalid ownership metadata`, the adoption annotations from Task 7 are missing on that object: patch them and retry), `openebs` (SC `host-path` default), `cert-manager` -> `issuers` (Cloudflare DNS-01 works from the LAN), `external-secrets` -> `secretstore`, `onepassword-connect` (SOPS via `sops-age`), `gateway-api-crds` -> `agentgateway-crds` -> `agentgateway` (VIP `192.168.2.31` announced on L2), `dex`, `netbird`, `omni`, `image-factory`, `network-policies-*`, plus the CAPI Kustomizations already Ready.

### Task 23: Omni and factory state (revised 2026-09-05)

UpCloud cluster0 was found DOWN on 2026-09-05 and the hosted Omni cluster etcd snapshots cannot be used outside SaaS (section 1). State migration is replaced by:

1. Omni starts FRESH on the new cluster0: `--initial-users=jshriner@protonmail.com` recreates the admin user; service accounts (omnictl contexts, CI) are recreated by hand and their new credentials stored in 1Password.
2. ~~The Image Factory registry content is rebuilt by re-running the mirror + sign scripts~~ **DONE 2026-09-05 (new cluster0): 96/96 images mirrored + cosign-signed, 0 failures; catalog refreshed (49 upstream digests re-pinned, `siderolabs/extensions:v1.13.5` digest `sha256:6e24e59f...acc8`) + signed. Verified: `/versions` -> ["v1.13.5"], 85 catalog extensions incl. both shrinedogg customs, schematic `9aed4e47...` initramfs build 200 / 182 MB.** Scripts reused from `.tmp/mirror/` with `--kubeconfig ~/.kube/cluster0.yaml`.
3. If UpCloud comes back before Task 34 (retirement), the original PVC copy of `omni-etcd`/`omni-sqlite`/registry MAY be done instead; do not block on it.
4. Hosted Omni stays alive and untouched until Phase G completes: it is both the cluster1 control plane until the rebuild and the only consumer of the B2 etcd snapshots (SaaS-side rollback).

### Task 24: DNS and NAT cutover (approval required) — REVISED 2026-09-06 (LAN-only edge, no NetBird)

Design decision: cluster0's gateway is **LAN-only permanently**. NetBird was dropped from cluster0 (PR #452); remote admin uses the UDM's built-in VPN. No cluster0 service is ever WAN-exposed; cluster1's gateway (post-rebuild) serves only cluster1's own apps.

Done already:

1. Cloudflare A records for omni/dex/factory flipped 87.58.147.51 -> **192.168.2.31** (unproxied, TTL 300; API, 2026-09-05); `netbird.biggs.dog` A record deleted (2026-09-06). LAN devices resolve the edge; WAN cannot route private IPs.
2. cluster0 external-dns removed (PR #450); NetBird app tree + gateway listener + cert + dex OIDC client removed (PR #452). ddns suspended indefinitely (no consumers).

Deferred to Phase G (cluster1 rebuild):

3. Drop the `siderolabs/netbird` Talos extension from cluster1 node configs (management server is gone).
4. No UDM port forwards to cluster0. UDM forwards 80/443 -> cluster1 gateway VIP only if cluster1 apps need WAN; otherwise none.
5. Verify from LAN and via UDM VPN: `https://omni.biggs.dog` Dex login, `https://factory.biggs.dog/versions`.

---

## Phase F: Relocate Tinkerbell to cluster0

### Task 25: Tinkerbell stack on cluster0

Port Task 9's manifests to `clusters/cluster0/kubernetes/apps/tinkerbell/` with `publicIP: 192.168.2.31`, hostNetwork on the single node, `nodeSelector` removed. Include the Hardware CR (Task 10) with two additions so CAPT treats the already-installed machine as done without running a workflow:

```yaml
metadata:
  annotations:
    v1alpha1.tinkerbell.org/provisioned: "true"
spec:
  interfaces:
    - netboot:
        allowPXE: false
        allowWorkflow: false
```

Also include the `talos-metal` Template. Add the infra CNP. PR F1; merge; verify `kubectl --kubeconfig $KC -n tinkerbell get pods`.

### Task 26: Switch CAPT to local mode

Before this task, regenerate the Image Factory schematic so `talos.config` points at Tootles' NEW address (`http://192.168.2.31:7080/2009-04-04/user-data`; the bootstrap schematic baked `192.168.2.30:7080`, cluster1's control-01, which is wiped in Phase G). Update `talos-workflow-template.yaml` and the Hardware `installer-image` annotation with the new schematic ID (current bootstrap schematic: `3ae3a62e...87cf`, port 7080). Only matters for a future re-image of the management node; the running node never re-fetches its config.



PR F2: delete `external-tinkerbell-kubeconfig.sops.yaml` from `capt-system/kustomization.yaml` and the tree. After merge: `kubectl --kubeconfig $KC -n capt-system delete secret external-tinkerbell-kubeconfig` (Flux `prune: false` does not remove it), `kubectl -n capt-system rollout restart deploy/capt-controller-manager`, then logs show `tinkerbellClientMode=local` and `kubectl get tinkerbellmachine -A` stays `Ready`.

Check the CAPT manager Deployment tolerates the secret's absence (`config/manager/manager.yaml:57-59` volume `optional`); if the pod is stuck `ContainerCreating`, patch the provider CR `spec.deployment.containers[0]` to drop the volume mount, or keep an empty Secret.

### Task 27: Remove Tinkerbell from cluster1

PR F3: delete `clusters/cluster1/kubernetes/apps/tinkerbell/` and its sources/CNP entries; since cluster1 ks.yaml files use `prune: false` on this repo, delete the namespace manually after merge: `kubectl delete ns tinkerbell` (cluster1). cluster1 is about to be rebuilt anyway.

---

## Phase G: cluster1 Path B with retained disks

### Task 28: Inventory and backups (hard gate, produce a table before anything is wiped)

Produce `docs/cluster1-rebuild-inventory.md` with, per node: install disk, data disks (`talosctl -n <ip> disks`), what lives on each (`talosctl -n <ip> mounts`, `zpool status` via a privileged debug pod), and per PVC: storageClass, node, backing disk, backup mechanism, restore path. Commands:

```sh
kubectl get pv -o custom-columns='NAME:.metadata.name,SC:.spec.storageClassName,NS:.spec.claimRef.namespace,PVC:.spec.claimRef.name,NODE:.spec.nodeAffinity.required.nodeSelectorTerms[0].matchExpressions[0].values[0],PATH:.spec.hostPath.path,ZFS:.spec.csi.volumeAttributes.openebs\.io/poolname'
kubectl -n rook-ceph exec deploy/rook-ceph-tools -- ceph status; ceph fsid; ceph osd tree; ceph auth get client.admin
kubectl -n rook-ceph get secret rook-ceph-mon -o yaml > /secure/rook-ceph-mon.yaml
kubectl -n rook-ceph get cm rook-ceph-mon-endpoints -o yaml > /secure/rook-ceph-mon-endpoints.yaml
kubectl -n cnpg-system get backups.postgresql.cnpg.io -A ; kubectl get objectstores -A     # barman targets and last successful backup per cluster
kubectl get replicationsources -A -o wide                                                  # volsync last sync
omnictl --context self-hosted get machines; omnictl cluster template export -c biggs-dog > .omni/cluster1/omni-export/cluster-template-$(date +%F).yaml   # from hosted Omni context
```

Note (2026-09-05): the B2 cluster etcd snapshots CANNOT seed the rebuilt cluster (age-encrypted with a SaaS-held key; see section 1). etcd state is rebuilt from git + 1Password only. Hosted Omni plus its snapshots remain the rollback until the rebuild is verified.

Facts that decide the risk profile (fill in):
- Rook mon store: `dataDirHostPath` (`/var/lib/rook`) sits on each mon node's **OS disk** (Talos EPHEMERAL). A Talos reinstall of the OS disk destroys the mon store even though OSD disks survive. Mitigation: `tar` `/var/lib/rook` from each mon node with a privileged hostPath pod before the wipe and restore it to the same path on the rebuilt node before the rook operator starts (Rook "Adopt an existing Rook Ceph cluster into a new Kubernetes cluster" procedure: same `fsid`, `rook-ceph-mon` secret, `rook-ceph-mon-endpoints`, mon data dirs). If the tar is unavailable, the fallback is the Rook "restore mon quorum from OSDs" procedure (`ceph-objectstore-tool` rebuild), which is slow and manual.
- ZFS `tank`: which disks (per node) and whether the siderolabs/zfs extension auto-imports on boot (verify with `talosctl -n <node> services ext-zfs-service` logs after rebuild; else `zpool import -f tank` from a privileged pod). openebs zfs-localpv PVs bind by node hostname + pool name, so hostnames must be preserved (they are, via the per-machine ConfigPatches in the exported template).
- openebs `host-path` (`/var/mnt/host-path`) on nv-01 and any other node: on the OS disk unless a `UserVolumeConfig` places it on a data disk. If OS-disk resident, these PVCs are **lost**: enumerate them (vLLM model cache, Steam `/home/retro` 250Gi, `nvngx-cache`, kagent/substrate data, mindwtr) and decide per PVC: volsync restore, re-download, or accept loss. Get user sign-off on that list.
- CNPG clusters run on openebs (node-local): restore from barman object store via `bootstrap.recovery` in each `Cluster` CR (temporary git change), then flip back.
- Media on ZFS (`media-zfs-pv`) and NFS server data: survive with the pool.

Gate: user approves the inventory table and the per-PVC decisions.

### Task 29: Omni cluster definition for the new cluster1

- Start from `.omni/cluster1/omni-export/cluster-template.yaml`. Keep machine UUIDs (hardware UUIDs are stable across reinstall), hostnames, per-machine patches (bond0, NIC rings, nvidia runtime, uinput, `/var/mnt/host-path` mount, user namespaces), the `coredns-custom` inline manifest, `cni: none` + `proxy.disabled` (Cilium comes from Flux via the `cilium` HelmRelease on first sync: Omni supports "Cilium via inline manifests" or you reuse the Task 7 CRS-style rendered manifest as an Omni `cluster.inlineManifests` ConfigPatch with the same Helm adoption metadata; choose the inline-manifest path since there is no CAPI on cluster1).
- Set `talos.version: v1.13.5` (decision: keep the existing extension set incl. the mirrored nvidia-open catalog; upgrade later through Omni), `kubernetes.version: v1.36.2`.
- Talos `machine.install.wipe: false` (default) so only the STATE/EPHEMERAL partitions of the install disk are reformatted; data disks are untouched.
- Store as `.omni/cluster1/rebuild/cluster-template.yaml` (git-ignored dir; also copy to 1Password Document `cluster1-omni-template` for durability).

### Task 30: Rebuild cluster1 (approval required per node group)

1. Backups from Task 28 verified restorable (spot-check one barman backup with `barman-cloud-restore --dry-run`, one volsync snapshot listing).
2. Scale down write-heavy workloads (CNPG clusters to hibernation, media apps) to quiesce ZFS and Ceph; `ceph osd set noout`.
3. Tar `/var/lib/rook` from mon nodes (Task 28 mitigation).
4. In hosted Omni: destroy the `biggs-dog` cluster (this runs `talosctl reset` on each node: wipes STATE + EPHEMERAL of the install disk only; confirm in the Omni UI that "wipe user disks" is not selected).
5. Each node PXE-boots via cluster0's Smee. Hardware CRs for the six cluster1 nodes on cluster0 (PR G1) with `netboot.ipxe.url` pointing at the self-hosted factory PXE endpoint for the Omni-generated schematic (Omni UI: Download Installation Media -> PXE boot URL; it embeds the siderolink join args). Nodes appear in self-hosted Omni as unallocated machines.
6. `omnictl cluster template sync -f .omni/cluster1/rebuild/cluster-template.yaml`; watch `omnictl cluster status biggs-dog`.
7. Seed Flux on cluster1 (same sequence knr-bootstrap uses, by hand): install flux-operator chart, create `flux-system` pull secret (username/PAT) and `sops-age` (biggs.dog key), apply `clusters/cluster1/flux-system/flux-operator/app/flux-instance.yaml`. Let Flux converge.
8. Storage re-adoption, in order: ZFS import check -> Rook adoption (restore mon dirs, `rook-ceph-mon` secret, `rook-ceph-mon-endpoints` before enabling the `rook-ceph-cluster` Kustomization; keep `cleanupPolicy.wipeDevicesFromOtherClusters` unset) -> `ceph osd unset noout`, `ceph status` HEALTH_OK with all OSDs `up/in` and PGs `active+clean` -> CNPG recovery -> volsync restores -> re-download-only data.
9. Gate: every cluster1 Kustomization Ready; smoke test Emby playback (ZFS), Pocket ID login (CNPG), a Matrix message (Ceph), one Dreamcast session (GPU + host-path).

---

## Phase H: Cleanup, docs, upstream

### Task 31: Renovate coverage in biggs.dog

Add regex custom managers in `renovate.json` for: CAPI operator `spec.version` in `capi-providers/*/provider*.yaml` (github-releases datasources: `kubernetes-sigs/cluster-api`, `sidero-community/cluster-api-bootstrap-provider-talos`, `sidero-community/cluster-api-control-plane-provider-talos`, `shrinedogg/cluster-api-provider-tinkerbell`), `talosVersion`/image version in `cluster.yaml` and the workflow template (`siderolabs/talos`), `bootstrap.toml` chart pins (keep equal to the HelmReleases; group them under one `groupName: capi-bootstrap`), Tinkerbell chart tag. Dry-run per knr-ops AGENTS.md guidance before merging.

### Task 32: knr-ops upstream PRs (polarsquad), one logical change each, pause between

1. `docs/extending.md` + `mgmt/local-talos/clusters/management/`: add the Talos `Template` and `templateOverrideRef`/`templateOverride` on `TinkerbellCluster`, with the finding that CAPT's default template cannot install Talos. Reference issue #105/#156.
2. Optional `bootstrap-sync-path` (kind-only sync path) in `[environments.<env>]` so a consumer repo does not need the Task 22 patch; default = `sync-path`. Include config tests and AGENTS.md.
3. `docs/operations.md`: CAPT external-Tinkerbell secret must exist in the target before pivot Phase 3 (Task 20 finding), and the acceptance-run notes for #105.
4. Pin the two Tinkerbell action images in the example template.

Also re-point CAPT to upstream once tinkerbell#604 is released; keep the fork pin until then.

### Task 33: biggs.dog docs

- `README.md`: cluster0 becomes "on-prem single-node Talos management cluster (CAPI self-managed)", node row for the new machine, remove UpCloud references; Repository Structure gains `clusters/cluster0/capi/`.
- `AGENTS.md`: describe `capi/` (knr-ops component layout inside this repo), `bootstrap.toml`, and the rule that `capi/` must stay a valid standalone Flux root.
- `docs/NOTES.md`: migration record (dates, commit SHAs, Task 17 bench results, Rook adoption steps taken, PVCs lost/restored), the Task 22 one-time path patch, the `flux` helm release history note.
- Update `.omni/omni-and-factory-implementation.md` status table.

### Task 34: Retire UpCloud

After 7 days of stable operation: export a final `kubectl get all -A` and PVC tarballs from UpCloud to cold storage, delete the UpCloud server and block storage, remove any UpCloud-specific files (`.omni/cluster0/init-vm.sh`, `cluster0-plan.md` move to `docs/history/`), revoke the UpCloud-era 1Password Connect token if it was distinct.

---

## 9. Risks and tradeoffs

| Risk | Impact | Mitigation |
|---|---|---|
| Talos workflow template untested with CAPT (never run upstream) | Phase D stalls at machine provisioning | Phase C bench test is a hard gate; CAPT template precedence verified in source |
| `templateOverrideRef` resolved by the wrong client (local vs external) | CAPT cannot find the Template | Task 17 step 6 decides ref vs inline |
| image2disk compression support for `.zst` | Workflow fails | Fall back to `.raw.xz`; verify in Phase C |
| CAPT pod cannot start without the external kubeconfig in the pivot target | `clusterctl move` waits on providers | Task 20 pre-seed; PR F2 checks `optional` volume |
| Cilium adoption by Helm fails (ownership metadata) | Cilium HelmRelease stuck | Adoption labels/annotations rendered into the CRS (Task 7); patch missing objects manually |
| One VIP shared across TCP+UDP LB Services via Cilium sharing-key | Omni SideroLink or STUN unreachable | Fall back to `externalIPs` on the node IP (current pattern) |
| Public exposure now depends on home WAN + UDM NAT | Omni/NetBird down when WAN IP changes | cloudflare-ddns CronJob keeps `home.biggs.dog` current; external-dns CNAMEs point at it (Task 14b) |
| Rook mon store lives on the OS disk | Ceph data unreachable after rebuild despite intact OSDs | Tar `/var/lib/rook` before wipe (Task 30 step 3); documented fallback rebuild from OSDs |
| openebs host-path PVCs on the OS disk | Data loss (vLLM cache, Steam library, kagent/substrate state) | Task 28 per-PVC decision list with user sign-off; volsync where it exists |
| Hosted Omni destroy wipes more than the install disk | Data loss on data disks | Confirm reset scope in Omni UI; `talosctl reset --system-labels-to-wipe STATE,EPHEMERAL` semantics; keep `install.wipe: false` |
| Single node runs CAPI + Flux + Omni + NetBird + Dex + gateway | Resource pressure | Size the machine >= 8 vCPU / 32 GB; Omni requests 1Gi/limits 4Gi today |
| UpCloud freeze (Task 1) leaves UpCloud without reconciliation for weeks | Cert renewals still run (cert-manager is a controller); ExternalSecrets still refresh | Acceptable; UpCloud is retired in Task 34 |
| Double-apply pattern (root autodetect + component Kustomizations) with `prune: false` | Deleted files linger on the cluster | Existing biggs.dog behavior; manual deletes noted per task |

## 10. Open questions

All five original questions were answered on 2026-09-05 and folded into section 0 (WAN DNS via external-dns + ddns CNAME; cluster1 stays on Talos v1.13.5; SideroLink LAN-only; management node MAC/IP/disk/NIC known, no BMC; prune: true under capi/). Remaining items to confirm during execution, not blockers:

1. Cloudflare API token scope: the cert-manager token must carry Zone:DNS:Edit for external-dns and cloudflare-ddns to write records (Task 14b). If it is DNS-01 only (Zone:Read + DNS:Edit is required for DNS-01 too, so it should be fine), create a second token item.
2. cluster1 pod/service CIDRs, to keep cluster0's distinct (Task 6 note).
3. Whether the target machine's UEFI supports "disk first, PXE second" ordering plus HookOS handoff (Phase B gate exercises this).
4. Whether the `image2disk` action accepts `.raw.zst` (Phase C).

## 11. Files likely to change (summary)

biggs.dog:
- New: `bootstrap.toml`; `clusters/cluster0/capi/**` (sources, infrastructure, capi-providers incl. one `.sops.yaml`, clusters/management incl. `cluster.yaml`, `cilium-crs.yaml`, `cilium-values.yaml`, `check-cilium-crs.sh`, `talos-workflow-template.yaml`); `clusters/cluster0/kubernetes/apps/openebs/**`; `clusters/cluster0/kubernetes/apps/network-policies/policies/infra/capi.yaml`; `clusters/cluster0/kubernetes/apps/networking/{external-dns,ddns}/**`; `clusters/cluster0/flux-system/sources/external-dns-repo.yaml`; `clusters/cluster0/kubernetes/apps/tinkerbell/**` (Phase F); `clusters/cluster1/kubernetes/apps/tinkerbell/**` (Phase B, removed in Phase F); `docs/cluster1-rebuild-inventory.md`.
- Modified: `clusters/cluster0/flux-system/flux-operator/app/flux-instance.yaml`, `flux-system/sources/{kustomization.yaml,flux-system-git.yaml}`, `kubernetes/apps/cert-manager/cert-manager/ks.yaml`, `kubernetes/apps/kube-system/cilium/app/helmrelease.yaml`, `kubernetes/apps/networking/agentgateway/app/cilium-lb-ip-pool.yaml`, `kubernetes/apps/omni/omni/app/{deployment.yaml,siderolink-service.yaml,ks.yaml}`, `kubernetes/apps/omni/image-factory/ks.yaml`, `kubernetes/apps/netbird/netbird/{ks.yaml,app/services.yaml,app/server-deployment.yaml}`, `clusters/cluster1/kubernetes/apps/networking/lan-dns/app/*`, `sops.yaml`, `renovate.json`, `README.md`, `AGENTS.md`, `docs/NOTES.md`.

knr-ops (upstream PRs, Task 32): `docs/extending.md`, `docs/operations.md`, `mgmt/local-talos/clusters/management/*`, optionally `bootstrap-rs/src/config.rs` + `main.rs` + `bootstrap.toml` + `AGENTS.md`.

## 12. Validation summary

- Repo: `kubectl kustomize` on every touched root; Python multi-doc parse; `check-cilium-crs.sh` diff clean; `sops -d` round-trip on the new `.sops.yaml`; `knr-bootstrap` config parse (Task 13).
- Phase B gate: Smee proxy offer + iPXE fetch for `24:4b:fe:5c:d9:4a`.
- Phase C gate: Talos installed by the template twice; `talos.config` fetched from Tootles.
- Phase D gate: Cluster `Available`, node Ready with Cilium, pivot complete, CAPT `external` mode.
- Phase E gate: all cluster0 Kustomizations Ready; Omni login via Dex; NetBird clients connected; certs valid.
- Phase F gate: CAPT `local` mode, TinkerbellMachine Ready.
- Phase G gate: Ceph HEALTH_OK, ZFS imported, CNPG clusters healthy from recovery, all cluster1 Kustomizations Ready, smoke tests.
