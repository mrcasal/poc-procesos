#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLANTUML_VERSION="${PLANTUML_VERSION:-1.2024.8}"
PLANTUML_CACHE_DIR="${PLANTUML_CACHE_DIR:-$ROOT_DIR/.cache/plantuml}"
PLANTUML_JAR="$PLANTUML_CACHE_DIR/plantuml-$PLANTUML_VERSION.jar"
PLANTUML_URL="https://repo1.maven.org/maven2/net/sourceforge/plantuml/plantuml/$PLANTUML_VERSION/plantuml-$PLANTUML_VERSION.jar"
PLANTUML_SERVER_URL="${PLANTUML_SERVER_URL:-https://www.plantuml.com/plantuml}"

cd "$ROOT_DIR"

diagrams=()
while IFS= read -r diagram; do
  diagrams+=("$diagram")
done < <(find docs/processes -name process.puml -type f | sort)

if [[ ${#diagrams[@]} -eq 0 ]]; then
  echo "No process.puml files found under docs/processes"
  exit 0
fi

render_with_plantuml() {
  plantuml -tsvg "${diagrams[@]}"
}

render_with_jar() {
  if [[ ! -f "$PLANTUML_JAR" ]]; then
    mkdir -p "$PLANTUML_CACHE_DIR"
    echo "Downloading PlantUML $PLANTUML_VERSION..."
    curl --fail --location --silent --show-error "$PLANTUML_URL" --output "$PLANTUML_JAR"
  fi

  java -jar "$PLANTUML_JAR" -tsvg "${diagrams[@]}"
}

render_with_docker() {
  docker run --rm \
    --volume "$ROOT_DIR:/workspace" \
    --workdir /workspace \
    plantuml/plantuml:"$PLANTUML_VERSION" \
    -tsvg "${diagrams[@]}"
}

plantuml_encode() {
  python3 - "$1" <<'PY'
import sys
import zlib

alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_"

def append3bytes(b1, b2, b3):
    c1 = b1 >> 2
    c2 = ((b1 & 0x3) << 4) | (b2 >> 4)
    c3 = ((b2 & 0xF) << 2) | (b3 >> 6)
    c4 = b3 & 0x3F
    return alphabet[c1] + alphabet[c2] + alphabet[c3] + alphabet[c4]

def encode64(data):
    result = []
    for i in range(0, len(data), 3):
        chunk = data[i:i + 3]
        if len(chunk) == 3:
            result.append(append3bytes(chunk[0], chunk[1], chunk[2]))
        elif len(chunk) == 2:
            result.append(append3bytes(chunk[0], chunk[1], 0)[:3])
        else:
            result.append(append3bytes(chunk[0], 0, 0)[:2])
    return "".join(result)

source_path = sys.argv[1]
with open(source_path, "rb") as source:
    payload = source.read()

compressed = zlib.compress(payload)[2:-4]
print(encode64(compressed))
PY
}

render_with_server() {
  for source in "${diagrams[@]}"; do
    encoded="$(plantuml_encode "$source")"
    curl --fail --location --silent --show-error \
      "$PLANTUML_SERVER_URL/svg/$encoded" \
      --output "${source%.puml}.svg"
  done
}

java_available() {
  command -v java >/dev/null 2>&1 && java -version >/dev/null 2>&1
}

if command -v plantuml >/dev/null 2>&1; then
  render_with_plantuml
elif java_available && command -v curl >/dev/null 2>&1; then
  render_with_jar
elif command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  render_with_server
elif command -v docker >/dev/null 2>&1; then
  render_with_docker
else
  echo "PlantUML renderer not available. Install plantuml, provide Java + curl, Docker, or python3 + curl for server rendering." >&2
  exit 1
fi

for source in "${diagrams[@]}"; do
  svg="${source%.puml}.svg"
  if [[ ! -f "$svg" ]]; then
    echo "Expected SVG was not generated: $svg" >&2
    exit 1
  fi
done
