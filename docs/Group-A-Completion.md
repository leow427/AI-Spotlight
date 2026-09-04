# Group A completion report

Implemented locally in `/Users/leo/Documents/AI-Spotlight-Real` on 2026-09-04.
Base revision: `b9c93c1c04055afaa7d87033ba0ffdcf79a5a8b1` (`main`).
Repository: [leow427/AI-Spotlight](https://github.com/leow427/AI-Spotlight).
This report records validation before publication.

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Fixed locally | Local replays ordered retained history using the selected model's template. All Cloud routes have bounded requests. Whole-turn trimming preserves the current prompt and saved transcript. Rejected drafts remain editable; omissions are disclosed. | All 82 tests pass; shared-scheme build and analysis pass; native C++ analysis clean; real GGUF smoke tests pass, including Swift preparation with network explicitly denied. | GitHub CI has not run for these unpublished changes. Cloud calls were tested through controlled transports, not live paid services. Unknown model limits and Codex output reserves follow the documented conservative policy. |
| B | Unresolved — not assigned | Only the acceptance callback needed for Group A draft preservation was changed. | Group A draft rejection covered. | The broader lifecycle race and active-route feedback work remains assigned to Group B. |
| C | Unresolved — not assigned | No model storage changes. | Existing tests pass. | Imported model identity work remains assigned to Group C. |
| D | Unresolved — not assigned | No transport delivery changes. | Existing tests pass. | Incremental production transport delivery work remains assigned to Group D. |
| E | Unresolved — not assigned | Shared context metadata is exposed through `CloudModel.contextBudget` for reuse. | Auto and model metadata consistency covered. | Compatible model discovery/defaults/feedback remain assigned to Group E. |

## Observable regressions prevented

- A second Local request includes the earlier user message and assistant response,
  followed by the current message once. New chats and returning to an earlier chat
  use only that chat's messages. The native template formatter itself is tested.
- Requests reserve output and protocol space. Tests cover just below, exactly at,
  and above the input allowance, including JSON escaping and Unicode. Native Local
  counting includes the actual model template and special tokens.
- Trimming removes whole old turns from a request copy. Tests read the saved chat
  archive afterward for Local, OpenAI, Anthropic, and Codex and confirm old messages
  remain intact. Empty failed-response placeholders do not become orphaned context.
- Oversized current prompts are rejected before generation and transcript insertion;
  the composer acceptance callback is not called, preserving the original draft.
- OpenAI/Anthropic serialize explicit output caps. Codex prepares its bounded text
  before starting server requests and retains its existing interruption/cleanup.

## Validation

Xcode 26.6 (17F113), shared `AI-Spotlight` scheme, macOS destination,
`CODE_SIGNING_ALLOWED=NO`:

- `xcodebuild test`: **82 tests, 0 failures**. All existing tests remain enabled.
- `xcodebuild build`: **succeeded**.
- `xcodebuild analyze`: **succeeded**.
- Supplemental `clang++ --analyze` on the changed native bridge: **succeeded, no diagnostics**.
- `git diff --check`: **clean**.

The existing Cloud fixture ended on an assistant message; it now includes the
current user message to represent a valid next-turn request. New archive tests
compare against the saved baseline because the existing ISO-8601 format discards
subsecond timestamp precision. No production persistence format was changed.

Real-model smoke tests used the already installed
`smollm2-135m-instruct-q4_k_m.gguf`, without downloading or changing the model:

- Native follow-up: 72 input tokens with history versus 15 for the latest prompt.
- Reused-engine isolated request matched a fresh engine's deterministic output.
- Native exact output-reserve boundary accepted; one token over rejected.
- Swift-to-native preparation retained the three most recent messages from five,
  counted 34 input tokens, streamed a response, and rejected an oversized prompt.
  This test ran under an explicit `deny network*` sandbox.

These smoke checks establish history delivery, isolation, budgeting, and offline
operation; they do not establish model answer quality. Logs and supplemental
harnesses are in `/private/tmp/ai-spotlight-group-a-*`, outside the repository.
The harmless Xcode AppIntents metadata-extraction warning appeared during tests;
there were no compiler or static analyzer findings in the final validation.

## Changed files

Production and project registration:

- `AI-Spotlight/Chat/ChatContext.swift` (new shared budget/preparation policy)
- `AI-Spotlight/Chat/AutoRouter.swift`
- `AI-Spotlight/LocalInference/LocalModelEngine.swift`
- `AI-Spotlight/LocalInference/LlamaCPPModelEngine.swift`
- `AI-Spotlight/LocalInference/LocalChatViewModel.swift`
- `AI-Spotlight/Cloud/CloudProviderClients.swift`
- `AI-Spotlight/Cloud/CodexSubscriptionClient.swift`
- `AI-Spotlight/App/AppShellView.swift`
- `Packages/LlamaBridge/Sources/LlamaBridge/AISLlamaBridge.cpp`
- `Packages/LlamaBridge/Sources/LlamaBridge/include/AISLlamaBridge.h`
- `AI-Spotlight.xcodeproj/project.pbxproj`

Regression tests:

- `AI-SpotlightTests/ChatContextTests.swift` (new)
- `AI-SpotlightTests/LocalInferenceTests.swift`
- `AI-SpotlightTests/CloudModeTests.swift`
- `AI-SpotlightTests/CodexSubscriptionTests.swift`
- `AI-SpotlightTests/AutoRouterTests.swift`

Documentation:

- `docs/Context-Budgets.md` (new policy, provider references, and Group E integration guidance)
- `docs/Group-A-Completion.md` (this report)

## Follow-up and compatibility

No migration is required. Saved chats, installed model metadata, and user model
preferences are preserved. Models without a supported chat template now produce
an actionable error instead of silently dropping history. The current prompt is
kept in the composer if preparation fails.

Before integration, run GitHub CI once the changes are explicitly approved for
publication. Live-provider verification and visual inspection of the context
notice remain manual. The shared policy documents conservative unknown-model
limits, the input cap, and Codex's lack of an enforced output-token field. Group E
should extend this one policy when verifying more model capabilities.
