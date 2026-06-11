#!/bin/bash

# Script para criar clusters KIND para modo Real
# Cria clusters reais usando KIND ao invés de KWOK

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================${NC}"
echo -e "${BLUE}  Create KIND Clusters (Real Mode)${NC}"
echo -e "${BLUE}==============================${NC}"
echo ""

# Check if kind is installed
if ! command -v kind &> /dev/null; then
    echo -e "${RED}❌ kind is not installed${NC}"
    echo -e "${YELLOW}Installing kind...${NC}"
    
    # Detect OS
    OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
    ARCH="$(uname -m)"
    
    # Download kind
    KIND_VERSION="v0.20.0"
    curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-${OS}-${ARCH}
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
fi

echo -e "${GREEN}✅ kind is installed: $(kind --version)${NC}"
echo ""

# Node image arch-aware (ppc64le não tem kindest/node oficial -> imagem da comunidade Power).
# Normalmente herdada do main.sh; fallback aqui para execução standalone.
if [ -z "${KIND_NODE_IMAGE:-}" ]; then
    if [ "$(uname -m)" = "ppc64le" ]; then
        KIND_NODE_IMAGE="quay.io/powercloud/kind-node:v1.31.14"
    else
        KIND_NODE_IMAGE="kindest/node:v1.31.2"
    fi
fi
echo -e "${BLUE}🖼️  Using kind node image: ${KIND_NODE_IMAGE}${NC}"

# Read node count from config.yaml
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/../simulator/data/config.yaml"
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}❌ Config file not found: $CONFIG_FILE${NC}"
    exit 1
fi

# Parse node counts from config.yaml
MEMBER1_NODES=$(grep -A 4 "member1:" "$CONFIG_FILE" | grep "nodes:" | awk '{print $2}')
MEMBER2_NODES=$(grep -A 4 "member2:" "$CONFIG_FILE" | grep "nodes:" | awk '{print $2}')

# Default to 3 workers if not found
MEMBER1_WORKERS=${MEMBER1_NODES:-3}
MEMBER2_WORKERS=${MEMBER2_NODES:-3}

echo -e "${BLUE}📋 Configuration from config.yaml:${NC}"
echo -e "   Member1: 1 control-plane + ${MEMBER1_WORKERS} workers = $((1 + MEMBER1_WORKERS)) total nodes"
echo -e "   Member2: 1 control-plane + ${MEMBER2_WORKERS} workers = $((1 + MEMBER2_WORKERS)) total nodes"
echo ""

# Clean up any orphaned Docker containers
echo -e "${YELLOW}🧹 Cleaning up orphaned containers...${NC}"
docker rm -f $(docker ps -aq -f "name=member") 2>/dev/null || true

# Check if clusters already exist
if kind get clusters | grep -q "member1"; then
    echo -e "${GREEN}✓ Cluster 'member1' already exists${NC}"
    MEMBER1_NEEDS_CREATE=false
else
    echo -e "${YELLOW}  Cluster 'member1' does not exist - will create with Karmada config${NC}"
    MEMBER1_NEEDS_CREATE=true
fi

if kind get clusters | grep -q "member2"; then
    echo -e "${GREEN}✓ Cluster 'member2' already exists${NC}"
    MEMBER2_NEEDS_CREATE=false
else
    echo -e "${YELLOW}  Cluster 'member2' does not exist - will create with Karmada config${NC}"
    MEMBER2_NEEDS_CREATE=true
fi

echo ""

