#!/bin/bash
# -----------------------------------------------------------------------------
# Main Orchestrator – provisions the full simulation stack using Karmada,
# KWOK, Cluster Autoscaler, and Prometheus, driven by a YAML config file.
# -----------------------------------------------------------------------------
# ‣ Behaviour
#   • Loads cluster definitions from initialization.yaml.
#   • Installs prerequisites, generates manifests, starts Karmada.
#   • Deploys Prometheus, KWOK, Cluster Autoscaler (conditionally), and nodes.
#   • Supports both KWOK (simulated) and real workload modes
# -----------------------------------------------------------------------------
COLOR="\033[1;32m"  # Green – this script's identity color
RESET="\033[0m"

set -euo pipefail
trap 'echo -e "${COLOR}❌ Error in ${BASH_SOURCE[0]}:$LINENO – $BASH_COMMAND${RESET}"' ERR

# Ensure /usr/local/go/bin is in PATH for Go-related commands (like local-up-karmada.sh)
export PATH=$PATH:/usr/local/go/bin

# -----------------------------------------------------------------------------
# Node image para os clusters kind (arch-aware).
# ppc64le (Power9) não tem imagem kindest/node oficial; usamos a build da
# comunidade Power (quay.io/powercloud/kind-node). amd64/arm64 usam a oficial.
# Karmada (hack/*.sh) seleciona a node image via a variável CLUSTER_VERSION.
# -----------------------------------------------------------------------------
if [[ "$(uname -m)" == "ppc64le" ]]; then
    export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-quay.io/powercloud/kind-node:v1.31.14}"
else
    export KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.31.2}"
fi
export CLUSTER_VERSION="${CLUSTER_VERSION:-$KIND_NODE_IMAGE}"
echo -e "${COLOR}🖼️  Kind node image: ${KIND_NODE_IMAGE}${RESET}"

# -----------------------------------------------------------------------------
# Parse execution mode from argument
# -----------------------------------------------------------------------------
EXECUTION_MODE="${1:-kwok}"  # Default to kwok if no argument

# Validate mode
if [[ "$EXECUTION_MODE" != "kwok" ]] && [[ "$EXECUTION_MODE" != "real" ]]; then
    echo -e "${COLOR}❌ Error: Invalid mode '${EXECUTION_MODE}'${RESET}"
    echo -e "${COLOR}   Usage: ./main.sh [kwok|real]${RESET}"
    echo -e "${COLOR}   Defaults to 'kwok' if not specified${RESET}"
    exit 1
fi

echo -e "${COLOR}🎯 Execution Mode: ${EXECUTION_MODE}${RESET}"

# -----------------------------------------------------------------------------
# Setup Python venv and dependencies for Analyzer
# -----------------------------------------------------------------------------
echo -e "${COLOR}🐍 Setting up Python venv for Analyzer...${RESET}"
SCRIPT_DIR="$(dirname "$0")"
pushd "$SCRIPT_DIR" > /dev/null
chmod +x setup_venv.sh
./setup_venv.sh
popd > /dev/null
echo -e "${COLOR}✅ Python venv ready.${RESET}"

# -----------------------------------------------------------------------------
# 1. Ensure all scripts are executable
# -----------------------------------------------------------------------------
chmod +x install_prerequisites.sh generate_manifests.sh install_karmada.sh \
        install_prometheus.sh install_kwok.sh install_autoscaler.sh \
        install_autoscaler_kind.sh taint_control_plane.sh create_kwok_nodes.sh \
        create_kind_clusters.sh create_real_nodes.sh real-mode_setup.sh kwok-mode_setup.sh \
        load_config.sh

echo -e "${COLOR}[1/8] 📦 Installing prerequisites...${RESET}"
./install_prerequisites.sh

# -----------------------------------------------------------------------------
# 2. Load all variables 
# -----------------------------------------------------------------------------
CONFIG_FILE="../simulator/data/config.yaml"
[[ ! -f $CONFIG_FILE ]] && { echo "❌ $CONFIG_FILE not found."; exit 1; }

echo -e "${COLOR}[2/8] 📦 Load configuration...${RESET}"
source ./load_config.sh $CONFIG_FILE

