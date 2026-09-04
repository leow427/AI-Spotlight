# Group C completion report

Implemented in `/Users/leo/Documents/AI-Spotlight-Real` on 2026-09-04.
Base revision: `6d23542d59ef17d500b206f0e4cdae60d5d5bbb4` (`main`).
Repository: [leow427/AI-Spotlight](https://github.com/leow427/AI-Spotlight).
Scope: Group C only. The user's request explicitly authorizes commit and push.
This report records local validation; the completion message reports publication
and the pushed revision's GitHub CI result.

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Existing implementation; not reassessed | No context/history changes. | Existing tests pass in final suite. | See Group A report. |
| B | Existing implementation; not reassessed | No request-lifecycle changes. | Existing tests pass in final suite. | One pre-edit cancellation test timed out, then passed on recheck; details below. |
| C | Fixed locally | Distinct identities retain distinct bytes. Same-ID replacement commits new metadata before removing old files. Legacy entries/selection and shared files are preserved. | 15 new storage tests; 27 focused tests pass; all 111 tests, build, and analyzer pass. | Previously overwritten bytes cannot be recovered. Cleanup errors can leave unused files. CI is checked after push. |
| D | Unresolved — not assigned | No transport buffering changes. | Existing tests pass. | Incremental transport delivery remains outside this change. |
| E | Unresolved — not assigned | No model-discovery or compatibility changes. | Existing tests pass. | Compatible Cloud selection remains outside this change. |

## Identity, replacement, and compatibility

- Each import receives a fresh `model-<UUID>.gguf` filename. Model IDs remain in
  metadata; punctuation, case, Unicode, and long-ID truncation cannot alias the
  destination. Finalizing the copy refuses to overwrite an occupied destination.
- Reimporting the same exact model ID intentionally replaces that library entry
  and updates its display name. Successful imports still select the imported
  model, preserving the existing interaction. Reimporting an installed file itself
  is supported. Callers use the returned model/newly loaded library for its path.
- Existing multi-model and legacy single-record metadata are read without moving
  files or rewriting metadata. The selected ID is preserved. A legacy single
  record becomes a library on the next successful metadata mutation, retaining
  its filename and identity. No manual migration is required.
- Copying and finalizing the new file happen before the atomic metadata write.
  Until that write succeeds, old metadata, selections, and model bytes remain
  intact. Failure removes only the attempted import's files. After success, old
  files belonging to the replaced ID are removed only when no retained record
  references them, accounting for case aliases and symlinks.
- Corrupt or unreadable metadata aborts mutations instead of being overwritten
  with an empty library. In-process imports, downloads, selections, and reads
  serialize their library access. No dependency or network operation was added.

## Validation

Xcode 26.6 (17F113), shared `AI-Spotlight` scheme, macOS destination,
`CODE_SIGNING_ALLOWED=NO`:

- Focused storage/local-inference suite: **27 tests, 0 failures**.
- Final `xcodebuild test`: **111 tests, 0 failures**.
- Final `xcodebuild build`: **succeeded**.
- Final `xcodebuild analyze`: **succeeded**, no analyzer findings.
- `git diff --check`: **clean**.

The new tests exercise production storage with temporary files and reopened store
instances. They cover `model.v1.gguf` versus `model-v1.gguf`, IDs sharing the old
80-character prefix, case/Unicode IDs, same-ID replacement, reimport from the
installed path, legacy metadata formats, selection preservation, untracked files,
already-shared legacy files, and concurrent store instances.

Injected file operations deterministically fail after a partial copy, during
finalization, and during metadata saving. Both new imports and replacements are
covered, including first import, selection saving, occupied destinations, and
cleanup failures. Tests compare the complete existing library directory and its
bytes before and after failed operations. A commit-boundary test verifies the old
bytes/metadata still exist and the new bytes are complete immediately before the
real atomic metadata write.

The original installation test expected a sanitized filename and in-place byte
replacement. Those assertions now use the returned replacement path and still
verify copied bytes, replacement bytes, updated display name, one entry per ID,
and selection. No tests were deleted, skipped, or disabled.

Before any edits, the 96-test baseline had one failure:
`RequestLifecycleTests.testDirectAPIReplacementStillCancelsItsOwnNetworkSource`
timed out waiting for `Producer cancelled` at line 229. It passed when rerun on
unchanged source and passed in the final complete suite. This intermittent
Group B issue was recorded without expanding the Group C changes.

The existing AppIntents metadata warning and macOS shortcut-service diagnostics
appeared during validation; no new compiler warnings were introduced. Logs and
build results are outside the repository under `/private/tmp/ai-spotlight-group-c-*`.

## Changed files

- `AI-Spotlight/LocalInference/LocalModelInstallationStore.swift`
- `AI-SpotlightTests/LocalModelInstallationStoreTests.swift` (new)
- `AI-SpotlightTests/LocalInferenceTests.swift`
- `AI-Spotlight.xcodeproj/project.pbxproj` (test registration)
- `docs/Group-C-Completion.md` (this report)

## Remaining limits

Old builds may already have overwritten one identity's bytes. This change preserves
the surviving files; it cannot reconstruct the lost originals. Reimport original
GGUF files for any identities affected before the fix.

If cleanup itself fails, or execution is interrupted around the commit, an unused
model file may remain on disk. The saved library continues to reference the valid
old or newly committed model. Untracked files are never swept automatically.
Concurrent writers are serialized within one application process; simultaneous
independent app processes and sudden hardware/power failure were not tested.

Tests use distinct small byte fixtures because Group C concerns file identity and
persistence. No real-model inference or manual UI verification was performed;
there are no UI or inference-path changes in this group.
