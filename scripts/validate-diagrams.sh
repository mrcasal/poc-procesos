#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d ".validate-diagrams.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT
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
  "$PYTHON_BIN" scripts/process_model.py validate "$model"
  if [[ ! -f "$svg" ]]; then
    echo "Missing SVG for $model: $svg"
    exit 1
  fi
done

mkdir -p "$TMP_DIR"
cp -R docs "$TMP_DIR/docs"

while IFS= read -r model; do
  process_dir="$(dirname "$model")"
  svg="$process_dir/process.svg"
  "$PYTHON_BIN" scripts/process_model.py render-svg "$model" "$svg"
done < <(find "$TMP_DIR/docs/processes" -name process.yaml -type f | sort)

changed=0
for model in "${models[@]}"; do
  svg="$(dirname "$model")/process.svg"
  if ! cmp --silent "$svg" "$TMP_DIR/$svg"; then
    echo "Outdated SVG: $svg"
    changed=1
  fi
done

if [[ "$changed" -ne 0 ]]; then
    echo "Run make diagrams and commit the updated diagram artifacts."
  exit 1
fi

echo "All process models are valid and diagram artifacts are up to date."
