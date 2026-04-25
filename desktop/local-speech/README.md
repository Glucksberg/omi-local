# Omi Local Speech

Loopback-only speech service for omi-local mode. The server rejects non-loopback
HTTP and WebSocket clients by default, even if it is accidentally started on a
wide network bind.

- STT: `whisper.cpp` through `/v2/voice-message/transcribe`,
  `/v2/voice-message/transcribe-stream`, and `/v4/listen`.
- TTS: macOS `say` through `/v1/tts/synthesize`.
- Observability: `/health` reports model metadata, concurrency config, request
  counts, in-flight work, last duration, and last error.
- Warmup: `POST /warmup` runs a tiny silent transcription to warm the OS file
  cache for the configured Whisper model.

Run:

```bash
cd desktop
./scripts/setup-local-speech.sh
./scripts/run-local-speech.sh
```

Benchmark the current setup:

```bash
./scripts/benchmark-local-speech.sh
```

Run persistently as a user LaunchAgent:

```bash
./scripts/install-local-speech-launch-agent.sh
```

The setup script installs Python dependencies into `local-speech/.venv`,
installs `whisper-cpp` with Homebrew if needed, downloads a default
`ggml-small.bin` model, and writes non-secret loopback settings to
`~/.omi.env`.

Useful overrides:

```bash
WHISPER_MODEL_SIZE=base ./scripts/setup-local-speech.sh
WHISPER_MODEL_PATH=/path/to/ggml-medium.bin ./scripts/run-local-speech.sh
OMI_LOCAL_TTS_VOICE=Samantha ./scripts/run-local-speech.sh
OMI_LOCAL_SPEECH_WARMUP_ON_START=1 ./scripts/run-local-speech.sh
```

`OMI_LOCAL_SPEECH_REQUIRE_LOOPBACK=0` disables the loopback guard, but that is
not recommended unless the service is protected by another local network control.

## Load Behavior

The current STT path uses `whisper-cli` per request. The model is not kept in a
resident Python object; each request starts `whisper-cli`, which opens the model,
transcribes, then exits. After the first request, macOS usually keeps the model
file in the filesystem cache, so repeated calls are faster even though the
process is not resident.

Set `OMI_LOCAL_STT_MAX_CONCURRENCY=1` unless you are deliberately testing
parallel transcription. Larger Whisper models can otherwise spawn competing
processes and make the laptop feel sluggish.

Model starting points for this laptop:

- `base`: fastest smoke tests, lower accuracy.
- `small`: current default, reasonable latency and quality.
- `medium`: better accuracy, noticeably more CPU/RAM and cold-load time.
- `large`: possible for batch tests, not recommended as the default until STT is
  moved to a resident backend.

TTS currently uses macOS `say`, so there is no local neural TTS model to load.
Kokoro or Qwen TTS should be added later behind `/v1/tts/synthesize` after this
baseline is stable.
