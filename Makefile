SHELL := /bin/bash
export PATH := $(PATH):/usr/local/go/bin

ACTUATOR_MODE ?= auto

# Auto-detect Docker Compose: v2 plugin ("docker compose") or v1 standalone ("docker-compose").
# Falls back to "docker compose" so the error message is clear if neither is installed.
COMPOSE := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

# Fallback compose project name for clean-project. The recipe first asks Compose
# for the real resolved project name (respects -p / COMPOSE_PROJECT_NAME / .env);
# this basename value is only used if that lookup returns nothing.
PROJECT := $(shell basename "$(CURDIR)" | tr '[:upper:]' '[:lower:]')

.PHONY: all setup start setup-and-start setup-and-start-human setup-kubernetes-infra stop-all-containers restart-all-containers clean-karmada-deployments clean-all clean-project help start-auto-mode start-human-loop-mode run-auto-mode run-all-containers run-all-containers-human ollama-start ollama-stop ollama-restart ollama-logs ollama-list ollama-build

# Default target: shows help
all: help

# Sets up infrastructure and runs in human-in-the-loop mode
setup-and-start-human: setup-kubernetes-infra stop-all-containers run-all-containers-human start

# Sets up Kubernetes infrastructure (receives mode as parameter)
setup-kubernetes-infra:
	@echo -e "\\e[35mStarting Kubernetes infrastructure setup...\\e[0m"
	@( \
		cd scripts && chmod +x main.sh && ./main.sh $(MODE); \
	)
	@echo -e "\\e[35mKubernetes infrastructure setup completed.\\e[0m"

# Starts all required containers via docker-compose (after updating KWOK_MODE)
run-all-containers:
	@echo "Updating compose.yaml with KWOK_MODE=$(MODE)..."
	@cd scripts && chmod +x update-compose-mode.sh && ./update-compose-mode.sh $(MODE)
	@echo "Starting all necessary containers via $(COMPOSE)..."
	@$(COMPOSE) -f compose.yaml up --build -d
	@echo "All containers started successfully."

# Run containers in human-in-the-loop mode (UI review required)
run-all-containers-human:
	@echo "Starting all containers in HUMAN-IN-THE-LOOP mode..."
	@echo "Updating compose.yaml paths with the user's HOME..."
	@echo scripts/replace_paths_in_compose.sh
	@echo "Starting all necessary containers via docker compose (ACTUATOR_MODE=human-in-the-loop)..."
	@ACTUATOR_MODE=human-in-the-loop $(COMPOSE) -f compose.yaml up --build -d
	@echo "All containers started successfully in HUMAN-IN-THE-LOOP mode."
	@echo "🎯 Actuator UI available at: http://localhost:5173"

# Sets up the complete infrastructure (KWOK mode)
setup-kwok:
	@echo -e "\\e[36m🎭 Setting up KWOK mode infrastructure...\\e[0m"
	@$(MAKE) stop-kubernetes-infra stop-all-containers
	@$(MAKE) setup-kubernetes-infra MODE=kwok
	@$(MAKE) run-all-containers MODE=kwok
	@echo -e "\\e[32m✓ KWOK mode infrastructure ready!\\e[0m"

# Sets up the complete infrastructure (Real mode)
setup-real:
	@echo -e "\\e[36m🌐 Setting up Real mode infrastructure...\\e[0m"
	@$(MAKE) stop-kubernetes-infra stop-all-containers
	@$(MAKE) setup-kubernetes-infra MODE=real
	@$(MAKE) run-all-containers MODE=real
	@echo -e "\\e[32m✓ Real mode infrastructure ready!\\e[0m"

# Generic setup target (requires mode parameter)
setup:
	@if [ "$(filter kwok real,$(MAKECMDGOALS))" ]; then \
		MODE=$$(echo "$(MAKECMDGOALS)" | grep -o -E 'kwok|real'); \
		$(MAKE) setup-$$MODE; \
	else \
		echo "Usage: make setup {kwok|real}"; \
		exit 1; \
	fi

# Starts only the Go simulator (assumes infrastructure is already set up)
start-simulator: clean-mongo-db
	@python3 scripts/wait_for_ollama.py
	@(cd simulator/cmd && go run main.go)

# Starts simulator in KWOK mode (assumes setup already done)
start-kwok:
	@echo -e "\\e[36m🎭 Starting simulator in KWOK mode...\\e[0m"
	@KWOK_MODE=true $(MAKE) start-simulator