echo -e "\n🔧 Loaded configuration from $CONFIG_FILE:"
echo "member1: $MEMBER1_NODES nodes, ${MEMBER1_CPU} CPU, ${MEMBER1_MEM} RAM"
echo "member2: $MEMBER2_NODES nodes, ${MEMBER2_CPU} CPU, ${MEMBER2_MEM} RAM, autoscaler=$MEMBER2_AUTOSCALER"
echo ""

# -----------------------------------------------------------------------------
# 3. Provision infrastructure
# -----------------------------------------------------------------------------
echo -e "${COLOR}[3/8] 📝 Generating configuration files...${RESET}"
./generate_manifests.sh

# -----------------------------------------------------------------------------
# 3.5. Clean up KIND clusters if in KWOK mode (before Karmada creates them)
# -----------------------------------------------------------------------------
if [[ "$EXECUTION_MODE" == "kwok" ]]; then
    echo -e "${COLOR}[3.5/8] 🧹 Cleaning up KIND clusters for KWOK mode...${RESET}"
    if command -v kind &> /dev/null; then
        for cluster in member1 member2; do
            if kind get clusters 2>/dev/null | grep -q "^${cluster}$"; then
                echo -e "${COLOR}  -> Deleting KIND cluster: ${cluster}${RESET}"
                kind delete cluster --name "$cluster" 2>/dev/null || true
                echo -e "${COLOR}    ✓ Cluster ${cluster} deleted${RESET}"
            fi
        done
        echo -e "${COLOR}  ✅ KIND clusters cleanup completed${RESET}"
    fi
fi

echo -e "${COLOR}[4/8] ☸️  Bringing up Karmada...${RESET}"
EXECUTION_MODE="$EXECUTION_MODE" ./install_karmada.sh
export KUBECONFIG=~/.kube/karmada.config

# -----------------------------------------------------------------------------
# 4. Setup according to execution mode (before Prometheus for Real mode)
# -----------------------------------------------------------------------------
export KUBECONFIG=~/.kube/members.config

if [[ "$EXECUTION_MODE" == "kwok" ]]; then
    echo -e "${COLOR}[5/8] 🎭 Setting up KWOK mode (simulated)...${RESET}"
    ./kwok-mode_setup.sh
    
    echo -e "${COLOR}[6/8] 📊 Installing Prometheus (before applying taints)...${RESET}"
    ./install_prometheus.sh  # includes readiness check and port-forwards
    
    echo -e "${COLOR}[6.5/8] 🧪 Applying control-plane taints (after Prometheus)...${RESET}"
    ./taint_control_plane.sh
elif [[ "$EXECUTION_MODE" == "real" ]]; then
    echo -e "${COLOR}[5/8] 🌐 Setting up Real mode (creating clusters)...${RESET}"
    ./real-mode_setup.sh
    
    echo -e "${COLOR}[6/8] 📊 Installing Prometheus...${RESET}"
    ./install_prometheus.sh  # includes readiness check and port-forwards
else
    echo -e "${COLOR}❌ Unknown execution mode: ${EXECUTION_MODE}${RESET}"
    echo -e "${COLOR}   Valid options: kwok, real${RESET}"
    exit 1
fi

# Autoscaler (for KWOK mode or KIND mode in member2)
if [[ "${MEMBER2_AUTOSCALER:-true}" == "true" ]]; then
    if [[ "$EXECUTION_MODE" == "kwok" ]]; then
        echo -e "${COLOR}[7/10] ⚙️ Installing Cluster Autoscaler (KWOK)...${RESET}"
        ./install_autoscaler.sh
    elif [[ "$EXECUTION_MODE" == "real" ]]; then
        echo -e "${COLOR}[7/10] ⚙️ Installing Cluster Autoscaler (KIND - member2 only)...${RESET}"
        chmod +x install_autoscaler_kind.sh
        ./install_autoscaler_kind.sh
    fi
else
    echo -e "${COLOR}[7/10] ⚙️ Skipping Autoscaler installation...${RESET}"
fi

echo -e "${COLOR}[8/10] ✅ Mode setup completed${RESET}"

