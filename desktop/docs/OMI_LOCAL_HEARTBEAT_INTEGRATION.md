# Omi Local Heartbeat Integration

This document defines how Omi Local should combine upstream-style conversation
processing with the local Tom heartbeat.

## Goal

Omi Local should keep the useful shape of upstream Omi:

- ambient audio becomes conversations
- conversations become structured summaries, tasks, and memories
- personal context becomes useful advice

The local product adds one extra boundary:

- Tom heartbeat decides what deserves attention, promotion, or a morning brief.

The processing pipeline should structure data. The heartbeat should make
judgment calls.

## Current Shape

The current local audio path is:

```text
microphone/system audio
  -> AudioMixer
  -> local-speech /v4/listen
  -> whisper.cpp transcription
  -> local SQLite transcription_sessions/transcription_segments
  -> Conversations UI
```

The current heartbeat path is:

```text
HeartbeatScheduler
  -> ChatProvider.runHeartbeatTurn()
  -> TomMemory files and read-only Omi tools
  -> optional Markdown writes under TomMemory
  -> HEARTBEAT_LOG.md
  -> optional concise alert
```

These paths are adjacent, not fully integrated. The bridge should be a local
candidate layer.

## Target Architecture

```text
raw local sensors
  -> local capture stores
  -> local processors
  -> candidate queues
  -> heartbeat review and promotion
  -> TomMemory canon and user-facing briefs
```

Candidate queues should exist between processing and heartbeat:

- `memory_candidates`: durable facts that may belong in TomMemory.
- `action_candidates`: tasks or follow-ups that may belong in tasks.
- `advice_candidates`: observations that may become a notification or morning brief.
- `digest_items`: lightweight evidence for daily/morning summaries.

The heartbeat consumes candidates, not raw noise.

## Responsibilities

### Conversation Processor

Runs after a local conversation is completed.

It should:

- generate title and overview
- classify low-value/noisy transcripts
- extract action candidates
- extract memory candidates
- extract advice candidates
- store confidence, source segment IDs, and reasoning

It should not:

- write TomMemory canon directly
- notify the user directly
- infer sensitive identity facts from uncertain audio
- treat every transcript as meaningful

### Heartbeat

Runs periodically or manually.

It should:

- read recent candidates and TomMemory state
- promote only durable memory to Markdown
- suppress duplicates and low-confidence observations
- create a morning brief from the last 12 to 24 hours
- emit an alert only when it is timely and useful
- append an audit entry to `HEARTBEAT_LOG.md`

It should not:

- reprocess all raw transcripts every cycle
- write outside TomMemory
- send external data without explicit configuration
- make destructive changes

## Morning Brief

Morning brief should be a special heartbeat mode, not a separate product brain.

Suggested input window:

- conversations since previous morning brief, capped by token budget
- memory/advice/action candidates from the same window
- unread/high-confidence tasks
- relevant screen/OCR digest items if available
- TomMemory canon

Suggested output:

- 3 to 5 direct observations
- 1 to 3 concrete suggestions for today
- a short note on uncertainty when the source audio was noisy

The brief should be stored as a Markdown daily note and optionally surfaced as a
Tom heartbeat alert.

## Privacy Rules

Ambient transcription is high-sensitivity data. The local processor must be
conservative.

- Do not promote third-party speech as a fact about Markus unless context is
  explicit.
- Do not store gossip, credentials, medical/legal/financial details, or raw
  sensitive snippets as canon by default.
- Prefer source-linked candidates over untraceable summaries.
- Keep raw conversations separate from canonical TomMemory.
- Favor "candidate pending review" over silent permanent memory when confidence
  is low.

## Implementation Plan

1. Add local candidate tables or records in the Rewind database.
2. Run local conversation processing when `completeLocalSession` finishes a
   recording.
3. Store candidates with source conversation ID, segment IDs, confidence, and
   type.
4. Add heartbeat tools/queries for recent candidates.
5. Teach heartbeat to promote candidates into TomMemory Markdown when memory
   writes are enabled.
6. Add morning brief mode and logging.
7. Add UI affordances for reviewing promoted/rejected candidates.

## Non-Goals

- Do not clone upstream cloud notification infrastructure locally.
- Do not make the heartbeat a continuous audio processor.
- Do not require vendor STT/TTS/LLM providers for local capture.
- Do not make upstream sync harder by scattering local behavior outside
  `LocalMode` and local adapters.
