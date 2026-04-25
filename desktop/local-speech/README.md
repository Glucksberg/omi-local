# Omi Local Speech

Loopback-only speech service for omi-local mode. The server rejects non-loopback
HTTP and WebSocket clients by default, even if it is accidentally started on a
wide network bind.

- STT: `whisper.cpp` through `/v2/voice-message/transcribe`,
  `/v2/voice-message/transcribe-stream`, and `/v4/listen`.
- TTS: macOS `say` through `/v1/tts/synthesize`.

Run:

```bash
cd desktop
./scripts/setup-local-speech.sh
./scripts/run-local-speech.sh
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
```

`OMI_LOCAL_SPEECH_REQUIRE_LOOPBACK=0` disables the loopback guard, but that is
not recommended unless the service is protected by another local network control.
