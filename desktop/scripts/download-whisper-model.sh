#!/bin/bash
set -euo pipefail

MODEL_SIZE="${1:-${WHISPER_MODEL_SIZE:-medium}}"
MODEL_DIR="${WHISPER_MODEL_DIR:-$HOME/Library/Application Support/Omi Local/models/whisper}"
MODEL_PATH="$MODEL_DIR/ggml-${MODEL_SIZE}.bin"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_SIZE}.bin"

mkdir -p "$MODEL_DIR"

echo "Downloading Whisper ${MODEL_SIZE} model to:"
echo "$MODEL_PATH"
curl -L --fail -C - "$MODEL_URL" -o "$MODEL_PATH"
echo "Downloaded: $MODEL_PATH"
