#!/bin/bash
# -----------------------------------------------------------------------------
# Environment Bootstrap – verifies and installs required CLI tools for KWOK,
# Karmada, and Kubernetes-based simulation.
#
# Arch-aware: works on amd64 e ppc64le (Power9). Em ppc64le não há binário
# oficial de kind nem imagem kindest/node, então compilamos o kind patcheado
# (ppc64le-cloud/kind-image) e usamos quay.io/powercloud/kind-node nos clusters.
# Distro-aware: usa dnf/yum (RHEL) ou apt (Debian/Ubuntu) quando precisa instalar.
# -----------------------------------------------------------------------------
# ‣ Tools installed: curl, docker, git, kubectl, helm, kind, jq, make,
#                    python3, pip, go, yq
# -----------------------------------------------------------------------------
#   Colour palette
# -----------------------------------------------------------------------------
COLOR="\033[1;35m"  # Magenta – this script's identity color
RESET="\033[0m"

set -euo pipefail

# Garante USER definido mesmo em shell não-login (ex.: dentro do make/container DinD)
USER="${USER:-$(id -un)}"
trap 'echo -e "${COLOR}❌  Error in ${BASH_SOURCE[0]}:$LINENO – $BASH_COMMAND${RESET}"' ERR

echo -e "${COLOR}🔧 Checking prerequisites...${RESET}"

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Mapeia `uname -m` para o token de arquitetura usado por Go/kubectl/kind/yq.
function go_arch() {
  case "$(uname -m)" in
    x86_64)  echo amd64   ;;
    aarch64) echo arm64   ;;
    ppc64le) echo ppc64le ;;
    s390x)   echo s390x   ;;
    *)       uname -m     ;;
  esac
}

