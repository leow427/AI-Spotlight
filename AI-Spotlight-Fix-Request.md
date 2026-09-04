# AI Spotlight — Fix request for an implementation agent

## Objective and scope

Implement and verify the **8 retained High/Medium issues in 5 groups** below. ONLY WORK ON YOUR SPECIFIED GROUP.

Repository: `leow427/AI-Spotlight`  
Local folder: `/Users/leo/Documents/AI-Spotlight-Real`  


Check the current revision and working-tree changes before editing, then read applicable repository guidance. Work from the current implementation and preserve unrelated work. File anchors below are from the compared revision; relocate them if the source has moved.

**Former issue 2 is removed from this request. Do not reintroduce Auto privacy-phrase routing or add privacy-policy work. Low-severity findings, broad cleanup, and new features are outside scope.** Keep explicit Local generation offline after model installation. Do not add web search or another inference backend as part of these fixes.

Implement local changes and meaningful regression tests. Publishing, pushing, merging, or deploying is not requested by this handoff. When finished, report the changes and validation results using the completion format at the end.

## A. Conversation context and limits — High -COMPLETED

Covers former #1 (High: Local loses history) and #9 (Medium: Cloud history lacks a model-specific budget).

**Current defect:** Local sends only the latest prompt, and the C++ bridge formats one user message and resets its context. Cloud instead sends the entire unbounded transcript; Auto assumes a generic Cloud context limit. Local and Cloud therefore disagree about conversation semantics and can fail on long inputs.

**Required behavior:**

- Pass ordered user/assistant history into Local inference, including the current user message exactly once. Use the selected model's chat template for the retained conversation. Keep sessions isolated.
- Prepare a bounded context for Local and each Cloud route, reserving capacity for output and template/protocol overhead. Use supported model limits or a documented conservative policy; do not silently assume every manual model has a 128,000-token context.
- Preserve the latest user message and retain coherent recent turns when trimming. Explain when context is omitted. If the current prompt alone cannot fit, return an actionable error and preserve the draft.
- Keep transcript persistence separate from the prepared request: trimming a request must not silently delete saved conversation history.
- Coordinate model-capability metadata with Group E rather than maintaining inconsistent limit tables.

**Starting points:**

- `AI-Spotlight/LocalInference/LocalChatViewModel.swift`: submit at line 129; local engine request at 141; Cloud history capture at 172.
- `AI-Spotlight/LocalInference/LocalModelEngine.swift`: LocalModelRequest.
- `Packages/LlamaBridge/Sources/LlamaBridge/AISLlamaBridge.cpp`: format_prompt at 36 and context reset at 201.
- `AI-Spotlight/Chat/AutoRouter.swift`: default capabilities at 58/65 and token estimate at 273.
- `AI-Spotlight/Cloud/CloudProviderClients.swift`, `CodexSubscriptionClient.swift`: outgoing conversation serialization.

**Acceptance checks:**

1. A second Local request receives the prior user message and assistant response, in order, plus the new user message exactly once. Switching to another chat does not leak the first chat's context.
2. Exercise the native bridge's multi-message formatting path; merely testing a view-model mock is insufficient to establish that the bridge uses history.
3. Boundary tests cover context just under and over the budget, reserved output capacity, and a single oversized prompt. No request exceeds the chosen budget policy; oversized input remains editable.
4. OpenAI, Anthropic, and Codex request preparation all use bounded context without deleting stored messages.
5. The local path introduces no network dependency. If a real-model smoke test cannot be performed, state that limit explicitly rather than substituting a claim about answer quality.

## B. Request lifecycle and route feedback — Medium -COMPLETED

Covers former #3 (cancellation race), #4 (lost rejected drafts), and #8 (misleading active route).

**Current defects:** Old canceled/erroring tasks can overwrite the replacement request's state. Drafts clear before route acceptance. Active status reads mutable next-request settings and can label an ongoing Cloud response as Local.

**Required behavior:**

- Give each active request an identity and captured route/provider/model. Only that request may change its state, publish tokens, or clear its task handle.
- Make Stop safe when a token, error, or completion from the old request is already queued. Starting a replacement must not lose its handle, mark it idle early, or allow unintended overlapping requests.
- Preserve existing server-side cancellation behavior, including Codex interruption where applicable.
- Clear the composer only after a request is accepted. Unsupported routing or context rejection must leave the user's original input available to edit.
- Display the actual active route until the request ends. Either disable route/provider changes while busy or make them apply only to the next request with accurate active feedback.
- Consolidate duplicated local/cloud lifecycle handling only where needed to make these guarantees consistent; avoid a broad view-layer rewrite.

**Starting points:**

- `AI-Spotlight/LocalInference/LocalChatViewModel.swift`: local/cloud task bodies at 139/191, Stop at 217, cleanup at 313.
- `AI-Spotlight/App/AppShellView.swift`: mode controls at 197/399, route status at 271, draft submission at 586.
- `AI-Spotlight/Cloud/CodexSubscriptionClient.swift`: server-side interrupt/cleanup.

**Acceptance checks:**

