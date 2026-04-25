#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SPEECH_DIR="$PWD/local-speech"
VENV_DIR="$SPEECH_DIR/.venv"
MODEL_SIZE="${WHISPER_MODEL_SIZE:-small}"
MODEL_DIR="${WHISPER_MODEL_DIR:-$HOME/Library/Application Support/Omi Local/models/whisper}"
MODEL_PATH="${WHISPER_MODEL_PATH:-$MODEL_DIR/ggml-${MODEL_SIZE}.bin}"
ENV_FILE="$HOME/.omi.env"

python3 -m venv "$VENV_DIR"
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/pip" install -r "$SPEECH_DIR/requirements.txt"

WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
if [ -z "$WHISPER_BIN" ]; then
  if command -v brew >/dev/null 2>&1; then
    brew install whisper-cpp
  else
    echo "ERROR: whisper.cpp not found and Homebrew is unavailable."
    echo "Install whisper.cpp, then set WHISPER_CPP_BIN in $ENV_FILE."
    exit 1
  fi
fi
WHISPER_BIN="$(command -v whisper-cli || command -v whisper-cpp || true)"
if [ -z "$WHISPER_BIN" ]; then
  echo "ERROR: whisper.cpp installed, but whisper-cli/whisper-cpp is still not on PATH."
  exit 1
fi

mkdir -p "$MODEL_DIR"
if [ ! -f "$MODEL_PATH" ]; then
  curl -L --fail \
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL_SIZE}.bin" \
    -o "$MODEL_PATH"
fi

set_env_line() {
  local key="$1"
  local value="$2"
  local escaped
  escaped=$(printf "%s" "$value" | sed "s/'/'\\\\''/g")
  local encoded="'$escaped'"
  touch "$ENV_FILE"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i '' "s|^${key}=.*|${key}=${encoded}|" "$ENV_FILE"
  else
    echo "${key}=${encoded}" >> "$ENV_FILE"
  fi
}

set_env_line OMI_LOCAL_TRANSCRIPTION_URL "http://127.0.0.1:10202"
set_env_line OMI_LOCAL_TRANSCRIPTION_ENABLED "1"
set_env_line OMI_LOCAL_TTS_URL "http://127.0.0.1:10202"
set_env_line OMI_LOCAL_TTS_ENABLED "1"
set_env_line WHISPER_CPP_BIN "$WHISPER_BIN"
set_env_line WHISPER_MODEL_PATH "$MODEL_PATH"

echo "Local speech setup complete."
echo "Model: $MODEL_PATH"
echo "Run:   ./scripts/run-local-speech.sh"
