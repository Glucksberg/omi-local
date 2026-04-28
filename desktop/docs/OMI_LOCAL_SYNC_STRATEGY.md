# Omi Local Sync Strategy

Omi Local is a divergent local product fork of upstream Omi. It is not a
`main-with-all-prs` branch and should not be managed as a stack of PR branches.

## Product Branch

- Upstream: `BasedHardware/omi`, branch `main`
- Public fork: `Glucksberg/omi-local`
- Product branch: `omi-local`
- Local path: `/Users/markus/omi-local`

The product branch contains local-first behavior:

- `LocalMode`
- local API routing
- local STT/TTS services
- local network policy
- TomMemory bootstrap
- Tom heartbeat
- local desktop onboarding and settings changes

## Public Clean History Constraint

The public fork branch was history-cleaned. Upstream history still contains
refs and tags that should not be republished through this fork.

Because of that, upstream sync must avoid reconnecting `omi-local` to upstream
history with a normal merge commit.

Use upstream as a source of reviewed changes, not as a public parent history.

## Current Sync Marker

Last integrated upstream SHA:

```text
5fe7eab4a76363ccb81a654ea7beb5707b256bb3
```

The fork-manager config stores this value as `lastIntegratedUpstreamSha`.
Update it only after a sync is verified and published.

## Sync Model

Preferred model:

```text
upstream/main changes since lastIntegratedUpstreamSha
  -> reviewed patch import
  -> integration branch from omi-local
  -> tests and smoke checks
  -> user-approved publication
  -> update lastIntegratedUpstreamSha
```

Avoid:

- `git merge upstream/main` into `omi-local`
- public merge commits with upstream parents
- `git push --tags`
- copying upstream branches into `origin`
- force-pushing without explicit approval

## Integration Branches

Use integration branches with this prefix:

```text
sync/omi-local-upstream-YYYYMMDD
```

The integration branch is disposable review space. It can contain conflict
resolution and test fixes. The product branch should only be updated after the
integration result is tested.

## Clean Patch Import

Recommended process:

1. Fetch upstream without tags.
2. Record the current upstream SHA.
3. List changed files:

   ```bash
   git diff --name-only <lastIntegratedUpstreamSha>..upstream/main
   ```

4. Classify overlap with protected local paths.
5. Create an integration branch from `omi-local`.
6. Apply upstream changes as a patch:

   ```bash
   git diff --binary <lastIntegratedUpstreamSha>..upstream/main -- <paths> | git apply --3way
   ```

7. Resolve conflicts preserving local-first boundaries.
8. Run verification.
9. Commit the cleaned result.
10. Publish only after explicit approval.

If a specific upstream commit is needed, use `git cherry-pick --no-commit` and
squash the result into an Omi Local sync commit after review. Do not preserve the
upstream commit as a public parent.

## Protected Areas

Conflicts in these areas are semantic, not mechanical:

- auth and onboarding
- API routing
- transcription and listen pipeline
- local STT/TTS
- chat and agent bridge
- conversations and memories
- proactive assistants
- heartbeat and TomMemory
- settings that enable vendor/cloud providers

Resolve these by preserving local behavior behind explicit local-mode adapters.

## Verification

Baseline checks:

```bash
python3 -m py_compile local-api/server.py local-speech/server.py
xcrun swift build -c debug --package-path Desktop
xcrun swift test -c debug --package-path Desktop --filter APIClientRoutingTests
```

Run narrower tests when touching specific areas:

- local mode guardrails
- chat session routing
- speech/TTS routing
- transcription storage
- heartbeat logging

## Fork Hygiene

The public fork should stay narrow:

- one public product branch: `omi-local`
- no copied upstream tags
- no copied upstream branch fanout
- upstream remote is fetch-only
- origin is the public product fork

If tags appear locally after upstream fetch, delete them locally before any
publication step unless a release workflow explicitly requires a reviewed tag.
