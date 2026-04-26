# Omi Local Speech

Loopback-only speech service for omi-local mode. The server rejects non-loopback
HTTP and WebSocket clients by default, even if it is accidentally started on a
wide network bind.

- STT: `whisper.cpp` through `/v2/voice-message/transcribe`,
  `/v2/voice-message/transcribe-stream`, and `/v4/listen`.
- TTS: macOS `say` by default, optional Kokoro-ONNX, or xAI TTS through
  `/v1/tts/synthesize`.
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
./scripts/benchmark-local-stt-models.sh
./scripts/benchmark-local-tts.sh
```

Run persistently as a user LaunchAgent:

```bash
./scripts/install-local-speech-launch-agent.sh
```

The setup script installs Python dependencies into `local-speech/.venv`,
installs `whisper-cpp` with Homebrew if needed, downloads a default
`ggml-small.bin` model, sets transcription language detection to `auto`, and
writes non-secret loopback settings to `~/.omi.env`. It also sets a small
Whisper initial prompt for `Omi`/`Omi Local`, because the local path does not use
the cloud provider vocabulary API.

Download another Whisper model without changing the active service:

```bash
./scripts/download-whisper-model.sh medium
./scripts/benchmark-local-stt-models.sh small medium
```

Enable local neural TTS with Kokoro-ONNX:

```bash
./scripts/setup-local-kokoro.sh
./scripts/install-local-speech-launch-agent.sh
./scripts/benchmark-local-tts.sh
```

Enable remote xAI TTS while keeping STT and LLM routing unchanged:

```bash
OMI_LOCAL_TTS_PROVIDER=xai
OMI_LOCAL_XAI_TTS_VOICE=ara
OMI_LOCAL_XAI_TTS_LANGUAGE=auto
OMI_LOCAL_XAI_TTS_CODEC=mp3
OMI_LOCAL_XAI_TTS_SAMPLE_RATE=24000
OMI_LOCAL_XAI_TTS_BIT_RATE=128000
```

Store the real key in macOS Keychain, or export `XAI_API_KEY` in your shell for
one-off tests:

```bash
security add-generic-password -a "$USER" -s omi-local-xai-tts-api-key -w "$XAI_API_KEY" -U
```

The xAI provider uses `POST https://api.x.ai/v1/tts` from the local loopback
speech service. The desktop app still calls only `/v1/tts/synthesize`, so the
API key is not passed to Swift UI code. Supported voice defaults are `ara`,
`eve`, `leo`, `rex`, and `sal`; `auto` language works well when responses mix
Portuguese and English.

Useful overrides:

```bash
WHISPER_MODEL_SIZE=base ./scripts/setup-local-speech.sh
WHISPER_MODEL_PATH=/path/to/ggml-medium.bin ./scripts/run-local-speech.sh
OMI_LOCAL_TTS_VOICE=Samantha ./scripts/run-local-speech.sh
OMI_LOCAL_TTS_PROVIDER=kokoro ./scripts/run-local-speech.sh
OMI_LOCAL_TTS_PROVIDER=xai ./scripts/run-local-speech.sh
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

The service defaults to `language=auto`, and the desktop app sends `multi` when
auto-detect is enabled. Both paths map to Whisper language auto-detection.

TTS defaults to macOS `say`, so there is no neural TTS model to load in the
baseline. When `OMI_LOCAL_TTS_PROVIDER=kokoro` is set, the first Kokoro request
loads the ONNX session and voices file into the service process; the model stays
resident until the service restarts. Start with the `int8` Kokoro model for this
MacBook, then compare `fp16` only if voice quality is the limiting factor.

When `OMI_LOCAL_TTS_PROVIDER=xai` is set, no local TTS model is loaded. Each TTS
request is proxied to xAI and returns remote audio bytes, so local memory and
CPU usage stay low; latency depends on network and xAI response time.
