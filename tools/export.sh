#!/usr/bin/env bash
# Regenerates game/imported/ from data/ and re-imports it into Godot.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd tools/glacier-export && cargo run --release -- "$@")
(cd game && godot --headless --import)