# Instala pacotes usando o gerenciador disponível (dnf/yum/apt).
function pkg_install() {
  if command -v dnf &> /dev/null; then
    sudo dnf install -y "$@"
  elif command -v yum &> /dev/null; then
    sudo yum install -y "$@"
  elif command -v apt &> /dev/null; then
    sudo apt update && sudo apt install -y "$@"
  else
    echo -e "${COLOR}⚠️ Nenhum gerenciador de pacotes (dnf/yum/apt) encontrado para instalar: $*${RESET}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Individual tool checks and installs
# -----------------------------------------------------------------------------

function install_curl() {
  if ! command -v curl &> /dev/null; then
    echo -e "${COLOR}📦 Installing curl...${RESET}"
    pkg_install curl
  else
    echo -e "${COLOR}✅ curl is already installed.${RESET}"
  fi
}

function install_docker() {
  if command -v docker &> /dev/null; then
    echo -e "${COLOR}✅ Docker is already installed.${RESET}"
    # root já tem acesso ao Docker; só ajusta grupo para usuários não-root.
    if [ "$USER" != "root" ] && ! id -nG "$USER" | grep -qw "docker"; then
      echo -e "${COLOR}🐳 Adding user $USER to docker group...${RESET}"
      sudo usermod -aG docker "$USER"
      echo -e "${COLOR}ℹ️ User added to 'docker' group. Run 'newgrp docker' or re-login.${RESET}"
    fi
    return
  fi

  echo -e "${COLOR}🐳 Installing Docker...${RESET}"
  if command -v dnf &> /dev/null || command -v yum &> /dev/null; then
    # RHEL/CentOS family (inclui ppc64le). Binários estáticos pararam em 2019;
    # o repo YUM tem versões atuais por arquitetura.
    pkg_install dnf-plugins-core || true
    sudo "$(command -v dnf || command -v yum)" config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo || true
    pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  else
    # Debian/Ubuntu
    pkg_install ca-certificates gnupg lsb-release
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(lsb_release -cs) stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi

  if [ "$USER" != "root" ]; then
    sudo usermod -aG docker "$USER" || true
  fi
  echo -e "${COLOR}ℹ️ Docker installed.${RESET}"
}

# Garante que o daemon do Docker esteja rodando. Em containers (DinD) o init
# nem sempre sobe o dockerd; tenta systemd, depois service, depois dockerd direto.
function ensure_docker_running() {
  if docker info &> /dev/null; then
    echo -e "${COLOR}✅ Docker daemon is running.${RESET}"
    return 0
  fi
  echo -e "${COLOR}🐳 Docker daemon not running — attempting to start...${RESET}"
  sudo systemctl start docker 2>/dev/null \
    || sudo service docker start 2>/dev/null \
    || sudo sh -c 'nohup dockerd > /var/log/dockerd.log 2>&1 &'
  for _ in $(seq 1 20); do
    if docker info &> /dev/null; then
      echo -e "${COLOR}✅ Docker daemon is running.${RESET}"
      return 0
    fi
    sleep 2
  done
  echo -e "${COLOR}⚠️ Docker daemon ainda não respondeu. Verifique /var/log/dockerd.log${RESET}"
  return 1
}

function install_compose() {
  # Prefer the Docker Compose v2 plugin ("docker compose"), which has official
  # builds for amd64, arm64 AND ppc64le (Power9).
  if docker compose version &> /dev/null; then
    echo -e "${COLOR}✅ Docker Compose v2 plugin is already installed.${RESET}"
    return
  fi
  if command -v docker-compose &> /dev/null; then
    echo -e "${COLOR}✅ docker-compose (standalone) is already installed.${RESET}"
    return
  fi

  local COMPOSE_VERSION=2.38.2
  # Compose v2 asset names are lowercase: docker-compose-linux-<arch>
  # uname -m already returns the matching arch token (x86_64, aarch64, ppc64le, s390x).
  local ARCH="$(uname -m)"
  local PLUGIN_DIR="/usr/local/lib/docker/cli-plugins"

  echo -e "${COLOR}🐳 Installing Docker Compose v2 plugin for linux-${ARCH}...${RESET}"
  sudo mkdir -p "$PLUGIN_DIR"
  sudo curl -fL "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-linux-${ARCH}" -o "$PLUGIN_DIR/docker-compose"
  sudo chmod +x "$PLUGIN_DIR/docker-compose"
  # Also expose it as a standalone command for backwards compatibility.
  sudo ln -sf "$PLUGIN_DIR/docker-compose" /usr/local/bin/docker-compose
}

function install_git() {
  if ! command -v git &> /dev/null; then
    echo -e "${COLOR}🐙 Installing Git...${RESET}"
    pkg_install git
  else
    echo -e "${COLOR}✅ Git is already installed.${RESET}"
  fi
}

function install_kubectl() {
  local KUBECTL_VERSION=v1.32.3
  local ARCH; ARCH="$(go_arch)"

  # "instalado" só se o binário roda nesta arquitetura.
  if command -v kubectl &> /dev/null && kubectl version --client &> /dev/null; then
    echo -e "${COLOR}✅ kubectl is already installed.${RESET}"
    return
  fi
  echo -e "${COLOR}📦 Installing kubectl (linux/${ARCH})...${RESET}"
  curl -fLO "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/${ARCH}/kubectl"
  chmod +x kubectl
  sudo mv kubectl /usr/local/bin/
}

function install_helm() {
  if ! command -v helm &> /dev/null; then
    echo -e "${COLOR}⛵ Installing Helm...${RESET}"
    # O instalador oficial detecta a arquitetura (inclui ppc64le).
    curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -s -- --version v3.17.4
  else
    echo -e "${COLOR}✅ Helm is already installed.${RESET}"
  fi
}

function install_kind() {
  local ARCH; ARCH="$(go_arch)"

  if command -v kind &> /dev/null && kind version &> /dev/null; then
    echo -e "${COLOR}✅ kind is already installed.${RESET}"
    return
  fi

  if [ "$ARCH" = "ppc64le" ]; then
    # Não há binário kind nem imagem kindest/node oficiais p/ ppc64le.
    # Compilamos o kind com o patch da comunidade Power. As node images
    # ppc64le vêm de quay.io/powercloud/kind-node (usadas no main.sh).
    echo -e "${COLOR}🧱 Building patched kind for ppc64le...${RESET}"
    command -v go &> /dev/null || { echo "Go é necessário para compilar o kind"; return 1; }
    local WORK=/tmp/kind-ppc64le-build
    rm -rf "$WORK"
    git clone -q https://github.com/ppc64le-cloud/kind-image "$WORK"
    git clone -q -b "$(cat "$WORK/KIND_VERSION")" https://github.com/kubernetes-sigs/kind "$WORK/kind"
    ( cd "$WORK/kind" && git apply ../build-ppc64le.patch && sudo env "PATH=$PATH" GOBIN=/usr/local/bin make install )
  else
    local KIND_VERSION=v0.29.0
    echo -e "${COLOR}🧱 Installing kind (linux-${ARCH})...${RESET}"
    curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
  fi
}

function install_jq() {
  if command -v jq &> /dev/null && jq --version &> /dev/null; then
    echo -e "${COLOR}✅ jq is already installed.${RESET}"
    return
  fi
  echo -e "${COLOR}🔧 Installing jq...${RESET}"
  # Remove binário obsoleto/quebrado (ex.: jq amd64 baixado por versões antigas)
  # que poderia ofuscar o pacote correto da distro em /usr/bin.
  if [ -e /usr/local/bin/jq ] && ! /usr/local/bin/jq --version &> /dev/null; then
    sudo rm -f /usr/local/bin/jq
  fi
  # Em ppc64le o upstream não publica binário; o pacote da distro tem.
  if pkg_install jq; then
    return
  fi
  # Fallback p/ download direto (amd64/arm64).
  sudo curl -fL -o /usr/local/bin/jq "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$(go_arch)"
  sudo chmod +x /usr/local/bin/jq
}

function install_make() {
  if ! command -v make &> /dev/null; then
    echo -e "${COLOR}📐 Installing make...${RESET}"
    pkg_install make
  else
    echo -e "${COLOR}✅ make is already installed.${RESET}"
  fi
}

function install_python3() {
  if ! command -v python3 &> /dev/null; then
    echo -e "${COLOR}🐍 Installing Python 3...${RESET}"
    pkg_install python3
  else
    echo -e "${COLOR}✅ Python 3 is already installed.${RESET}"
  fi
}

function install_pip() {
  if ! command -v pip &> /dev/null && ! command -v pip3 &> /dev/null; then
    echo -e "${COLOR}🐍 Installing pip...${RESET}"
    pkg_install python3-pip
  else
    echo -e "${COLOR}✅ pip is already installed.${RESET}"
  fi
}

function install_go() {
  local GO_VERSION=1.24.4
  local ARCH; ARCH="$(go_arch)"

  # "instalado" só se o go roda E é da arquitetura certa (evita Go amd64 num ppc64le).
  if command -v go &> /dev/null && go version 2>/dev/null | grep -q "linux/${ARCH}"; then
    echo -e "${COLOR}✅ Golang is already installed.${RESET}"
    return
  fi

  echo -e "${COLOR}🔧 Installing Golang ${GO_VERSION} (linux-${ARCH})...${RESET}"
  curl -fLO "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "go${GO_VERSION}.linux-${ARCH}.tar.gz"
  rm -f "go${GO_VERSION}.linux-${ARCH}.tar.gz"
  grep -q '/usr/local/go/bin' ~/.bashrc 2>/dev/null || echo 'export PATH=$PATH:/usr/local/go/bin' >> ~/.bashrc
  export PATH=$PATH:/usr/local/go/bin
  echo -e "${COLOR}ℹ️ Golang installed. PATH has been updated.${RESET}"
}

function install_yq() {
  local DESIRED_VERSION="v4.44.5"
  local ARCH; ARCH="$(go_arch)"
  local CURRENT_VERSION=""

  if command -v yq &> /dev/null && yq --version &> /dev/null; then
    CURRENT_VERSION="$(yq --version 2>/dev/null | awk '{print $NF}')" || true
  fi

  if [[ -z "$CURRENT_VERSION" ]] || [[ "$CURRENT_VERSION" != "$DESIRED_VERSION" ]]; then
    echo -e "${COLOR}📦 Installing yq ${DESIRED_VERSION} (linux_${ARCH})...${RESET}"
    sudo curl -fL -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/${DESIRED_VERSION}/yq_linux_${ARCH}"
    sudo chmod +x /usr/local/bin/yq
    echo -e "${COLOR}✅ yq ${DESIRED_VERSION} installed.${RESET}"
  else
    echo -e "${COLOR}✅ yq ${DESIRED_VERSION} is already installed.${RESET}"
  fi
}

# -----------------------------------------------------------------------------
# Run all prerequisite checks sequentially
# (install_go antes de install_kind: em ppc64le o kind é compilado com Go)
# -----------------------------------------------------------------------------
install_curl
install_docker
ensure_docker_running
install_compose
install_git
install_go
install_kubectl
install_helm
install_kind
install_jq
install_make
install_python3
install_pip
install_yq

# Ensure required directories exist for docker-compose volume mounts
mkdir -p ~/.kube
mkdir -p ~/.kwok

echo -e "${COLOR}✅ Environment is ready.${RESET}"
