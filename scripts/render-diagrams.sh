#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  echo "Python no está disponible. Instálalo o define PYTHON_BIN con la ruta al ejecutable."
  exit 1
fi

cd "$ROOT_DIR"

models=()
while IFS= read -r model; do
  models+=("$model")
done < <(find docs/processes -name process.yaml -type f | sort)

if [[ ${#models[@]} -eq 0 ]]; then
  echo "No process.yaml files found under docs/processes"
  exit 0
fi

for model in "${models[@]}"; do
  process_dir="$(dirname "$model")"
  svg="$process_dir/process.svg"
  "$PYTHON_BIN" scripts/process_model.py render-svg "$model" "$svg"
done
