# omi-local Mode

This document tracks the `omi-local` runtime for the desktop app. The design
goal is to keep the fork sync-friendly with upstream: small guards, local
adapters, and explicit environment flags instead of broad rewrites.

## Run

```bash
cd desktop
./run-local.sh
```

`run-local.sh` starts the app as `Omi Local.app` with bundle id
`com.omi.omi-local` and launch argument `--local-mode`. It does not touch the
production app bundle.

By default, `run-local.sh` also starts `scripts/run-local-speech.sh` on
`127.0.0.1:10202` for local STT/TTS. Disable that with
`OMI_LOCAL_SPEECH_AUTOSTART=0`.

## LLM Exception

`omi-local` keeps speech, auth shims, storage, and app traffic local. The only
intentional remote exception is LLM inference through OpenAI Codex using your
ChatGPT subscription OAuth.

Authenticate once through pi-mono's OpenAI Codex OAuth flow:

```bash
cd desktop
./scripts/login-openai-codex.mjs
```

That writes OAuth credentials to `~/.pi/agent/auth.json` with user-only file
permissions. If the browser does not return to `localhost:1455` automatically,
paste the full redirect URL into the terminal prompt. Then run local mode with:

```bash
cat >> ~/.omi.env <<'EOF'
OMI_REMOTE_LLM_PROVIDER=openai-codex
OMI_REMOTE_LLM_MODEL=gpt-5.5
EOF
```

`openai-codex` uses pi-mono's `~/.pi/agent/auth.json`; no `OPENAI_API_KEY` is
needed. `OMI_REMOTE_LLM_PROVIDER=openai` remains available as a deliberate API
key fallback, but it is not the `omi-local` default.

## Current Guarantees

- Local deterministic auth is enabled with user id `local-user`.
- Firebase bootstrap is skipped in local mode.
- `GoogleService-Info*.plist` files are not copied into the local app bundle,
  including Swift resource bundles.
- Sparkle, Sentry, Mixpanel, PostHog, Heap startup, API-key fetches, and startup
  network syncs are disabled in local mode.
- App HTTP/WebSocket requests are guarded by `LocalNetworkPolicy`.
- External egress is blocked by default in local mode. Loopback is allowed.
- LAN hosts are opt-in with `OMI_LOCAL_ALLOW_LAN=1`.
- External egress is only for deliberate break-glass testing with
  `OMI_LOCAL_ALLOW_EGRESS=1`.
- The bundled Swift URLSession guard blocks app-level external egress; the
  `pi-mono` Node subprocess may reach OpenAI only when
  `OMI_REMOTE_LLM_PROVIDER=openai-codex` has OAuth credentials in
  `~/.pi/agent/auth.json` or when the explicit API-key fallback is configured.
- Cloud agent VM provisioning and agent sync are disabled in local mode.
- Screen activity sync to the upstream backend is disabled in local mode.
- Agent bridge, AI proxy, transcription, and TTS proxy are disabled by default
  until a local provider is explicitly configured.
- Knowledge graph fetches use local storage in local mode.

## Local Provider Flags

Use these only when the matching local service is running on loopback or an
allowed LAN host.

- `OMI_LOCAL_AGENT_BRIDGE=1`: allow the bundled agent bridge to start.
- `OMI_LOCAL_LLM_BASE_URL=http://127.0.0.1:<port>`: mark local LLM as available
  for bridge flows that know how to use it.
- `OMI_LOCAL_AI_PROXY_URL=http://127.0.0.1:<port>`: local replacement for the
  app's Gemini proxy endpoints.
- `OMI_LOCAL_AI_ENABLED=1`: use `OMI_API_URL` as the local AI proxy base.
- `OMI_LOCAL_TRANSCRIPTION_URL=http://127.0.0.1:<port>`: local transcription
  backend.
- `OMI_LOCAL_TRANSCRIPTION_ENABLED=1`: use the local API URL for transcription.
- `OMI_LOCAL_TTS_URL=http://127.0.0.1:<port>`: local TTS backend.
- `OMI_LOCAL_TTS_ENABLED=1`: allow TTS through the local TTS proxy. Without this
  flag, macOS system speech is used directly.
- `OMI_REMOTE_LLM_PROVIDER=openai-codex`: allow the agent bridge to use pi-mono's
  OpenAI Codex OAuth provider instead of the Omi/Firebase provider.
- `OMI_REMOTE_LLM_MODEL=gpt-5.5`: default remote model in `omi-local`. Keep this
  aligned with pi-mono's `openai-codex` catalog after future upstream syncs.
- `OMI_LOCAL_ALLOW_LAN=1`: allow RFC1918 and `.local` hosts.
- `OMI_LOCAL_ALLOW_EGRESS=1`: break-glass override for external egress.

## Local Speech

Setup:

```bash
cd desktop
./scripts/setup-local-speech.sh
./scripts/install-local-speech-launch-agent.sh
```

Run:

```bash
./scripts/run-local-speech.sh
curl -s http://127.0.0.1:10202/health | jq
```

STT uses `whisper.cpp` and the model pointed to by `WHISPER_MODEL_PATH`.
TTS uses macOS `say` through the same loopback service. This is intentionally
simple and deterministic; Kokoro or Qwen TTS can be added later behind the same
`/v1/tts/synthesize` route without changing the app.

## Sync-Friendly Patch Rules

- Keep `omi-local` behavior behind `LocalMode` or local service adapters.
- Prefer early returns and provider interfaces over deleting upstream features.
- Keep local runtime names separate: `Omi Local.app`, `com.omi.omi-local`.
- Do not touch `/Applications/omi.app` or `com.omi.computer-macos` during local
  testing.
- When upstream changes vendor flows, add local guards at the boundary rather
  than forking the feature internally.
- Keep this file and the root agent docs current when local-mode rules change.

## Remaining Work

1. Local API service on `127.0.0.1:10201` implementing the desktop/Python routes
   the app expects.
2. Replace the basic local speech bridge with higher-quality providers where
   needed: Whisper medium/large for STT, Kokoro/Qwen for TTS.
3. Local embedding proxy with the app's existing proxy route shape, wired to
   `OMI_LOCAL_AI_PROXY_URL`.
4. Automated egress tests that fail if local mode reaches nonlocal hosts, except
   the explicit OpenAI LLM subprocess.
5. Optional compile-time vendor pruning once the local runtime is stable. This
   is intentionally later because removing SDKs from the build graph is more
   invasive and harder to sync with upstream.

## Verification Checklist

```bash
xcrun swift build -c debug --package-path Desktop
npm --prefix agent run build
./scripts/run-local-speech.sh
curl -s http://127.0.0.1:10202/health | jq
./run-local.sh
pgrep -fal "Omi Local|Omi Computer|Resources/agent/dist/index.js"
find "/Applications/Omi Local.app/Contents/Resources" -name "GoogleService-Info*.plist" -print
rg -n "FIREBASE_API_KEY|GOOGLE|MIXPANEL|POSTHOG|SENTRY" "/Applications/Omi Local.app/Contents/Resources/.env"
lsof -Pan -p <omi-local-pid> -i
```

Expected local-mode evidence:

- One `Omi Computer --local-mode` process.
- No `Resources/agent/dist/index.js` process unless explicitly enabled.
- No `GoogleService-Info*.plist` in the local app bundle.
- No vendor keys in the bundled `.env`.
- No open external network sockets at idle.
- Agent bridge starts only after `~/.pi/agent/auth.json` contains an
  `openai-codex` OAuth credential.
