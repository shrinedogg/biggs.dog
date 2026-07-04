#!/usr/bin/env bash
# clusters/cluster1/init-vm.sh
# First-boot bootstrap for the UpCloud VM (Ubuntu).
# Idempotent — safe to re-run. No hardcoded secrets; reads runtime inputs from env.
#
# Required env vars:
#   FLUX_GITHUB_TOKEN          — GitHub PAT for Flux git auth
#   ONEPASSWORD_CREDENTIALS_JSON — 1Password Connect server credentials blob
#   ONEPASSWORD_CONNECT_TOKEN    — 1Password Connect access token
#
# Usage:  sudo bash init-vm.sh

set -Eeuo pipefail

LOG="/var/log/cluster1-init.log"
REPO_URL="https://github.com/shrinedogg/biggs.dog.git"
REPO_DIR="/opt/biggs.dog"
BRANCH="main"

# ── Logging ──────────────────────────────────────────────────────────────────
exec > >(tee -a "$LOG") 2>&1
set -x

log() { set +x; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; set -x; }
section() { log "=== $* ===" }

# ── 1. Dependencies ──────────────────────────────────────────────────────────
section "Installing dependencies"
apt-get update -qq
apt-get install -y --no-install-recommends ca-certificates curl openssl gnupg ufw jq

# ── 2. k3s ───────────────────────────────────────────────────────────────────
section "Installing k3s (bundled Traefik + Klipper; metrics-server disabled)"
if command -v k3s &>/dev/null; then
    log "k3s already installed, skipping"
else
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--disable=metrics-server" sh -s -
fi

export KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

log "Waiting for node to be Ready..."
for i in $(seq 1 60); do
    if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
        log "Node Ready"
        break
    fi
    sleep 5
done

if ! kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
    log "ERROR: Node did not become Ready in time"
    exit 1
fi

# ── 3. Host firewall (ufw) ──────────────────────────────────────────────────
section "Configuring UFW"
if ufw status 2>/dev/null | grep -q "Status: active"; then
    log "UFW already active"
else
    ufw --force enable
fi

# Only add rules if missing (idempotent)
for rule in \
    "22/tcp" \
    "80/tcp" \
    "443/tcp" \
    "8090/tcp" \
    "8091/tcp" \
    "8100/tcp" \
    "50180/udp" \
    "3478/udp"; do
    if ! ufw status | grep -q "$rule"; then
        ufw allow "$rule"
        log "Allowed $rule"
    fi
done

# ── 4. /dev/net/tun (Omni WireGuard) ────────────────────────────────────────
section "Creating /dev/net/tun"
mkdir -p /dev/net
if [ ! -c /dev/net/tun ]; then
    mknod /dev/net/tun c 10 200
    chmod 600 /dev/net/tun
    log "Created /dev/net/tun"
else
    log "/dev/net/tun already exists"
fi

# ── 5. Clone repo ────────────────────────────────────────────────────────────
section "Cloning repo"
if [ -d "$REPO_DIR/.git" ]; then
    log "Repo already cloned, pulling latest"
    cd "$REPO_DIR"
    git pull origin "$BRANCH"
else
    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
    cd "$REPO_DIR"
fi

# ── 6. Bootstrap secrets ─────────────────────────────────────────────────────
section "Creating bootstrap secrets"

# Validate required env vars
for var in FLUX_GITHUB_TOKEN ONEPASSWORD_CREDENTIALS_JSON ONEPASSWORD_CONNECT_TOKEN; do
    if [ -z "${!var:-}" ]; then
        log "ERROR: $var is not set"
        exit 1
    fi
done

# Pre-create namespaces so secrets have a home
kubectl create namespace flux-system --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -

# Flux pull secret
log "Creating flux-system secret"
kubectl -n flux-system create secret generic flux-system \
    --from-literal=username=shrinedogg \
    --from-literal=password="$FLUX_GITHUB_TOKEN" \
    --type=Opaque --dry-run=client -o yaml | kubectl apply -f -

# 1Password Connect credentials
log "Creating onepassword-connect-secret"
kubectl -n external-secrets create secret generic onepassword-connect-secret \
    --from-literal=1password-credentials.json="$ONEPASSWORD_CREDENTIALS_JSON" \
    --dry-run=client -o yaml | kubectl apply -f -

log "Creating onepassword-connect-token"
kubectl -n external-secrets create secret generic onepassword-connect-token \
    --from-literal=token="$ONEPASSWORD_CONNECT_TOKEN" \
    --dry-run=client -o yaml | kubectl apply -f -

# ── 7. Flux Operator ────────────────────────────────────────────────────────
section "Installing Flux Operator"
if kubectl get crd fluxinstances.fluxcd.controlplane.io &>/dev/null; then
    log "Flux Operator already installed"
else
    kubectl apply --kustomize ghcr.io/controlplaneio-fluxcd/kustomize-config/flux-operator:main
    log "Waiting for Flux Operator to be Ready..."
    for i in $(seq 1 60); do
        if kubectl get deployment flux-operator-controller -n flux-system -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '1'; then
            log "Flux Operator Ready"
            break
        fi
        sleep 5
    done
fi

# ── 8. Apply flux-system manifests ──────────────────────────────────────────
section "Applying flux-system manifests"
kubectl apply -k "$REPO_DIR/clusters/cluster1/flux-system"

# ── 9. Wait for Flux to reconcile ────────────────────────────────────────────
section "Waiting for Flux to reconcile"
log "Waiting for GitRepository/flux-system..."
for i in $(seq 1 120); do
    if kubectl get gitrepository flux-system -n flux-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q "True"; then
        log "GitRepository Ready"
        break
    fi
    sleep 5
done

log "Waiting for Kustomization/repositories..."
for i in $(seq 1 120); do
    READY=$(kubectl get kustomizations -n flux-system -o jsonpath='{range .items[*]{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{"\n"}}' 2>/dev/null | grep -c " True" || true)
    TOTAL=$(kubectl get kustomizations -n flux-system --no-headers 2>/dev/null | wc -l || echo 0)
    if [ "$READY" -ge "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
        log "All Kustomizations Ready ($READY/$TOTAL)"
        break
    fi
    sleep 5
done

# ── 10. Print next steps ────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "<YOUR_VM_IP>")

cat <<EOF

===============================================================================
  Bootstrap complete. Next steps:
===============================================================================

  VM Public IP: $PUBLIC_IP

  1. DNS records (Cloudflare, grey cloud / DNS-only):
     omni.biggs.dog     A  $PUBLIC_IP
     netbird.biggs.dog  A  $PUBLIC_IP
     dex.biggs.dog      A  $PUBLIC_IP

  2. 1Password items to create (biggs-dog vault):
     - dex-admin-password          (property: hash — bcrypt)
     - dex-omni-client-secret      (property: secret)
     - dex-netbird-client-secret   (property: secret)
     - omni-etcd-key               (property: key — GPG private key armor)
     - netbird-datastore-encryption-key
     - netbird-relay-secret

  3. Manual post-boot tasks:
     a. Omni: accept EULA + create service account
        (login at https://omni.biggs.dog after cert issues)
     b. NetBird: /setup admin user + add Dex as Generic OIDC provider
        (login at https://netbird.biggs.dog after cert issues)

  4. Validate:
     - kubectl get nodes
     - flux get kustomizations -A
     - curl https://dex.biggs.dog/.well-known/openid-configuration

===============================================================================
EOF

log "Bootstrap complete"