# Starts simulator in Real mode (assumes setup already done)
start-real:
	@echo -e "\\e[36m🌐 Starting simulator in Real mode...\\e[0m"
	@KWOK_MODE=false $(MAKE) start-simulator

# Generic start target (requires mode parameter)
start:
	@if [ "$(filter kwok real,$(MAKECMDGOALS))" ]; then \
		MODE=$$(echo "$(MAKECMDGOALS)" | grep -o -E 'kwok|real'); \
		$(MAKE) start-$$MODE; \
	else \
		echo "Usage: make start {kwok|real}"; \
		exit 1; \
	fi

# Sets up infrastructure and starts simulator (KWOK mode)
setup-and-start-kwok:
	@echo -e "\\e[36m🎭 Setting up and starting in KWOK mode...\\e[0m"
	@$(MAKE) setup-kwok
	@$(MAKE) start-kwok

# Sets up infrastructure and starts simulator (Real mode)
setup-and-start-real:
	@echo -e "\\e[36m� Setting up and starting in Real mode...\\e[0m"
	@$(MAKE) setup-real
	@$(MAKE) start-real

# Generic setup-and-start target (requires mode parameter)
setup-and-start:
	@if [ "$(filter kwok real,$(MAKECMDGOALS))" ]; then \
		MODE=$$(echo "$(MAKECMDGOALS)" | grep -o -E 'kwok|real'); \
		$(MAKE) setup-and-start-$$MODE; \
	else \
		echo "Usage: make setup-and-start {kwok|real}"; \
		exit 1; \
	fi

# Dummy targets to avoid make errors
kwok:
	@:
real:
	@:

# Cleans all documents from all collections in the mongo container.
# Uses the miniforge Python + pymongo bundled in the mongo image (the conda
# mongodb package ships only `mongod`, so there is no `mongosh`/`mongo` shell).
clean-mongo-db:
	@echo "Cleaning all documents from all collections in mongo container..."
	@container_id=$$(sudo docker ps -q -f name=mongo); \
	if [ -z "$$container_id" ]; then \
		echo "Mongo container is not running. Nothing to clean."; \
		exit 0; \
	fi; \
	py='import sys; from pymongo import MongoClient; c=MongoClient("mongodb://localhost:27017"); [ [c[d][coll].delete_many({}) for coll in c[d].list_collection_names()] for d in c.list_database_names() if d not in ("admin","local","config") ]'; \
	if sudo docker exec $$container_id python -c "$$py"; then \
		echo "All documents removed from all user collections via pymongo in container."; \
	else \
		echo "ERROR: failed to clean MongoDB collections (see output above)."; \
		exit 1; \
	fi

