#!/bin/bash
# -----------------------------------------------------------------------------
# Update members.config to use Docker network IPs instead of localhost
# -----------------------------------------------------------------------------
set -euo pipefail

echo "🔧 Creating/updating members.config with Docker network IPs..."

MEMBER1_IP=$(docker inspect member1-control-plane 2>/dev/null | jq -r '.[0].NetworkSettings.Networks.kind.IPAddress' 2>/dev/null || echo "")
MEMBER2_IP=$(docker inspect member2-control-plane 2>/dev/null | jq -r '.[0].NetworkSettings.Networks.kind.IPAddress' 2>/dev/null || echo "")

if [ -z "$MEMBER1_IP" ] || [ -z "$MEMBER2_IP" ]; then
    echo "⚠️  Could not get cluster IPs"
    exit 1
fi

# Export kubeconfigs from kind
kind get kubeconfig --name member1 > /tmp/member1_temp.yaml
kind get kubeconfig --name member2 > /tmp/member2_temp.yaml

# Merge the configs using kubectl (avoids PyYAML dependency) and update IPs
mkdir -p "$HOME/.kube"
KUBECONFIG="/tmp/member1_temp.yaml:/tmp/member2_temp.yaml" kubectl config view --flatten > "$HOME/.kube/members.config"

# Update server endpoints to Docker network IPs
kubectl --kubeconfig="$HOME/.kube/members.config" config set-cluster kind-member1 --server="https://${MEMBER1_IP}:6443"
kubectl --kubeconfig="$HOME/.kube/members.config" config set-cluster kind-member2 --server="https://${MEMBER2_IP}:6443"

# Rename contexts to simpler names (ignore if already renamed)
kubectl --kubeconfig="$HOME/.kube/members.config" config rename-context kind-member1 member1 2>/dev/null || true
kubectl --kubeconfig="$HOME/.kube/members.config" config rename-context kind-member2 member2 2>/dev/null || true

echo "✅ Created members.config with updated endpoints"

echo "✅ members.config created/updated:"
echo "   member1: https://${MEMBER1_IP}:6443"
echo "   member2: https://${MEMBER2_IP}:6443"

# Cleanup temp files
rm /tmp/member1_temp.yaml /tmp/member2_temp.yaml

