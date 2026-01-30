# 🐕 biggs.dog

> Biggs was my dog. He was the best boy and when I found out I could buy a domain with `.dog` as the extension, I migrated my homelab services to biggs.dog to honor him.

## 📖 Overview

This is a mono repository for my home infrastructure and Kubernetes cluster, following Infrastructure as Code (IaC) and GitOps practices using [Flux](https://fluxcd.io/).

## 🏗️ Architecture

### GitOps with Flux

The cluster is managed by [Flux Operator](https://fluxcd.controlplane.io/operator/) syncing from the `main` branch of this repository. Flux components include:
- Source Controller
- Kustomize Controller
- Helm Controller
- Notification Controller

### Repository Structure

```
clusters/
└── cluster0/
    ├── flux-system/          # Flux instance and Helm/OCI sources
    │   ├── flux-instance.yaml
    │   └── sources/          # HelmRepository and OCIRepository definitions
    └── kubernetes/
        └── apps/             # Application deployments
            ├── cert-manager/
            ├── cnpg/
            ├── external-secrets/
            ├── biggs/
            ├── kube-system/
            ├── media/
            ├── networking/
            ├── observability/
            ├── openebs/
            ├── renovate/
            └── rook-ceph/
```

## 🔧 Core Components

### Networking
| Component | Description |
|-----------|-------------|
| [Cilium](https://cilium.io/) | CNI with BGP support for LoadBalancer IP advertisement |
| [k8s-gateway](https://github.com/ori-edge/k8s_gateway) | DNS for Kubernetes services |
| [Gateway API](https://gateway-api.sigs.k8s.io/) | Kubernetes ingress using Gateway API |
| [AgentGateway](https://github.com/kgateway-dev/kgateway) | Gateway API implementation installed from OCI charts |

### Storage
| Component | Description |
|-----------|-------------|
| [Rook-Ceph](https://rook.io/) | Distributed storage cluster |
| [OpenEBS](https://openebs.io/) | Container attached storage |
| [Volsync](https://volsync.readthedocs.io/) | Backup and replication of persistent volumes |
| [Snapshot Controller](https://github.com/kubernetes-csi/external-snapshotter) | CSI volume snapshots |
| NFS CSI Driver | NFS storage provisioner |
| ZFS | ZFS volume management |

### Database
| Component | Description |
|-----------|-------------|
| [CloudNativePG](https://cloudnative-pg.io/) | PostgreSQL operator for in-cluster databases |

### Security & Secrets
| Component | Description |
|-----------|-------------|
| [cert-manager](https://cert-manager.io/) | Certificate management with CA and ACME issuers |
| [External Secrets](https://external-secrets.io/) | Sync secrets from external providers |
| [1Password Connect](https://developer.1password.com/docs/connect/) | Secret backend for External Secrets |
| [SOPS](https://github.com/getsops/sops) | Encrypted secrets (age key) |

### Observability
| Component | Description |
|-----------|-------------|
| [Victoria Metrics](https://victoriametrics.com/) | Metrics storage and monitoring |
| [Victoria Logs](https://docs.victoriametrics.com/victorialogs/) | Log aggregation |
| [Grafana Operator](https://grafana.github.io/grafana-operator/) | Grafana deployment and dashboard management |

### System
| Component | Description |
|-----------|-------------|
| [Node Feature Discovery](https://kubernetes-sigs.github.io/node-feature-discovery/) | Hardware feature detection |
| Intel GPU Plugin | Intel GPU device plugin for hardware acceleration |

### Automation
| Component | Description |
|-----------|-------------|
| [Renovate](https://docs.renovatebot.com/) | Automated dependency updates (HelmRelease chart versions + container images) |

## 📺 Applications

### Media Stack
- **Emby** - Media server
- **Booklore** - Book management
- **Ersatz** - Custom media service
- **Nsyncd** - Synchronization service

### Other
- **biggs** - Personal application

## 🌐 Networking Configuration

### BGP Peering
The cluster uses Cilium BGP to peer with the network router (UDM) for LoadBalancer IP advertisement:
- **Cluster ASN:**
- **Router ASN:**
- **Peer Address:**
- **LoadBalancer IP Pool:**

## 🔐 Secret Management

Secrets are managed using:
1. **SOPS with age encryption** - For secrets stored in Git
2. **External Secrets + 1Password** - For runtime secret injection from 1Password vaults

## 🚀 Getting Started

### Prerequisites
- Kubernetes cluster
- [Flux CLI](https://fluxcd.io/flux/cmd/)
- [SOPS](https://github.com/getsops/sops) with age key for decryption
- 1Password Connect credentials

### Bootstrap

The cluster bootstraps via Flux Operator syncing from:
```
https://github.com/shrinedogg/biggs.dog.git
```

Flux will automatically reconcile the cluster state based on the manifests in `clusters/cluster0/`.

## 🔁 Dependency Updates

Dependency updates are managed by Renovate using the repository config in `renovate.json`.
It is set up to update Flux `HelmRelease` chart versions (HelmRepository and OCI-based sources) and container images referenced in Kubernetes manifests, including the media stack under `clusters/cluster0/kubernetes/apps/media/`.

## 📁 App Structure Pattern

Each application follows a consistent pattern:
```
<namespace>/
├── kustomization.yaml    # Namespace-level kustomization
├── namespace.yaml        # Namespace definition
└── <app>/
    ├── ks.yaml           # Flux Kustomization
    └── app/
        ├── kustomization.yaml
        └── helmrelease.yaml (or raw manifests)
```

## 📝 License

Personal homelab configuration - feel free to use as reference.