# Create member1 cluster using Karmada config
if [ "$MEMBER1_NEEDS_CREATE" = true ]; then
    echo -e "${BLUE}[1/2] Creating member1 cluster (private) with ${MEMBER1_WORKERS} workers...${NC}"

    # Check if Karmada config exists, if so, use it (it already has workers now)
    KARMADA_CONFIG="$SCRIPT_DIR/karmada/artifacts/kindClusterConfig/member1.yaml"
    if [ -f "$KARMADA_CONFIG" ]; then
        echo -e "${BLUE}  Using Karmada config (already includes workers)...${NC}"
        kind create cluster --name member1 --image "$KIND_NODE_IMAGE" --config "$KARMADA_CONFIG"
    else
        # Generate KIND config with dynamic worker count
        cat > /tmp/member1-kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        cgroups-per-qos: "false"
        enforce-node-allocatable: ""
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        cgroups-per-qos: "false"
        enforce-node-allocatable: ""
  - |
    kind: KubeletConfiguration
    cgroupDriver: cgroupfs
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = false
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "cloud=private"
EOF

        # Add workers dynamically
        for i in $(seq 1 ${MEMBER1_WORKERS}); do
            cat >> /tmp/member1-kind-config.yaml <<EOF
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "cloud=private"
EOF
        done

        kind create cluster --name member1 --image "$KIND_NODE_IMAGE" --config /tmp/member1-kind-config.yaml
        rm /tmp/member1-kind-config.yaml
    fi

    # Merge member1 kubeconfig - only if context doesn't exist
    kind export kubeconfig --name member1
    if kubectl config get-contexts | grep -q " member1 "; then
        # Context already exists, just update cluster
        echo -e "${BLUE}  Context 'member1' already exists, skipping rename${NC}"
    else
        kubectl config rename-context kind-member1 member1 || true
    fi

    echo -e "${GREEN}✅ member1 cluster created${NC}"
else
    echo -e "${BLUE}[1/2] Skipping member1 - already exists with correct number of workers${NC}"
fi

# Create member2 cluster (public) with workers - only if needed
if [ "$MEMBER2_NEEDS_CREATE" = true ]; then
    echo -e "${BLUE}[2/2] Creating member2 cluster (public) with ${MEMBER2_WORKERS} workers...${NC}"

    # Check if Karmada config exists, if so, use it (it already has workers now)
    KARMADA_CONFIG="$SCRIPT_DIR/karmada/artifacts/kindClusterConfig/member2.yaml"
    if [ -f "$KARMADA_CONFIG" ]; then
        echo -e "${BLUE}  Using Karmada config (already includes workers)...${NC}"
        kind create cluster --name member2 --image "$KIND_NODE_IMAGE" --config "$KARMADA_CONFIG"
    else
        # Generate KIND config with dynamic worker count
        cat > /tmp/member2-kind-config.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        cgroups-per-qos: "false"
        enforce-node-allocatable: ""
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        cgroups-per-qos: "false"
        enforce-node-allocatable: ""
  - |
    kind: KubeletConfiguration
    cgroupDriver: cgroupfs
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
      SystemdCgroup = false
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: InitConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "cloud=public"
EOF

        # Add workers dynamically
        for i in $(seq 1 ${MEMBER2_WORKERS}); do
            cat >> /tmp/member2-kind-config.yaml <<EOF
  - role: worker
    kubeadmConfigPatches:
      - |
        kind: JoinConfiguration
        nodeRegistration:
          kubeletExtraArgs:
            node-labels: "cloud=public"
EOF
        done

        kind create cluster --name member2 --image "$KIND_NODE_IMAGE" --config /tmp/member2-kind-config.yaml
        rm /tmp/member2-kind-config.yaml
    fi

    # Merge member2 kubeconfig - only if context doesn't exist
    kind export kubeconfig --name member2
    if kubectl config get-contexts | grep -q " member2 "; then
        # Context already exists, just update cluster
        echo -e "${BLUE}  Context 'member2' already exists, skipping rename${NC}"
    else
        kubectl config rename-context kind-member2 member2 || true
    fi

    echo -e "${GREEN}✅ member2 cluster created${NC}"
else
    echo -e "${BLUE}[2/2] Skipping member2 - already exists with correct number of workers${NC}"
fi

echo ""
echo -e "${GREEN}==============================${NC}"
echo -e "${GREEN}  Summary${NC}"
echo -e "${GREEN}==============================${NC}"
echo ""
echo -e "${GREEN}✅ Created clusters:${NC}"
kind get clusters

echo ""
echo -e "${BLUE}🔧 Applying kubelet resource hack...${NC}"

# Parse resources from config.yaml
MEMBER1_CPU=$(yq '.clusters.member1.cpu' "$CONFIG_FILE" 2>/dev/null || echo "2")
MEMBER1_MEM=$(yq '.clusters.member1.memory' "$CONFIG_FILE" 2>/dev/null || echo "4Gi")
MEMBER2_CPU=$(yq '.clusters.member2.cpu' "$CONFIG_FILE" 2>/dev/null || echo "2")
MEMBER2_MEM=$(yq '.clusters.member2.memory' "$CONFIG_FILE" 2>/dev/null || echo "4Gi")

