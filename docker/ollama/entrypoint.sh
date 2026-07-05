#!/bin/bash
# =============================================================================
# entrypoint.sh — Inicia o Ollama, puxa modelos base e cria variantes
# customizadas via Modelfile com num_ctx e num_thread do config.yaml.
# =============================================================================
set -e

CONFIG_FILE="${OLLAMA_MODELS_CONFIG:-/app/ollama_models.yaml}"
MODELFILE_DIR="/tmp/ollama-modelfiles"
mkdir -p "$MODELFILE_DIR"

# ----- 1. Inicia o servidor Ollama em background -----
echo "[entrypoint] Iniciando Ollama server..."
ollama serve &
OLLAMA_PID=$!

# Espera o servidor ficar pronto (tenta até 30s)
echo "[entrypoint] Aguardando servidor ficar pronto..."
for i in $(seq 1 30); do
    if ollama list &>/dev/null; then
        echo "[entrypoint] Servidor pronto."
        break
    fi
    sleep 1
done

# ----- 2. Lê config e provisiona modelos -----
if [ -f "$CONFIG_FILE" ]; then
    echo "[entrypoint] Lendo configuração de modelos de: $CONFIG_FILE"

    # Extrai lista de modelos ollama do YAML usando python (disponível no miniforge)
    python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, yaml, subprocess, os

config_path = sys.argv[1]
modelfile_dir = "/tmp/ollama-modelfiles"

with open(config_path) as f:
    cfg = yaml.safe_load(f)

# Navega para a seção de modelos — suporta ambas as estruturas de config
ai_cfg = cfg.get("ai-engine", cfg).get("ai", cfg.get("ai", {}))
models = ai_cfg.get("models", {})

for model_key, model_cfg in models.items():
    provider = model_cfg.get("provider", "")
    if provider != "ollama":
        continue

    base_model = model_cfg.get("model_name", model_key)
    ollama_cfg = model_cfg.get("ollama_config", {})
    num_ctx = ollama_cfg.get("num_ctx")
    num_thread = ollama_cfg.get("num_thread")

    # Puxa o modelo base primeiro
    print(f"[entrypoint] Puxando modelo base: {base_model}")
    subprocess.run(["ollama", "pull", base_model], check=True)

    # Se tem parâmetros customizados, cria uma variante via Modelfile
    if num_ctx or num_thread:
        # Usa o MESMO nome do modelo base — o ollama create sobrescreve
        # a entrada local com os novos parâmetros, sem duplicar os pesos.
        modelfile_path = os.path.join(modelfile_dir, f"{model_key.replace(':', '_')}.Modelfile")

        print(f"[entrypoint] Criando Modelfile para {base_model} (num_ctx={num_ctx}, num_thread={num_thread})")
        with open(modelfile_path, "w") as mf:
            mf.write(f"FROM {base_model}\n")
            if num_ctx:
                mf.write(f"PARAMETER num_ctx {num_ctx}\n")
            if num_thread:
                mf.write(f"PARAMETER num_thread {num_thread}\n")

        print(f"[entrypoint] Aplicando Modelfile em: {base_model}")
        subprocess.run(["ollama", "create", base_model, "-f", modelfile_path], check=True)
        print(f"[entrypoint] ✅ Modelo {base_model} configurado (num_ctx={num_ctx}, num_thread={num_thread})")
    else:
        print(f"[entrypoint] ✅ Modelo {base_model} pronto (sem parâmetros custom)")
PYEOF

    echo "[entrypoint] Todos os modelos provisionados."
else
    echo "[entrypoint] Sem config ($CONFIG_FILE), puxando modelo padrão..."
    ollama pull qwen3:8b
fi

echo "[entrypoint] Ollama pronto. Aguardando..."
wait $OLLAMA_PID
