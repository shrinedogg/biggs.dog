#!/usr/bin/env bash
# Regenerate the Cilium ClusterResourceSet ConfigMap from the committed
# HelmRelease values and diff it against the checked-in copy. Run after any
# change to clusters/cluster0/kubernetes/apps/kube-system/cilium (version or
# values). Exit 1 when the checked-in copy is stale.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

VALUES=clusters/cluster0/kubernetes/apps/kube-system/cilium/app/helmrelease.yaml
CRS=clusters/cluster0/capi/clusters/management/cilium-crs.yaml
VERSION=$(yq '.spec.chart.spec.version' "$VALUES" | tr -d 'v')

TMP_VALS=$(mktemp) TMP_RENDER=$(mktemp) TMP_CM=$(mktemp)
trap 'rm -f "$TMP_VALS" "$TMP_RENDER" "$TMP_CM"' EXIT

yq '.spec.values' "$VALUES" > "$TMP_VALS"
helm template cilium cilium/cilium --version "$VERSION" -n kube-system -f "$TMP_VALS" \
  | yq '(.metadata.labels."app.kubernetes.io/managed-by") = "Helm"
      | (.metadata.annotations."meta.helm.sh/release-name") = "cilium"
      | (.metadata.annotations."meta.helm.sh/release-namespace") = "kube-system"' \
  > "$TMP_RENDER"
kubectl create configmap cluster0-cilium -n default \
  --from-file=cilium.yaml="$TMP_RENDER" --dry-run=client -o yaml > "$TMP_CM"

# Compare the ConfigMap body (everything between the leading '---' and the
# ClusterResourceSet document) with the checked-in copy.
awk '/^---$/{n++} n==1' "$CRS" | tail -n +2 > /tmp/crs-current.yaml
diff -u /tmp/crs-current.yaml "$TMP_CM"
