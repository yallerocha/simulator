SHELL := /bin/bash
export PATH := $(PATH):/usr/local/go/bin

ACTUATOR_MODE ?= auto

# Auto-detect Docker Compose: v2 plugin ("docker compose") or v1 standalone ("docker-compose").
# Falls back to "docker compose" so the error message is clear if neither is installed.
COMPOSE := $(shell if docker compose version >/dev/null 2>&1; then echo "docker compose"; elif command -v docker-compose >/dev/null 2>&1; then echo "docker-compose"; else echo "docker compose"; fi)

.PHONY: all setup start setup-and-start setup-and-start-human setup-kubernetes-infra stop-all-containers restart-all-containers clean-karmada-deployments clean-all help start-auto-mode start-human-loop-mode run-auto-mode run-all-containers run-all-containers-human

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
start-simulator:
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

# Cleans all documents from all collections in the mongo container
clean-mongo-db:
	@echo "Cleaning all documents from all collections in mongo container..."
	@container_id=$$(sudo docker ps -q -f name=mongo); \
	if [ -z "$$container_id" ]; then \
		echo "Mongo container is not running. Nothing to clean."; \
		exit 0; \
	fi; \
	js='dbs=db.getMongo().getDBNames().filter(function(x){return ["admin","local","config"].indexOf(x)<0});dbs.forEach(function(dbName){db=db.getSiblingDB(dbName);db.getCollectionNames().forEach(function(coll){db[coll].deleteMany({});});});'; \
	sudo docker exec $$container_id mongosh --quiet --eval "$$js"; \
	echo "All documents removed from all user collections via mongosh in container."

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

restart-all-containers: stop-all-containers run-all-containers
	@echo "All services have been fully restarted."

# Para derrubar os containers KIND do cluster
stop-kubernetes-infra:
	@echo "Parando containers KIND do cluster..."
	kind delete cluster --name member1 || true
	kind delete cluster --name member2 || true
	kind delete cluster --name karmada-host || true
	@echo "Clusters KIND removidos."

# Stops and removes all simulator containers, volumes, and images
stop-all-containers:
	@if ! command -v docker >/dev/null 2>&1; then \
		echo "docker não encontrado — pulando limpeza de containers (ambiente novo; os pré-requisitos serão instalados no setup)."; \
	else \
		echo "Stopping and removing all containers and volumes defined in compose.yaml..."; \
		sudo $(COMPOSE) -f compose.yaml down -v || true; \
		echo "Removing images..."; \
		mongo_image_ids=$$(sudo docker images --format '{{.ID}} {{.Repository}}' | grep mongo | awk '{print $$1}'); \
		for img in $$(sudo docker images -q); do \
			if ! echo "$$mongo_image_ids" | grep -q "$$img"; then \
				sudo docker rmi -f $$img 2>/dev/null || true; \
			fi; \
		done; \
		echo "Cleanup process completed."; \
	fi

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
	@echo "� Container Management:"
	@echo "  run-all-containers                : Starts all required containers via docker-compose"
	@echo "  restart-all-containers            : Stops, removes, and recreates all containers"
	@echo "  stop-all-containers               : Stops and removes all simulator containers"
	@echo ""
	@echo "🗄️  Database:"
	@echo "  clean-mongo-db                    : Cleans all documents from MongoDB collections"
	@echo ""
	@echo "🧹 Cleanup:"
	@echo "  clean-karmada-deployments         : Deletes all deployments and jobs from Karmada"
	@echo "  clean-all                         : Cleans Karmada deployments + MongoDB"
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