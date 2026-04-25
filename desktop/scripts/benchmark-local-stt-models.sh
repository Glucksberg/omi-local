#!/bin/bash
set -euo pipefail

WHISPER_BIN="${WHISPER_CPP_BIN:-$(command -v whisper-cli || command -v whisper-cpp || true)}"
MODEL_DIR="${WHISPER_MODEL_DIR:-$HOME/Library/Application Support/Omi Local/models/whisper}"
RUNS="${OMI_LOCAL_STT_BENCH_RUNS:-2}"
THREADS="${WHISPER_THREADS:-4}"
TMP_DIR="$(mktemp -d /tmp/omi-local-stt-models.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ -z "$WHISPER_BIN" ]; then
  echo "ERROR: whisper-cli not found. Run ./scripts/setup-local-speech.sh first." >&2
  exit 1
fi

voice_for_locale() {
  local locale="$1"
  say -v '?' | awk -v locale="$locale" '$0 ~ locale { line=$0; sub(" " locale ".*", "", line); sub(/[[:space:]]+$/, "", line); print line; exit }'
}

make_case_audio() {
  local name="$1"
  local voice="$2"
  local text="$3"
  local aiff="$TMP_DIR/$name.aiff"
  local wav="$TMP_DIR/$name.wav"

  if [ -n "$voice" ]; then
    say -v "$voice" -o "$aiff" "$text"
  else
    say -o "$aiff" "$text"
  fi
  /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$aiff" "$wav"
  echo "$wav"
}

EN_TEXT="${OMI_LOCAL_STT_BENCH_EN_TEXT:-hello this is an omi local speech benchmark for everyday work}"
PT_TEXT="${OMI_LOCAL_STT_BENCH_PT_TEXT:-ola este e um teste local do omi para portugues e ingles no trabalho diario}"
EN_VOICE="${OMI_LOCAL_STT_BENCH_EN_VOICE:-$(voice_for_locale en_US)}"
PT_VOICE="${OMI_LOCAL_STT_BENCH_PT_VOICE:-$(voice_for_locale pt_BR)}"

EN_WAV="$(make_case_audio en "$EN_VOICE" "$EN_TEXT")"
PT_WAV="$(make_case_audio pt "$PT_VOICE" "$PT_TEXT")"

if [ "$#" -gt 0 ]; then
  MODELS=("$@")
else
  MODELS=(small medium)
fi

echo "Whisper binary: $WHISPER_BIN"
echo "Threads: $THREADS"
echo "Runs per case: $RUNS"
echo "English voice: ${EN_VOICE:-default}"
echo "Portuguese voice: ${PT_VOICE:-default}"
echo

run_case() {
  local model_name="$1"
  local model_path="$2"
  local case_name="$3"
  local wav_path="$4"

  for ((run = 1; run <= RUNS; run++)); do
    local output_base="$TMP_DIR/${model_name}-${case_name}-${run}"
    local log_path="$TMP_DIR/${model_name}-${case_name}-${run}.log"
    echo "== model=$model_name case=$case_name run=$run =="
    /usr/bin/time -p "$WHISPER_BIN" \
      -m "$model_path" \
      -f "$wav_path" \
      -otxt \
      -of "$output_base" \
      -l auto \
      -t "$THREADS" \
      -nt \
      >"$log_path" 2>&1
    cat "$output_base.txt"
    echo
    tail -n 8 "$log_path" | sed 's/^/  /'
    echo
  done
}

for model_name in "${MODELS[@]}"; do
  model_path="$MODEL_DIR/ggml-${model_name}.bin"
  if [ ! -f "$model_path" ]; then
    echo "== model=$model_name missing =="
    echo "Run: ./scripts/download-whisper-model.sh $model_name"
    echo
    continue
  fi
  run_case "$model_name" "$model_path" en "$EN_WAV"
  run_case "$model_name" "$model_path" pt "$PT_WAV"
done
