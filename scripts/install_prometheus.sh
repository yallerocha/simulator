#!/bin/bash
# -----------------------------------------------------------------------------
# Prometheus + Grafana Installer – deploys Prometheus + Grafana via Helm in
# both member clusters. Also sets up port-forwards for local access to
# Prometheus + Grafana UIs.
# -----------------------------------------------------------------------------
# ‣ Behaviour
#   • Installs Prometheus and Grafana in `member1` and `member2` clusters.
#   • Waits for pods to be fully running and ready.
#   • Starts background port-forwards for each cluster.
# -----------------------------------------------------------------------------
#   Colour palette
# -----------------------------------------------------------------------------
COLOR="\033[1;36m"  # Cyan – this script's identity color
RESET="\033[0m"

set -eo pipefail
trap 'echo -e "\033[1;31m❌ Error in $BASH_SOURCE:$LINENO – $BASH_COMMAND\033[0m"' ERR

GRAFANA_STATUS=${PROMETHEUS_GRAFANA_ENABLE:-false}
RELEASE_NAME="prometheus"
NAMESPACE="monitoring"
KUBE_PROMETHEUS_STACK_VERSION=75.15.1
SLEEP_TIME=${SLEEP_TIME:-5}

GRAFANA_USER="adminuser"
GRAFANA_PASSWORD="p@ssword!"

export KUBECONFIG=~/.kube/members.config

# -----------------------------------------------------------------------------
# Create temporary credential files
# -----------------------------------------------------------------------------
create_grafana_credentials_files() {
  echo -n "$GRAFANA_USER" > ./admin-user
  echo -n "$GRAFANA_PASSWORD" > ./admin-password
}

# -----------------------------------------------------------------------------
# Install Prometheus + Grafana in both clusters
# -----------------------------------------------------------------------------
for CONTEXT in member1 member2; do
  echo -e "${COLOR}⛵ [$CONTEXT] Installing Prometheus + Grafana...${RESET}"
  kubectl config use-context "$CONTEXT"

  echo -e "${COLOR}🔧 Creating namespace '$NAMESPACE' if not exists...${RESET}"
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  echo -e "${COLOR}🔑 Creating Grafana admin credentials secret...${RESET}"
  create_grafana_credentials_files
  kubectl -n "$NAMESPACE" delete secret grafana-admin-credentials --ignore-not-found
  kubectl create secret generic grafana-admin-credentials \
    --from-file=./admin-user \
    --from-file=./admin-password \
    -n "$NAMESPACE"

  echo -e "${COLOR}📦 Configuring Helm repository...${RESET}"
  helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
  helm repo update >/dev/null

  echo -e "${COLOR}🧹 Removing previous Prometheus release (if any)...${RESET}"
  helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || true

  echo -e "${COLOR}🔧 Creating grafana dashboard ConfigMap...${RESET}"
  kubectl apply -f pending-pods-dashboard.yaml -n "$NAMESPACE"

  echo -e "${COLOR}🚀 Installing kube-prometheus-stack via Helm...${RESET}"
  helm upgrade --install "$RELEASE_NAME" prometheus-community/kube-prometheus-stack \
  -f prometheus_grafana.yaml \
  --version $KUBE_PROMETHEUS_STACK_VERSION \
  --set grafana.enabled=${GRAFANA_STATUS} \
  --namespace "$NAMESPACE" \
  --wait \
  --timeout 30m \
  --set prometheusOperator.admissionWebhooks.enabled=false \
  --set prometheusOperator.admissionWebhooks.patch.enabled=false \
  --set prometheusOperator.tls.enabled=false \
  --set grafana.admin.existingSecret=grafana-admin-credentials \
  --set grafana.admin.userKey=admin-user \
  --set grafana.admin.passwordKey=admin-password \
  --set grafana.service.type=ClusterIP \
  --set prometheus.service.type=ClusterIP

  echo -e "${COLOR}⏳ Waiting for Prometheus pod to become ready...${RESET}"
  for i in {1..40}; do
    POD=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)
    READY=$(kubectl get pod -n "$NAMESPACE" "$POD" -o jsonpath="{.status.containerStatuses[0].ready}" 2>/dev/null || true)
    [[ "$READY" == "true" ]] && break
    echo -e "${COLOR}⌛ [$CONTEXT] Waiting for pod '$POD' to be ready...${RESET}"
    sleep "$SLEEP_TIME"
  done
done

# -----------------------------------------------------------------------------
# Start port-forwarding for Prometheus and Grafana UIs
# -----------------------------------------------------------------------------
start_port_forward() {
  local ctx=$1 ns=$2 svc=$3 local_port=$4 target_port=$5
  local logfile="/tmp/pf_${ctx}_${local_port}.log"
  # Mata qualquer port-forward anterior na mesma porta para evitar conflito
  pkill -f "port-forward svc/$svc $local_port:" 2>/dev/null || true
  sleep 1
  nohup bash -c "
    while true; do
      KUBECONFIG=${KUBECONFIG} kubectl --context '${ctx}' -n '${ns}' \
        port-forward 'svc/${svc}' '${local_port}:${target_port}' \
        --address 127.0.0.1 >>'${logfile}' 2>&1
      sleep 2
    done
  " >>"$logfile" 2>&1 &
  disown $!
}

echo -e "${COLOR}🌐 Starting background port-forwards...${RESET}"
start_port_forward member1 "$NAMESPACE" prometheus-prometheus 9090 9090
start_port_forward member2 "$NAMESPACE" prometheus-prometheus 9091 9090

start_port_forward member1 "$NAMESPACE" grafana 3000 80
start_port_forward member2 "$NAMESPACE" grafana 3001 80

echo -e "${COLOR}✅ Prometheus + Grafana successfully installed in both clusters.${RESET}"
echo -e "${COLOR}➡️ Prometheus UI: http://localhost:9090 (member1), http://localhost:9091 (member2)${RESET}"
echo -e "${COLOR}➡️ Grafana UI: http://localhost:3000 (member1), http://localhost:3001 (member2)${RESET}"