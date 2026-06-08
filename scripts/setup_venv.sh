#!/bin/bash
# Script para criar venv e instalar dependências do requirements.txt
set -e

VENV_DIR="../venv"
REQ_FILE="../analyzer/requirements.txt"

# Em ppc64le (e em qualquer máquina que traga conda/mamba) normalmente NÃO há
# wheels pip prontos, então compilar pandas/numpy do zero falha (exige GCC>=9.3).
# Preferimos o conda-forge, que tem binários ppc64le. O ambiente é criado no
# prefixo $VENV_DIR, então o downstream continua usando ../venv/bin/python.
CONDA_BIN="$(command -v mamba || command -v conda || true)"

if [ -n "$CONDA_BIN" ]; then
    echo "🐍 Usando conda-forge ($CONDA_BIN) para o ambiente do analyzer..."

    # Idempotente: se o env já existe e importa tudo, não refaz nada.
    if [ -x "$VENV_DIR/bin/python" ] && \
       "$VENV_DIR/bin/python" -c "import pandas, matplotlib, seaborn, plotnine" 2>/dev/null; then
        echo "✅ Ambiente conda já existe e está completo."
        exit 0
    fi

    # Converte specs do pip ("pkg==x.y") para o formato conda ("pkg=x.y").
    mapfile -t SPECS < <(grep -vE '^[[:space:]]*(#|$)' "$REQ_FILE" | sed 's/==/=/')

    rm -rf "$VENV_DIR"
    "$CONDA_BIN" create -p "$VENV_DIR" -y python=3.13 "${SPECS[@]}" -c conda-forge
    echo "✅ Ambiente conda criado e dependências instaladas."
    exit 0
fi

# Fallback: venv padrão + pip (onde há wheels prontos, ex.: x86_64).
if [ ! -d "$VENV_DIR" ]; then
    echo "Criando ambiente virtual..."
    python3 -m venv "$VENV_DIR"
elif [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "Reparando ambiente virtual corrompido..."
    python3 -m venv --clear "$VENV_DIR"
fi

# Verifica se o reparo foi bem-sucedido
if [ ! -f "$VENV_DIR/bin/activate" ]; then
    echo "❌ Erro: Falha ao criar/reparar ambiente virtual"
    exit 1
fi

# Ativa venv
source "$VENV_DIR/bin/activate"

# Instala dependências
pip install --upgrade pip
pip install -r "$REQ_FILE"

echo "Ambiente virtual criado e dependências instaladas."