# Function to hack kubelet immediately after creation - ALL WORKERS
hack_kubelet_worker() {
    local cluster=$1
    local cpu=$2
    local memory=$3
    
    echo -e "${YELLOW}  Discovering worker nodes for cluster ${cluster}...${NC}"
    
    # Wait for cluster to be available
    for i in {1..60}; do
        if kubectl get nodes --context "${cluster}" &>/dev/null; then
            break
        fi
        sleep 1
    done
    
    # Get ALL worker nodes dynamically
    local worker_nodes=$(kubectl get nodes --context "${cluster}" --no-headers 2>/dev/null | grep -E "worker[0-9]*" | awk '{print $1}')
    
    if [ -z "$worker_nodes" ]; then
        echo -e "${RED}  ✗ No worker nodes found for ${cluster}${NC}"
        return 1
    fi
    
    # Hack EACH worker node
    for worker_node in $worker_nodes; do
        echo -e "${YELLOW}  Hacking kubelet on ${worker_node}...${NC}"
        
        # Wait for docker container to exist
        for i in {1..60}; do
            if docker ps | grep -q "${worker_node}"; then
                break
            fi
            sleep 1
        done
        
        # Modify kubelet config BEFORE it fully stabilizes
        docker exec "${worker_node}" sed -i 's/nodeStatusReportFrequency: 0s/nodeStatusReportFrequency: 999999h/' /var/lib/kubelet/config.yaml 2>/dev/null || true
        docker exec "${worker_node}" sed -i 's/nodeStatusUpdateFrequency: 0s/nodeStatusUpdateFrequency: 999999h/' /var/lib/kubelet/config.yaml 2>/dev/null || true
        
        # Kill kubelet to force restart with new config
        docker exec "${worker_node}" pkill -9 kubelet 2>/dev/null || true
        
        # Wait for kubelet to restart and stabilize
        echo -e "${YELLOW}    Waiting for kubelet to restart...${NC}"
        sleep 10
        
        # Wait for node to be Ready in kubernetes
        echo -e "${YELLOW}    Waiting for node to be Ready...${NC}"
        for i in {1..30}; do
            if kubectl get node "${worker_node}" --context "${cluster}" 2>/dev/null | grep -q "Ready"; then
                break
            fi
            sleep 2
        done
        
        # Apply resource patches
        echo -e "${YELLOW}    Applying resource patches...${NC}"
        kubectl patch node "${worker_node}" --type=merge --subresource=status --context "${cluster}" -p "{
            \"status\": {
                \"capacity\": {\"cpu\": \"${cpu}\", \"memory\": \"${memory}\"},
                \"allocatable\": {\"cpu\": \"${cpu}\", \"memory\": \"${memory}\"}
            }
        }" 2>/dev/null && echo -e "${GREEN}    ✓ Resource patch applied${NC}" || echo -e "${YELLOW}    ⚠️  Patch may need retry${NC}"
        
        echo -e "${GREEN}  ✓ Kubelet config modified on ${worker_node}${NC}"
    done
}

# Apply hack to both clusters if they were created
if [ "$MEMBER1_NEEDS_CREATE" = true ]; then
    hack_kubelet_worker "member1" "$MEMBER1_CPU" "$MEMBER1_MEM"
fi

if [ "$MEMBER2_NEEDS_CREATE" = true ]; then
    hack_kubelet_worker "member2" "$MEMBER2_CPU" "$MEMBER2_MEM"
fi

echo -e "${GREEN}✅ Kubelet hack applied${NC}"

echo ""
echo -e "${BLUE}ℹ️  Note: If clusters were recreated, you may need to reconnect them:${NC}"
echo -e "${YELLOW}   Run: make setup-kubernetes-infra${NC}"
echo -e "${YELLOW}   This will reconnect the clusters to Karmada and reinstall Prometheus${NC}"

echo ""
echo -e "${BLUE}To verify:${NC}"
echo "  kubectl --context member1 get nodes"
echo "  kubectl --context member2 get nodes"
echo ""
