# Group E completion report

Implemented in `/Users/leo/Documents/AI-Spotlight-Real` on 2026-09-04.
Base revision: `3a7c11d081add26ea97457f2b9dee9317303f905` (`main`).
Repository: [leow427/AI-Spotlight](https://github.com/leow427/AI-Spotlight).
Scope: Group E only. The user's request explicitly authorizes commit and push.
This report records local validation; the completion message reports the pushed
revision and its GitHub CI result.

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Existing fix preserved | Shared budgets now read reviewed Cloud capability metadata. History, trimming, reserves, and Local inference are preserved. | Existing context, native bridge, and Auto tests pass; new tests cover expanded model limits at request boundaries. | See Group A report and Context-Budgets.md. |
| B | Existing fix preserved | Unsupported-model rejection uses the existing pre-acceptance path to retain drafts. Request lifecycle is unchanged. | Existing lifecycle tests pass; new test verifies rejection retains draft and stored transcript. | See Group B report. |
| C | Existing fix preserved | No model-storage changes. | Existing installation tests pass. | See Group C report. |
| D | Existing fix preserved | No streaming-transport changes. | Existing production transport tests pass. | See Group D report. |
| E | Fixed locally | OpenAI discovery/defaults use reviewed streaming text-chat models. Saved/manual selections survive. Unsupported, unverified, and empty selections have explicit feedback. Account checks are separate from compatibility. | Original implementation selects DALL-E in the new regression; fixed implementation selects Luna. All 20 new tests and all 140 tests pass; build/analyzer pass; settings states rendered and inspected. | No paid provider requests. New or unreviewed IDs require manual entry and can still be rejected by the provider. CI is checked after push. |

## Observable regressions prevented

- A mixed account list containing DALL-E, audio, embedding, and text models cannot
  automatically choose a non-chat model. The default follows the documented
  lightweight model preference order, independent of provider order or alphabetic
  naming. Positive compatibility uses exact reviewed IDs and snapshots.
- Existing 24-hour caches are filtered on every read. Old unsafe entries,
  duplicates, and empty/wrong-provider entries cannot become automatic defaults.
  The raw cache format remains compatible, with no migration.
- A valid empty or incompatible-only model list succeeds as an account check and
  reports zero compatible chat choices. Settings explain refresh/manual entry.
  It no longer supplies an invalid default or mislabels this as malformed data.
- Saved and manual IDs are retained even if absent from a refreshed list.
  Compatible IDs can be entered without discovery; unknown/fine-tuned IDs remain
  usable with unverified feedback and conservative Group A limits. Known
  incompatible IDs remain editable, with sending disabled and an actionable
  request-boundary error before network access or draft acceptance.
- Successful connection feedback explicitly describes only a model-list check.
  It does not imply that an unsupported selection is ready for chat, that billing
  works, or that a generation request succeeded. Tests assert GET-only discovery
  with no generation calls.
- Reviewed capability and context/output information lives in
  `CloudModelCapabilities`; Group A's existing `ModelContextPolicy`, model metadata,
  Auto routing, and outgoing context preparation reuse it. Codex's default and
  existing exact-ID limits are retained. No inference backend or web-search
  feature was added; Local remains offline after installation.

## Validation

Xcode 26.6 (17F113), shared `AI-Spotlight` scheme, macOS destination,
`CODE_SIGNING_ALLOWED=NO`:

- Pre-edit baseline: **120 tests, 0 failures**.
- New mixed-list regression on original production code: **failed as expected**;
  `dall-e-3` became the default and incompatible models appeared as chat choices.
- Focused Cloud/settings/context/Codex suite: **63 tests, 0 failures**.
- Final `xcodebuild build`: **succeeded**.
- Final complete `xcodebuild test`: **140 tests, 0 failures**, including **20 new
  Group E tests**. No tests were removed, skipped, or disabled.
- Final `xcodebuild analyze`: **succeeded**, no analyzer findings.
- `git diff --check`: **clean**.

Controlled response gates cover preference/provider changes while discovery is
in flight without arbitrary sleeps. Tests exercise production cache decoding,
settings, context preparation, and Responses request construction. Manual
compatible/unsupported/unknown IDs, cache reloads, absent saved selections,
authentication/malformed-list failures, and just-under/at/over input budgets are
covered. Existing Anthropic and Codex tests pass.

The existing cache-lifetime test's fictional `gpt-test` discovery fixture was
changed to verified `gpt-4o-mini`; its 24-hour reuse/expiry assertions remain.

A temporary AppKit/SwiftUI harness rendered the real Settings view at 560×740
points using isolated mock credentials and model responses. Compatible,
unsupported, unverified, and empty-choice states were visually inspected;
messages and manual inputs were readable, with the existing scrollable form.
The temporary rendering harness is excluded from the committed test suite.
Screenshots precede a final wording-only adjustment to the model-count label.

The existing AppIntents metadata warning and macOS shortcut-service diagnostics
appeared during validation. No new compiler warnings or analyzer findings were
introduced. Logs, build results, the temporary rendering method, and screenshots
are outside the repository under `/private/tmp/ai-spotlight-group-e-*`.

## Changed files

- `AI-Spotlight/Cloud/CloudModelCapabilities.swift` (new shared reviewed metadata)
- `AI-Spotlight/Cloud/CloudModelCatalog.swift`
- `AI-Spotlight/Cloud/CloudSettingsModel.swift`
- `AI-Spotlight/Cloud/CloudDomain.swift`
- `AI-Spotlight/Chat/ChatContext.swift`
- `AI-Spotlight/App/AppShellView.swift`
- `AI-SpotlightTests/CloudModelSelectionTests.swift` (new)
- `AI-SpotlightTests/CloudModeTests.swift` (cache fixture only)
- `AI-Spotlight.xcodeproj/project.pbxproj` (source/test registration)
- `docs/Cloud-Model-Selection.md` (policy, exact IDs, sources, and maintenance)
- `docs/Context-Budgets.md` (shared metadata and reviewed model limits)
- `docs/Group-E-Completion.md` (this report)

## Remaining limits and manual follow-up

No migration is required. A previously saved incompatible ID is intentionally
retained, so the user must choose another model in Settings before sending.

The reviewed OpenAI catalog is a conservative subset of provider offerings.
Additional/new models remain manually usable as unverified until their exact
endpoint, request-option, streaming, and limit support is reviewed. Published
compatibility does not establish account entitlements, quota, billing, answer
quality, or future provider availability. No live paid generation or account
credential changes were performed. The rendered UI check used mock account data;
end-to-end live account verification remains manual.
