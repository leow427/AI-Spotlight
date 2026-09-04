# Group D completion report

Implemented in `/Users/leo/Documents/AI-Spotlight-Real` on 2026-09-04.
Base revision: `8db7b86062ba26d666ecc520eb17fbc73e78d016` (`main`).
Repository: [leow427/AI-Spotlight](https://github.com/leow427/AI-Spotlight).
Scope: Group D only. The user's request explicitly authorizes commit and push.
This report records local validation; the completion message reports publication
and the pushed revision's GitHub CI result.

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Existing fix preserved | No context/history changes. | Existing tests pass in the full suite. | See the Group A report for its scope and limits. |
| B | Existing fix preserved | No request-identity or route-feedback changes. | Existing lifecycle tests and new end-to-end source cancellation tests pass. | See the Group B report. |
| C | Existing fix preserved | No model-storage changes. | Existing storage tests pass. | See the Group C report. |
| D | Fixed locally | Completed SSE lines are forwarded immediately instead of waiting for 4 KB or EOF. Fragmented UTF-8, ordering, cancellation, and partial replies are preserved. | Original transport fails the new before-EOF regression. All 9 new tests and all 120 tests pass; build and analyzer pass. | Live-provider latency and manual UI inspection were not performed. CI is checked after push. |
| E | Unresolved — not assigned | No model-discovery, compatibility, or default-selection changes. | Existing tests pass. | Compatible Cloud model selection remains outside this change. |

## Observable regression prevented

`URLSessionCloudTransport` now forwards its raw byte buffer at each LF, including
the LF in CRLF lines. A complete small SSE event reaches the provider parser while
the connection remains open, without needing another event or padding to 4 KB.
The existing 4,096-byte cap still bounds transport chunks for long lines, and EOF
still forwards remaining bytes for bodies without a trailing newline.

The existing parser buffers fragmented lines and decodes UTF-8 only after a line
is available. It therefore safely rejoins a multibyte character split across the
transport cap. Parser and provider production code did not need changes. Existing
consumer cancellation still cancels the underlying URLSession operation.

## Validation

Xcode 26.6 (17F113), shared `AI-Spotlight` scheme, macOS destination,
`CODE_SIGNING_ALLOWED=NO`:

- Before edits: **111 tests, 0 failures**.
- Regression against the original transport: **failed as expected**. A complete
  event smaller than 4 KB was not delivered while the source stayed open; it was
  delivered only after the test released EOF.
- Final focused streaming suite: **9 tests, 0 failures**.
- Final complete suite: **120 tests, 0 failures**.
- `xcodebuild build`: **succeeded**.
- `xcodebuild analyze`: **succeeded**, no analyzer findings.
- `git diff --check`: **clean**.

The new tests use a controlled `URLProtocol` inside an ephemeral `URLSession`.
The production `session.bytes(for:)` implementation, transport buffering, parser,
OpenAI/Anthropic clients, and chat view model all run through their real paths.
No live-provider requests or network-dependent timing measurements are needed.
Expectations coordinate source startup, consumer receipt, and source shutdown;
timeouts only bound test failures. There are no arbitrary sleeps.

Coverage includes:

- An event below 4 KB received before EOF, status-before-data ordering, and exact
  reconstruction of the transport's bytes.
- Three incremental events for each direct API provider, withholding each next
  event until receipt of the preceding one. One-byte source writes fragment
  accented text, emoji, CJK characters, and CRLF delimiters.
- A long SSE line with an emoji split at the 4,096-byte transport boundary, plus
  a parser check that waits for fragmented Unicode and the complete blank line.
- A non-success HTTP response body with Unicode and no trailing newline.
- Network loss and premature EOF after partial output for both direct providers,
  including an unfinished next event when the connection fails.
- Cancellation while awaiting headers and while awaiting body bytes, verified
  through URLProtocol's `stopLoading` before invalidating the test session.
- Stop and network failure through both providers and the view model, verifying
  that partial replies remain visible and saved, and the active request is cleared.

No existing tests were changed, removed, skipped, or disabled. The existing
AppIntents metadata warning and macOS shortcut-service diagnostics appeared during
validation; the final changes introduce no compiler warnings. Logs and build
results are outside the repository under `/private/tmp/ai-spotlight-group-d-*`.

## Changed files and compatibility

- `AI-Spotlight/Cloud/CloudNetworking.swift`
- `AI-SpotlightTests/CloudStreamingTransportTests.swift` (new)
- `AI-Spotlight.xcodeproj/project.pbxproj` (test registration)
- `docs/Group-D-Completion.md` (this report)

No migration, dependency, model download, or settings change is required. This
change affects direct API transport delivery; the Codex subscription transport
and explicit Local inference path are unchanged. The tests establish delivery
once complete event bytes are available from URLSession, not a guarantee about
how quickly a remote provider, proxy, or network sends those bytes.