# -----------------------------------------------------------------------------
# 5. Final verification (for Real mode only)
# -----------------------------------------------------------------------------
if [[ "$EXECUTION_MODE" == "real" ]]; then
    echo -e "${COLOR}[9/10] 🔍 Final verification of node resources...${RESET}"
    
    export KUBECONFIG=~/.kube/members.config
    
    # Function to verify node resources for ALL workers
    verify_cluster_resources() {
        local cluster=$1
        local expected_cpu=$2
        local expected_mem=$3
        
        echo -e "${COLOR}  Checking all workers in ${cluster}...${RESET}"
        
        # Get ALL worker nodes dynamically
        local worker_nodes=$(kubectl get nodes --context "${cluster}" --no-headers 2>/dev/null | grep -E "worker[0-9]*" | awk '{print $1}')
        
        if [ -z "$worker_nodes" ]; then
            echo -e "${COLOR}    ⚠️  No worker nodes found for ${cluster}${RESET}"
            return 1
        fi
        
        local all_ok=0
        
        for node in $worker_nodes; do
            echo -e "${COLOR}    Checking ${node}...${RESET}"
            
            # Get actual values
            ACTUAL_CPU=$(kubectl get node "$node" --context "$cluster" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null || echo "ERROR")
            ACTUAL_MEM=$(kubectl get node "$node" --context "$cluster" -o jsonpath='{.status.capacity.memory}' 2>/dev/null || echo "ERROR")
            
            if [ "$ACTUAL_CPU" = "$expected_cpu" ] && [ "$ACTUAL_MEM" = "$expected_mem" ]; then
                echo -e "${COLOR}      ✅ ${node}: ${ACTUAL_CPU} cores, ${ACTUAL_MEM} (CORRECT)${RESET}"
            else
                echo -e "${COLOR}      ⚠️  ${node}: ${ACTUAL_CPU} cores, ${ACTUAL_MEM} (Expected: ${expected_cpu} cores, ${expected_mem})${RESET}"
                echo -e "${COLOR}      🔧 Reapplying patches...${RESET}"
                
                # Reapply patch
                kubectl patch node "$node" --type=merge --subresource=status --context "$cluster" -p "{
                    \"status\": {
                        \"capacity\": {\"cpu\": \"${expected_cpu}\", \"memory\": \"${expected_mem}\"},
                        \"allocatable\": {\"cpu\": \"${expected_cpu}\", \"memory\": \"${expected_mem}\"}
                    }
                }" 2>/dev/null
                
                # Verify again
                sleep 2
                ACTUAL_CPU=$(kubectl get node "$node" --context "$cluster" -o jsonpath='{.status.capacity.cpu}' 2>/dev/null)
                ACTUAL_MEM=$(kubectl get node "$node" --context "$cluster" -o jsonpath='{.status.capacity.memory}' 2>/dev/null)
                
                if [ "$ACTUAL_CPU" = "$expected_cpu" ] && [ "$ACTUAL_MEM" = "$expected_mem" ]; then
                    echo -e "${COLOR}      ✅ Patch successful: ${ACTUAL_CPU} cores, ${ACTUAL_MEM}${RESET}"
                else
                    echo -e "${COLOR}      ❌ Patch failed: ${ACTUAL_CPU} cores, ${ACTUAL_MEM}${RESET}"
                    all_ok=1
                fi
            fi
        done
        
        return $all_ok
    }
    
    # Verify both clusters
    verify_cluster_resources "member1" "$MEMBER1_CPU" "$MEMBER1_MEM"
    MEMBER1_STATUS=$?
    
    verify_cluster_resources "member2" "$MEMBER2_CPU" "$MEMBER2_MEM"
    MEMBER2_STATUS=$?
    
    if [ $MEMBER1_STATUS -eq 0 ] && [ $MEMBER2_STATUS -eq 0 ]; then
        echo -e "${COLOR}  ✅ All node resources verified and correct${RESET}"
    else
        echo -e "${COLOR}  ⚠️  Some nodes have incorrect resources${RESET}"
        echo -e "${COLOR}  ℹ️  You can manually fix with: ./scripts/hack_kubelet.sh${RESET}"
    fi
else
    echo -e "${COLOR}[9/10] Skipping resource verification (KWOK mode)${RESET}"
fi

# -----------------------------------------------------------------------------
# 6. Final message
# -----------------------------------------------------------------------------
echo -e "\n${COLOR}[🎉] Environment provisioned successfully!${RESET}"
