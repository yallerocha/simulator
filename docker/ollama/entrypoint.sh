#!/bin/bash
# =============================================================================
# entrypoint.sh — Inicia o Ollama, puxa modelos base e cria variantes
# customizadas via Modelfile com num_ctx e num_thread do config.yaml.
# =============================================================================
set -e

CONFIG_FILE="${OLLAMA_MODELS_CONFIG:-/app/ollama_models.yaml}"
MODELFILE_DIR="/tmp/ollama-modelfiles"
READY_FILE="/tmp/ollama-ready"
mkdir -p "$MODELFILE_DIR"
rm -f "$READY_FILE"  # limpa sinal de prontidão de boot anterior

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

    # Extrai apenas o modelo selecionado do YAML usando python (disponível no miniforge)
    python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, yaml, subprocess, os

config_path = sys.argv[1]
modelfile_dir = "/tmp/ollama-modelfiles"

with open(config_path) as f:
    cfg = yaml.safe_load(f)

# Navega para a seção ai — suporta ambas as estruturas de config
ai_cfg = cfg.get("ai-engine", cfg).get("ai", cfg.get("ai", {}))
models = ai_cfg.get("models", {})
selected = ai_cfg.get("selected_model")

if not selected:
    print("[entrypoint] ⚠️ Nenhum selected_model definido no config. Pulando provisionamento.")
    sys.exit(0)

model_cfg = models.get(selected, {})
provider = model_cfg.get("provider", "")

if provider != "ollama":
    print(f"[entrypoint] ℹ️ Modelo selecionado '{selected}' usa provider '{provider}', não é ollama. Pulando.")
    sys.exit(0)

base_model = model_cfg.get("model_name", selected)
ollama_cfg = model_cfg.get("ollama_config", {})
num_ctx = ollama_cfg.get("num_ctx")
num_thread = ollama_cfg.get("num_thread")
# num_gpu: nº de camadas na GPU. 0 = CPU puro; valor alto (ex.: 999) = todas as
# camadas na GPU; ausente = Ollama decide sozinho (usa GPU se disponível).
# Testar "is not None" porque 0 é válido e significa desligar a GPU.
num_gpu = ollama_cfg.get("num_gpu")

# Puxa apenas o modelo selecionado
print(f"[entrypoint] Puxando modelo selecionado: {base_model}")
subprocess.run(["ollama", "pull", base_model], check=True)

# Se tem parâmetros customizados, cria uma variante via Modelfile
if num_ctx or num_thread or num_gpu is not None:
    modelfile_path = os.path.join(modelfile_dir, f"{selected.replace(':', '_')}.Modelfile")

    mode = "CPU (num_gpu=0)" if num_gpu == 0 else (f"GPU (num_gpu={num_gpu})" if num_gpu is not None else "GPU (auto)")
    print(f"[entrypoint] Criando Modelfile para {base_model} (num_ctx={num_ctx}, num_thread={num_thread}, modo={mode})")
    with open(modelfile_path, "w") as mf:
        mf.write(f"FROM {base_model}\n")
        if num_ctx:
            mf.write(f"PARAMETER num_ctx {num_ctx}\n")
        if num_thread:
            mf.write(f"PARAMETER num_thread {num_thread}\n")
        if num_gpu is not None:
            mf.write(f"PARAMETER num_gpu {num_gpu}\n")

    print(f"[entrypoint] Aplicando Modelfile em: {base_model}")
    subprocess.run(["ollama", "create", base_model, "-f", modelfile_path], check=True)
    print(f"[entrypoint] ✅ Modelo {base_model} configurado (num_ctx={num_ctx}, num_thread={num_thread}, modo={mode})")
else:
    print(f"[entrypoint] ✅ Modelo {base_model} pronto (sem parâmetros custom)")
PYEOF

    echo "[entrypoint] Todos os modelos provisionados."
else
    echo "[entrypoint] Sem config ($CONFIG_FILE), puxando modelo padrão..."
    ollama pull qwen3:8b
fi

# ----- 3. Sinaliza que o provisionamento terminou -----
touch "$READY_FILE"
echo "[entrypoint] ✅ Sinal de prontidão criado ($READY_FILE)"

echo "[entrypoint] Ollama pronto. Aguardando..."
wait $OLLAMA_PID
