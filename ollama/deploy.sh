#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${1:-./modelfiles}"
CONTAINER="${OLLAMA_CONTAINER:-ollama}"
DEST_DIR="/tmp/modelfiles"

# Pick runtime
if command -v podman >/dev/null 2>&1 && podman container exists "$CONTAINER" 2>/dev/null; then
    RT=podman
elif command -v docker >/dev/null 2>&1; then
    RT=docker
else
    echo "No podman or docker found." >&2
    exit 1
fi

# Verify container is running
if ! $RT ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "Container '$CONTAINER' is not running." >&2
    exit 1
fi

# Verify source
[[ -d "$SRC_DIR" ]] || { echo "Not a directory: $SRC_DIR" >&2; exit 1; }

shopt -s nullglob
files=("$SRC_DIR"/*.model)
(( ${#files[@]} )) || { echo "No .model files in $SRC_DIR" >&2; exit 1; }

# Copy
echo "Copying ${#files[@]} modelfile(s) to $CONTAINER:$DEST_DIR"
$RT exec "$CONTAINER" rm -rf "$DEST_DIR"
$RT exec "$CONTAINER" mkdir -p "$DEST_DIR"
$RT cp "$SRC_DIR/." "$CONTAINER:$DEST_DIR"

# Create
ok=0
fail=0
for f in "${files[@]}"; do
    base="$(basename "$f")"
    name="${base%.model}"

    echo "--- $name"
    if $RT exec "$CONTAINER" ollama create "$name" -f "$DEST_DIR/$base"; then
        ok=$((ok+1))
    else
        echo "FAILED: $name" >&2
        fail=$((fail+1))
    fi
done

$RT exec "$CONTAINER" rm -rf "$DEST_DIR"

echo
echo "Created: $ok  Failed: $fail"
$RT exec "$CONTAINER" ollama list
(( fail == 0 ))