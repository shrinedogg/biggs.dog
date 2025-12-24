# Biggs was my dog.
He was the best boy and when I found out I could buy a domain with .dog as the extension, I migrated my homelab services to biggs.dog to honor him.

# What is this?
This is a mono repository for my home infrastructure and Kubernetes cluster. I try to adhere to Infrastructure as Code (IaC) and GitOps practices.

## design choices

I made some hard choices based on my environment that may not appeal to you or your use-case.

My NAS is an Ubuntu bare-metal host that besides a ZFS pool also hosts my k3s control plane (`control-01`); I do this because I host pods on my control plane related to media management and downloading. This is to avoid downloading directly to the HDDs in my ZFS pool, but instead download to the node's local SSD as a temporary location and move downloaded/extracted files via local disk transfer to the ZFS pool instead of using my limited 1Gbps networking equipment. This introduces stickiness, but the goal of this particular cluster is not to provide these applications with some absurd availablity completely decoupled from the hose, but rather to clusterize and codify a bunch of homelab services that otherwise would be difficult to manage. If my NAS is down, the media pods aren't worth much, so this is stickiness I can live with for these services at this time.

## hardware assumptions/prereqs

These values here are configurable and listed in our next section, and the hardware preferences are my own.

1) You are deploying only one control node for k3s with the hostname of `control-01`
2) You have an NFS share at IP of `192.168.2.30` and/or `192.168.2.32`
3) You have 3 worker nodes with the hostnames `worker-01`, `worker-02`, `worker-03`.
	a) Two of these worker nodes (1 & 2 specifically) should have Intel iGPUs for hardware accelleration of the `jellyfin` & `ersatztv` media workloads.
4)  Each node in the cluster has atleast 512GB+ in local SSD on the root drive. NVME drives atleast PCI-E 3.0 or above in XFS format preferred.
	a) The default storageclass used for this cluster is the `local-path` type found as part of the k3s package.
5) IPs used for `metallb-system` are resources that use MetalLB to create its L2 `loadbalancer` resources in your cluster's services.

### hardcoded resources/values?

Yes, unforunately there are a few of which to be aware at the time of writing this.

- Search the repo for `kubernetes.io/hostname: control-01` to edit the main control node hostname value where it's used.
- Search the repo for `kubernetes.io/hostname: worker-0*` to edit the worker node hostname values where they are used.
- Search the repo for `provisioner: external-nfs` to edit the IP value of your NFS share available to kubernetes.
- Search the repo for `kind: IPAddressPool` resources in the repo to your desired value.
- Search the repo for `vaults:` and edit the vault name to that of your existing 1password vault.
- Search the repo for `- host:` to edit ingress host values to match your existing host.

# Setup

First, you'll need Kubernetes.

### to install k3s

From what you intend to be your k3s main control node:

`curl -sfL https://get.k3s.io | sh -s server --disable servicelb --disable traefik`

Note: the value for your `K3S_TOKEN` can be found at `/var/lib/rancher/k3s/server/node-token` on the control node.

From what you inted to be your k3s worker nodes:
`curl -sfL https://get.k3s.io | K3S_URL=https://<controlnodeIP>:6443 K3S_TOKEN=<yourvalue> sh -`


### to bootstrap with flux

```
flux bootstrap github  
--token-auth  
--owner=<your_value>
--repository=<your_value> 
--branch=main  
--path=clusters/k3s/flux-system  
--personal
```
 