1. Deterministically queue a token from request A, stop A, start B, then release A's cancellation/error path. B remains busy and cancellable; late A events cannot mutate B.
2. Cover both Local and Cloud, including late failure/completion and rapid Stop/New Chat/restart. Use controlled continuations or barriers rather than timing sleeps.
3. Submit an unsupported web-search request in Auto with Cloud configured, and a rejected oversized request. Neither loses the draft or starts unintended generation.
4. During an active Cloud stream, change next-request mode/provider if the UI permits it. The displayed active route remains correct and the running request is unaffected.
5. Verify stopping B still reaches its underlying producer/server after A's cleanup has run.

## C. Imported model identity — Medium

Covers former #5.

**Current defect:** Distinct IDs such as `model.v1` and `model-v1` map to the same file. Replacement operates on the sanitized destination while metadata deduplicates only by original ID, so one import silently overwrites another.

**Required behavior:**

- Make storage destinations unique for distinct model identities, or detect and resolve a conflict before any destructive replacement.
- Preserve existing library entries and the selected model through any filename/metadata migration.
- Define intentional reimport/replacement behavior for the same identity separately from a collision between different identities.
- Keep metadata and file updates consistent if copying, replacement, or metadata saving fails. Do not claim to recover bytes already overwritten before this fix.

**Starting point:** `AI-Spotlight/LocalInference/LocalModelInstallationStore.swift`: destination at 39, replacement at 47, library update at 59, sanitization at 130.

**Acceptance checks:**

1. Import `model.v1.gguf` and `model-v1.gguf` with different contents. Both remain independently selectable and return their original bytes.
2. Test IDs that collide under the old 80-character truncation and the chosen policy for reimporting the same identity.
3. Load an existing library and verify compatibility/migration, selected-model preservation, and no loss of unrelated model files.
4. Simulate a relevant write failure and verify that a previously valid model/library remains usable.

## D. Cloud streaming delivery — Medium

Covers former #6.

**Current defect:** URLSessionCloudTransport waits for 4,096 bytes or EOF before forwarding data. Complete small events are delayed, and provider tests currently bypass this layer.

**Required behavior:**

- Deliver available complete streaming events promptly, using event/line boundaries or a bounded flush strategy rather than a size-only threshold.
- Preserve split UTF-8 characters, fragmented events, ordering, cancellation, and partial output on failure.
- Keep the change in the production transport/parsing path; do not only adjust mock chunk sizes.

**Starting points:** `AI-Spotlight/Cloud/CloudNetworking.swift:30`, `ServerSentEvents.swift`, and the direct API clients in `CloudProviderClients.swift`.

**Acceptance checks:**

1. Exercise the actual production transport with a controlled URLSession source or equivalent boundary seam. Provide a complete event below 4 KB and hold the stream open: the consumer receives it before EOF.
2. Verify several small events arrive incrementally, including splits inside a multibyte Unicode character and SSE delimiters.
3. Verify cancellation reaches the source and partial output is retained if the stream fails.
4. Do not use live-provider latency as the sole regression check.

## E. Compatible Cloud model selection — Medium

Covers former #7.

**Current defect:** OpenAI model listing is treated as a list of compatible chat models, sorted alphabetically, and the first result becomes the default. Model-list success is also presented without distinguishing it from selected-model compatibility.

**Required behavior:**

- Filter or validate discovered models against the text-chat endpoint this app implements. Use current supported provider information; do not replace the defect with another arbitrary name-order heuristic.
- Choose a compatible default and preserve a valid explicit user preference.
- Keep manual model entry usable, with clear feedback for unsupported or unverified selections. Do not silently discard a valid saved/manual choice.
- Distinguish account/API connectivity from compatibility of the selected model. Do not add an automatic billable generation request merely to label connectivity.
- Reuse relevant capability/limit information from Group A.

**Starting points:** `AI-Spotlight/Cloud/CloudModelCatalog.swift:123–160`; `CloudSettingsModel.swift:249–274`; provider request construction.

**Acceptance checks:**

1. A mixed list containing image, embedding, and supported text models never selects an incompatible model automatically.
2. Saved supported selections survive refresh; no-compatible-model results have a useful state rather than an invalid default.
3. Cover manual compatible, unsupported, and unknown IDs with the implemented feedback policy.
4. A successful account/model-list check does not imply that an unsupported selected model is ready for chat.

## Validation and completion report

Read Agents.md in the folder for specifics.

Return a concise completion report containing:

| Group | Status | Changed behavior | Tests/evidence | Remaining limitation |
|---|---|---|---|---|
| A | Fixed / Partial / Unresolved | | | |
| B | Fixed / Partial / Unresolved | | | |
| C | Fixed / Partial / Unresolved | | | |
| D | Fixed / Partial / Unresolved | | | |
| E | Fixed / Partial / Unresolved | | | |

Include the base revision, changed files, build/test/analyzer outcomes, and any migration or manual verification needed. Do not call a group fixed solely because code was edited; explain the observable regression that is now prevented. State any unresolved work without silently expanding the scope to the removed issue, Low findings, or unrelated refactoring.
