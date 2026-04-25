#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

SPEECH_DIR="$PWD/local-speech"
VENV_DIR="$SPEECH_DIR/.venv"
HOST="${OMI_LOCAL_SPEECH_HOST:-127.0.0.1}"
PORT="${OMI_LOCAL_SPEECH_PORT:-10202}"

if [ ! -x "$VENV_DIR/bin/uvicorn" ]; then
  ./scripts/setup-local-speech.sh
fi

if [ -f "$HOME/.omi.env" ]; then
  while IFS='=' read -r key value; do
    case "$key" in
      OMI_LOCAL_TRANSCRIPTION_URL|OMI_LOCAL_TRANSCRIPTION_ENABLED|OMI_LOCAL_DEFAULT_TRANSCRIPTION_LANGUAGE|OMI_LOCAL_TTS_URL|OMI_LOCAL_TTS_ENABLED|OMI_LOCAL_TTS_PROVIDER|OMI_LOCAL_TTS_VOICE|OMI_LOCAL_TTS_RATE|OMI_LOCAL_KOKORO_MODEL_PATH|OMI_LOCAL_KOKORO_VOICES_PATH|OMI_LOCAL_KOKORO_VOICE|OMI_LOCAL_KOKORO_LANG|OMI_LOCAL_KOKORO_SPEED|OMI_LOCAL_SPEECH_MAX_AUDIO_BYTES|OMI_LOCAL_SPEECH_MAX_TTS_CHARS|OMI_LOCAL_SPEECH_STREAM_CHUNK_BYTES|OMI_LOCAL_SPEECH_REQUIRE_LOOPBACK|OMI_LOCAL_STT_MAX_CONCURRENCY|OMI_LOCAL_TTS_MAX_CONCURRENCY|OMI_LOCAL_SPEECH_QUEUE_TIMEOUT_SECONDS|OMI_LOCAL_SPEECH_WARMUP_ON_START|WHISPER_CPP_BIN|WHISPER_MODEL_PATH|WHISPER_THREADS|WHISPER_TIMEOUT_SECONDS|WHISPER_EXTRA_ARGS)
        value="${value%$'\r'}"
        value="${value#\"}"
        value="${value%\"}"
        value="${value#\'}"
        value="${value%\'}"
        export "$key=$value"
        ;;
    esac
  done < <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$HOME/.omi.env" || true)
fi

exec "$VENV_DIR/bin/uvicorn" server:app --app-dir "$SPEECH_DIR" --host "$HOST" --port "$PORT"
