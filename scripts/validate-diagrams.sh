#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$ROOT_DIR"

models=()
while IFS= read -r model; do
  models+=("$model")
done < <(find docs/processes -name process.yaml -type f | sort)

if [[ ${#models[@]} -eq 0 ]]; then
  echo "No process.yaml files found under docs/processes"
  exit 0
fi

svgs=()
for model in "${models[@]}"; do
  process_dir="$(dirname "$model")"
  layout="$process_dir/layout.yaml"
  svg="$process_dir/process.svg"
  ruby scripts/process-model.rb validate "$model" "$layout"
  svgs+=("$svg")
  if [[ ! -f "$svg" ]]; then
    echo "Missing SVG for $model: $svg"
    exit 1
  fi
done

mkdir -p "$TMP_DIR"
cp -R docs "$TMP_DIR/docs"

while IFS= read -r model; do
  process_dir="$(dirname "$model")"
  layout="$process_dir/layout.yaml"
  svg="$process_dir/process.svg"
  ruby scripts/process-model.rb render-svg "$model" "$layout" "$svg"
done < <(find "$TMP_DIR/docs/processes" -name process.yaml -type f | sort)

changed=0
for svg in "${svgs[@]}"; do
  if ! cmp --silent "$svg" "$TMP_DIR/$svg"; then
    echo "Outdated SVG: $svg"
    changed=1
  fi
done

if [[ "$changed" -ne 0 ]]; then
  echo "Run make diagrams and commit the updated SVG files."
  exit 1
fi

echo "All process models are valid and SVG files are up to date."
