#!/usr/bin/env python3
# =============================================================================
# wait_for_ollama.py — Blocks until the configured local LLM is fully ready.
# =============================================================================
import sys
import time
import json
import urllib.request
import urllib.error

CONFIG_PATH = "simulator/data/config.yaml"
OLLAMA_URL = "http://localhost:11434"

def parse_config(path):
    """
    Parses simulator config yaml to find selected_model and its provider.
    Avoids requiring pyyaml on the host by doing a simple line-by-line parsing.
    """
    selected_model = None
    provider = None
    in_models_section = False
    model_providers = {}

    try:
        with open(path, "r") as f:
            for line in f:
                line_stripped = line.strip()
                if not line_stripped or line_stripped.startswith("#"):
                    continue
                
                # Check selected model
                if line_stripped.startswith("selected_model:"):
                    selected_model = line_stripped.split(":", 1)[1].strip()
                    # Strip quotes or inline comments
                    selected_model = selected_model.split("#")[0].strip().replace("\"", "").replace("'", "")
                
                # Check models block
                if line_stripped.startswith("models:"):
                    in_models_section = True
                    continue
                
                # Detect end of models block by indentation
                if in_models_section and line.startswith("  ") and not line.startswith("    "):
                    # Check if it's a key in models
                    current_model = line_stripped.replace(":", "").strip()
                    # Read lines below to find its provider
                    # Simple heuristic: scan until next model or indentation change
                    model_providers[current_model] = None
                
                # Simple parser helper to map providers
                if in_models_section and line_stripped.startswith("provider:"):
                    prov = line_stripped.split(":", 1)[1].strip().split("#")[0].strip()
                    # Associate with the last model found
                    if model_providers:
                        last_model = list(model_providers.keys())[-1]
                        model_providers[last_model] = prov

    except Exception as e:
        print(f"⚠️ Error parsing config: {e}. Defaulting to check for qwen3:8b.")
        return "qwen3:8b", "ollama"

    # Determine provider of selected model
    provider = model_providers.get(selected_model)
    if not provider:
        # Fallback search if simple parsing missed it
        if "ollama" in selected_model or selected_model in ["qwen3:8b", "llama3.1:8b", "gemma3:4b"]:
            provider = "ollama"
        else:
            provider = "openrouter" # default legacy fallback

    return selected_model, provider

def get_installed_models():
    """Queries Ollama local tags endpoint."""
    try:
        req = urllib.request.Request(f"{OLLAMA_URL}/api/tags")
        with urllib.request.urlopen(req, timeout=3) as response:
            data = json.loads(response.read().decode())
            return [m["name"] for m in data.get("models", [])]
    except Exception:
        return []

def is_ollama_running():
    """Checks if Ollama API port is open/responding."""
    try:
        urllib.request.urlopen(OLLAMA_URL, timeout=2)
        return True
    except urllib.error.HTTPError:
        return True # Ollama returns 404 or 200 depending on version, both mean port is active
    except Exception:
        return False

def main():
    model, provider = parse_config(CONFIG_PATH)
    
    if provider != "ollama":
        print(f"ℹ️ Selected model '{model}' uses provider '{provider}'. No local model check required.")
        return 0

    print(f"🔍 Monitoring local Ollama for model: \033[1;36m{model}\033[0m")
    
    # 1. Wait for Ollama service to start up
    started = False
    for i in range(30):
        if is_ollama_running():
            started = True
            break
        print("⏳ Waiting for Ollama service to start...", end="\r")
        time.sleep(1)
    
    if not started:
        print("\n❌ Timeout: Ollama service port 11434 is not responding.")
        return 1

    print("✅ Ollama service is up and running.")

    # 2. Wait for the model to be fully pulled/created
    start_time = time.time()
    try:
        while True:
            models = get_installed_models()
            # Match base name or exact name (ollama tag normalization)
            matched = any(model in m or m in model for m in models)
            
            if matched:
                print(f"\n✅ Model '{model}' is ready and fully downloaded! Let's start the simulation.")
                return 0
            
            elapsed = int(time.time() - start_time)
            print(f"⏳ Waiting for '{model}' to finish downloading... (elapsed: {elapsed}s)", end="\r")
            time.sleep(5)
    except KeyboardInterrupt:
        print("\n⏹ Wait cancelled by user.")
        return 130

if __name__ == "__main__":
    sys.exit(main())
