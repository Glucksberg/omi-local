#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SPEECH_DIR="$PWD/local-speech"
VENV_DIR="$SPEECH_DIR/.venv"
MODEL_DIR="${OMI_LOCAL_KOKORO_MODEL_DIR:-$HOME/Library/Application Support/Omi Local/models/kokoro}"
MODEL_VARIANT="${OMI_LOCAL_KOKORO_MODEL_VARIANT:-int8}"
ENV_FILE="$HOME/.omi.env"

case "$MODEL_VARIANT" in
  f32)
    MODEL_FILE="kokoro-v1.0.onnx"
    ;;
  fp16)
    MODEL_FILE="kokoro-v1.0.fp16.onnx"
    ;;
  int8)
    MODEL_FILE="kokoro-v1.0.int8.onnx"
    ;;
  *)
    echo "ERROR: OMI_LOCAL_KOKORO_MODEL_VARIANT must be one of: int8, fp16, f32" >&2
    exit 1
    ;;
esac

if [ ! -x "$VENV_DIR/bin/python" ]; then
  ./scripts/setup-local-speech.sh
fi

if ! command -v espeak-ng >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    brew install espeak-ng
  else
    echo "ERROR: espeak-ng is required for Kokoro phonemization." >&2
    exit 1
  fi
fi

"$VENV_DIR/bin/pip" install -r "$SPEECH_DIR/requirements-tts.txt"

mkdir -p "$MODEL_DIR"
MODEL_PATH="$MODEL_DIR/$MODEL_FILE"
VOICES_PATH="$MODEL_DIR/voices-v1.0.bin"
BASE_URL="https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0"

if [ ! -f "$MODEL_PATH" ]; then
  curl -L --fail -C - "$BASE_URL/$MODEL_FILE" -o "$MODEL_PATH"
fi

if [ ! -f "$VOICES_PATH" ]; then
  curl -L --fail -C - "$BASE_URL/voices-v1.0.bin" -o "$VOICES_PATH"
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

set_env_line OMI_LOCAL_TTS_PROVIDER "kokoro"
set_env_line OMI_LOCAL_KOKORO_MODEL_PATH "$MODEL_PATH"
set_env_line OMI_LOCAL_KOKORO_VOICES_PATH "$VOICES_PATH"
set_env_line OMI_LOCAL_KOKORO_VOICE "${OMI_LOCAL_KOKORO_VOICE:-pf_dora}"
set_env_line OMI_LOCAL_KOKORO_LANG "${OMI_LOCAL_KOKORO_LANG:-pt-br}"
set_env_line OMI_LOCAL_KOKORO_SPEED "${OMI_LOCAL_KOKORO_SPEED:-1.0}"

echo "Kokoro setup complete."
echo "Model:  $MODEL_PATH"
echo "Voices: $VOICES_PATH"
echo "Run:    ./scripts/run-local-speech.sh"
