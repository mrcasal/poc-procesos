#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  layout="$process_dir/layout.yaml"
  svg="$process_dir/process.svg"
  ruby scripts/process-model.rb render-svg "$model" "$layout" "$svg"
done
