# Group B completion report

Implemented in `/Users/leo/Documents/AI-Spotlight-Real` on 2026-09-04.
Base revision: `f40b272ea17fb820645665712cd223f7dffb0839` (`main`).
Repository: [leow427/AI-Spotlight](https://github.com/leow427/AI-Spotlight).
Scope: Group B only. The user's request explicitly authorizes commit and push.
This report records local validation; the completion message reports publication
and the pushed revision's GitHub CI result.

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Existing implementation; not reassessed | Preserved the baseline context preparation and acceptance behavior. | All existing context and history tests pass. | See the existing Group A report for its scope and limits. |
| B | Fixed locally | Request identity protects state, tokens, acceptance, and task cleanup. Active route/provider/model feedback survives next-request settings changes. Rejected drafts remain editable. Stop remains connected to the replacement producer. | 14 new deterministic lifecycle tests; all 96 tests pass; build and analyzer pass. Production OpenAI, Anthropic, and Codex clients are exercised through controlled boundaries. | Live-provider behavior and manual visual inspection were not performed. CI is checked after push. |
| C | Unresolved — not assigned | No model-storage changes. | Existing installation tests pass. | Imported model identity remains outside this change. |
| D | Unresolved — not assigned | No production transport buffering changes. | Existing provider tests and replacement cancellation tests pass. | Small-event transport delivery remains outside this change. |
| E | Unresolved — not assigned | No catalog, compatibility policy, or default-selection changes. | Existing Cloud settings tests pass. | Compatible model selection remains outside this change. |

## Observable regressions prevented

- Local and Cloud each capture a request identity and route. Only the current
  identity can publish text, accept prepared input, report failure/completion, or
  clear the generation handle. Local resolves the engine's selected model before
  preparation, including when its initial library refresh has not finished.
- Stop revokes ownership before cancelling the consumer. A queued token, error,
  completion, or delayed Local preparation from A cannot overwrite replacement B,
  append into a new chat, or remove B's Stop handle. Busy state remains true even
  if saving a partial response reports an error, preventing a third generation.
- Cloud installs its task handle before invoking the acceptance callback. Both
  routes check cancellation before starting their producers, including when that
  callback immediately stops the request and starts another chat.
- Auto submission now lives in the same view model used by the composer. Rejected
  web-search and oversized input never invoke acceptance or start a producer;
  original whitespace is preserved. Earlier errors do not mask the new routing
  limitation. Group A's Local/Cloud context-rejection protection is retained.
- The active status uses the captured route, provider, and model before consulting
  the next mode or Cloud settings. Stop is visible during preparation and streaming.
  Mode controls explain that changes apply to the next request. Local model
  selection blocks submission until the engine and displayed selection agree.
- Existing provider cancellation is preserved. The Codex regression delays A's
  `turn/start` reply until B starts, then verifies A's interruption/unsubscription
  and B's subsequent interruption use their own thread and turn IDs.

## Validation

Xcode 26.6 (17F113), shared `AI-Spotlight` scheme, macOS destination,
`CODE_SIGNING_ALLOWED=NO`:

- Baseline: **82 tests, 0 failures**.
- Final `xcodebuild test`: **96 tests, 0 failures**, including all 14 new tests.
- Final `xcodebuild build`: **succeeded**.
- Final `xcodebuild analyze`: **succeeded**.
- Whitespace validation for the Group B changes: **clean**.

The new tests use continuations, stream boundaries, observable state, and awaited
consumer shutdown rather than timing sleeps. The Local and Cloud matrices each
exercise queued tokens, failures, and completion. Additional tests cover New Chat,
delayed preparation, both acceptance callbacks, pre-start cancellation, rejected
Auto drafts, normal completion, current failure with partial output, actual Cloud
settings changes, model-selection ordering, and persistence failure.

OpenAI and Anthropic tests use the production clients with controlled network
streams. The Codex test uses the production subscription client with a controlled
RPC transport. No billable service requests, new model downloads, or new network
dependencies were introduced. A real-model answer-quality smoke test was not
repeated for this lifecycle change.

The test run emitted the existing AppIntents metadata warning and macOS shortcut
service connection diagnostics. There were no compiler or static-analyzer findings.
Local logs and build results are outside the repository under
`/private/tmp/ai-spotlight-group-b-*`.

## Changed files and compatibility

- `AI-Spotlight/LocalInference/LocalChatViewModel.swift`
- `AI-Spotlight/App/AppShellView.swift`
- `AI-SpotlightTests/RequestLifecycleTests.swift` (new)
- `AI-Spotlight.xcodeproj/project.pbxproj` (test registration)
- `docs/Group-B-Completion.md` (this report)

No migration is required. Saved chats, local model files, Cloud preferences, and
provider protocols retain their existing formats. The pre-existing edit to
`docs/Group-A-Completion.md` and untracked `AI-Spotlight-Fix-Request.md` are preserved
and excluded from this commit.

Optional manual visual check: start a Cloud response, change the next mode to
Local and choose another provider in Settings, verify the status still identifies
the active Cloud provider/model, then Stop and submit another response. The route
data and cancellation behavior for this sequence are covered by automated tests;
the panel's visual appearance has not been manually inspected in this task.
