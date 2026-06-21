#!/bin/bash
echo "=== Agent toolNames ==="
for agent in cilium-debug-agent cilium-policy-agent vm-agent helm-agent k8s-agent observability-agent promql-agent flux-agent cilium-manager-agent; do
  tools=$(kubectl get agent "$agent" -n ai-system -o jsonpath='{.spec.declarative.tools[0].mcpServer.toolNames}' 2>/dev/null || echo "GET_FAILED")
  echo "$agent: $tools"
done

echo ""
echo "=== Agent Status Conditions ==="
for agent in cilium-debug-agent cilium-policy-agent vm-agent helm-agent k8s-agent observability-agent promql-agent flux-agent cilium-manager-agent; do
  status=$(kubectl get agent "$agent" -n ai-system -o jsonpath='{.status.conditions[0]}' 2>/dev/null || echo "GET_FAILED")
  echo "$agent: $status"
done

echo ""
echo "=== Pod Status ==="
kubectl get pods -n ai-system -o wide 2>/dev/null