# Cleans all deployments and jobs from Karmada namespace default
clean-karmada-deployments:
	@echo -e "\\e[33m🧹 Cleaning all deployments and jobs from Karmada...\\e[0m"
	@if [ -z "$$KUBECONFIG" ]; then \
		export KUBECONFIG=~/.kube/karmada.config; \
		echo "Using default KUBECONFIG: ~/.kube/karmada.config"; \
	fi; \
	kubectl config use-context karmada-apiserver 2>/dev/null || true; \
	echo "Deleting all deployments in namespace default..."; \
	deployments=$$(kubectl get deployments -n default -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	if [ -n "$$deployments" ]; then \
		for deploy in $$deployments; do \
			echo "  Deleting deployment: $$deploy"; \
			kubectl delete deployment $$deploy -n default --ignore-not-found=true 2>/dev/null || true; \
		done; \
		echo "✓ All deployments deleted."; \
	else \
		echo "  No deployments found in namespace default."; \
	fi; \
	echo "Deleting all jobs in namespace default..."; \
	jobs=$$(kubectl get jobs -n default -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); \
	if [ -n "$$jobs" ]; then \
		for job in $$jobs; do \
			echo "  Deleting job: $$job"; \
			kubectl delete job $$job -n default --ignore-not-found=true 2>/dev/null || true; \
		done; \
		echo "✓ All jobs deleted."; \
	else \
		echo "  No jobs found in namespace default."; \
	fi; \
	echo -e "\\e[32m✓ Karmada cleanup completed.\\e[0m"

# Cleans both Karmada deployments and MongoDB
clean-all: clean-karmada-deployments clean-mongo-db
	@echo -e "\\e[32m✓ Complete cleanup finished (Karmada + MongoDB).\\e[0m"

# Removes ONLY this project's containers, app images and data volumes.
# KEEPS: Ollama image + downloaded models (ollama_data volume) and Mongo image.
# Removes: broker/monitor/ai-engine/actuator images + mongo_data/config_data volumes.
# Does NOT run any global `docker ... prune`, so nothing else on the host is touched.
clean-project:
	@echo -e "\\e[33m🧹 Cleaning project containers, app images and data volumes...\\e[0m"
	@echo "  → Stopping/removing containers + network (volumes preserved for now)..."
	@sudo $(COMPOSE) -f compose.yaml down --remove-orphans || true
	@echo "  → Removing app-built images (broker, monitor, ai-engine, actuator)..."
	@ids=$$(sudo $(COMPOSE) -f compose.yaml images -q broker monitor ai-engine actuator 2>/dev/null | sort -u); \
	if [ -n "$$ids" ]; then sudo docker image rm -f $$ids || true; else echo "    (nenhuma imagem de app encontrada)"; fi
	@echo "  → Removing project data volumes (KEEPING ollama_data / models)..."
	@proj=$$(sudo $(COMPOSE) -f compose.yaml config 2>/dev/null | sed -n 's/^name: //p' | head -1); \
	[ -z "$$proj" ] && proj="$(PROJECT)"; \
	echo "    (compose project: $$proj)"; \
	for v in mongo_data config_data; do \
		vol=$$(sudo docker volume ls -q -f label=com.docker.compose.project=$$proj -f label=com.docker.compose.volume=$$v); \
		if [ -n "$$vol" ]; then echo "    removendo volume: $$vol"; sudo docker volume rm $$vol || true; else echo "    (sem volume para $$v)"; fi; \
	done
	@echo -e "\\e[32m✓ Projeto limpo. Imagem+modelos do Ollama e imagem do Mongo preservados.\\e[0m"

restart-all-containers: stop-all-containers run-all-containers
	@echo "All services have been fully restarted."

# Para derrubar os containers KIND do cluster
stop-kubernetes-infra:
	@echo "Parando containers KIND do cluster..."
	kind delete cluster --name member1 || true
	kind delete cluster --name member2 || true
	kind delete cluster --name karmada-host || true
	@echo "Clusters KIND removidos."

# Stops and removes all simulator containers
stop-all-containers:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "docker não encontrado — pulando limpeza de containers (ambiente novo; os pré-requisitos serão instalados no setup)."; \
	else \
		echo "Stopping and removing all containers defined in compose.yaml..."; \
		sudo $(COMPOSE) -f compose.yaml down || true; \
		echo "Cleanup process completed."; \
	fi

# ──────────────────────────────────────────────────────────────────────────────
# Ollama Management
# ──────────────────────────────────────────────────────────────────────────────

# Build the Ollama container image (conda install ufcg-ibm::ollama-ppc64le)
ollama-build:
	@echo -e "\\e[35m🔨 Building Ollama container (ufcg-ibm::ollama-ppc64le)...\\e[0m"
	@$(COMPOSE) -f compose.yaml build ollama
	@echo -e "\\e[32m✓ Ollama image built.\\e[0m"

# Start the Ollama container (pulls models and applies Modelfiles on first boot)
ollama-start:
	@echo -e "\\e[35m🚀 Starting Ollama server...\\e[0m"
	@$(COMPOSE) -f compose.yaml up -d ollama
	@echo -e "\\e[32m✓ Ollama started. Use 'make ollama-logs' to watch model provisioning.\\e[0m"

# Stop the Ollama container
ollama-stop:
	@echo -e "\\e[33m⏹  Stopping Ollama server...\\e[0m"
	@$(COMPOSE) -f compose.yaml stop ollama
	@echo -e "\\e[32m✓ Ollama stopped.\\e[0m"

# Restart Ollama (re-applies Modelfiles from config)
ollama-restart:
	@echo -e "\\e[36m🔄 Restarting Ollama (re-applying Modelfiles from config)...\\e[0m"
	@$(COMPOSE) -f compose.yaml restart ollama
	@echo -e "\\e[32m✓ Ollama restarted.\\e[0m"

# Follow Ollama logs
ollama-logs:
	@$(COMPOSE) -f compose.yaml logs -f ollama

# List models available in Ollama
ollama-list:
	@sudo docker exec ollama ollama list

# ──────────────────────────────────────────────────────────────────────────────
# Important Notes
# - You must export the KUBECONFIG variable with the correct files
#   before running commands that use `kubectl`, such as the Broker.
#   Example:
#
#     export KUBECONFIG=~/.kube/karmada.config
#     # or (to view multiple clusters)
#     export KUBECONFIG=~/.kube/karmada.config:~/.kube/members.config
#
# - Without this, the Broker will not be able to create deployments and jobs correctly.
# ──────────────────────────────────────────────────────────────────────────────
# Help

help:
	@echo "╔══════════════════════════════════════════════════════════════════╗"
	@echo "║          Multi-Cloud Workload Migration Simulator               ║"
	@echo "╚══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "🎯 Main Commands (Standardized Syntax):"
	@echo ""
	@echo "  make setup-and-start {kwok|real}  : Setup infrastructure + Start simulator"
	@echo "  make setup {kwok|real}            : Setup infrastructure only"
	@echo "  make start {kwok|real}            : Start simulator only (assumes setup done)"
	@echo ""
	@echo "📦 Examples:"
	@echo "  make setup-and-start kwok         : 🎭 Full KWOK mode setup and start"
	@echo "  make setup-and-start real         : 🌐 Full Real mode setup and start"
	@echo "  make setup kwok                   : 🎭 Setup KWOK infrastructure"
	@echo "  make setup real                   : 🌐 Setup Real infrastructure"
	@echo "  make start kwok                   : 🎭 Start simulator (KWOK)"
	@echo "  make start real                   : 🌐 Start simulator (Real)"
	@echo ""
	@echo "📦 Container Management:"
	@echo "  run-all-containers                : Starts all required containers via docker-compose"
	@echo "  restart-all-containers            : Stops, removes, and recreates all containers"
	@echo "  stop-all-containers               : Stops and removes all simulator containers"
	@echo ""
	@echo "🤖 Ollama (Local LLM):"
	@echo "  ollama-build                      : Build Ollama image (ufcg-ibm::ollama-ppc64le)"
	@echo "  ollama-start                      : Start Ollama server + pull models"
	@echo "  ollama-stop                       : Stop Ollama server"
	@echo "  ollama-restart                    : Restart Ollama (re-apply Modelfiles)"
	@echo "  ollama-logs                       : Follow Ollama container logs"
	@echo "  ollama-list                       : List models available in Ollama"
	@echo ""
	@echo "🗄️  Database:"
	@echo "  clean-mongo-db                    : Cleans all documents from MongoDB collections"
	@echo ""
	@echo "🧹 Cleanup:"
	@echo "  clean-karmada-deployments         : Deletes all deployments and jobs from Karmada"
	@echo "  clean-all                         : Cleans Karmada deployments + MongoDB"
	@echo "  clean-project                     : Removes project images + data volumes (keeps Ollama models/image + Mongo image)"
	@echo ""
	@echo "☸️  Infrastructure:"
	@echo "  setup-kubernetes-infra            : Runs scripts/main.sh to set up Kubernetes"
	@echo "  stop-kubernetes-infra             : Removes KIND cluster containers"
	@echo ""
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo "🎭 KWOK Mode (Simulated):"
	@echo "  • Fake nodes created by KWOK controller"
	@echo "  • Busybox fake containers (no actual resource consumption)"
	@echo "  • Metrics based on Kubernetes resource requests"
	@echo "  • Fast simulation for testing and development"
	@echo ""
	@echo "🌐 Real Mode (KIND Clusters):"
	@echo "  • Real KIND clusters (member1, member2) with worker nodes"
	@echo "  • Real workload containers (7 types: cpu/memory/io/network/mixed/bursty/idle)"
	@echo "  • Actual resource consumption tracked by cAdvisor"
	@echo "  • Prometheus metrics from real containers"
	@echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	@echo ""
	@echo "📝 Important Notes:"
	@echo "  • Export KUBECONFIG before running simulator:"
	@echo "    export KUBECONFIG=~/.kube/karmada.config"
	@echo "  • Or to view multiple clusters:"
	@echo "    export KUBECONFIG=~/.kube/karmada.config:~/.kube/members.config"
	@echo ""