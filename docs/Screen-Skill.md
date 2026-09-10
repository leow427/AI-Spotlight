# Screen

The composer shows only **File Mode** as an attachment tool. Use **/screen** to
capture the full desktop (all connected displays in their desktop arrangement),
or **/snapshot** to select a region. Either command with a question captures and
sends; the command alone attaches and waits. Retake repeats the attachment's
capture type. Leading `/think`, `/screen`, `/snapshot`, and `/search` commands can
be combined. Commands inside the actual question remain literal text.

Use **/think your question** to request more reasoning for one answer. The local
server enables thinking and reserves 2,048 output tokens, with 1,024 available for
reasoning; ordinary replies keep their existing 512-token budget. File Mode also
carries the request's thinking setting through its tool loop. Cloud adapters set
provider-specific thinking controls; ChatGPT increases effort to at least Extra
High without lowering a stronger existing setting. Reply history excludes the
transient thinking setting and internal guidance. See
[thinking and capture verification](Thinking-and-Capture.md).

Capture preflights Screen Recording permission before hiding the panel. Permission
denial, cancellation and failed retakes preserve the draft and previous attachment.
The transparent, click-through panel stays ordered while macOS owns region
selection. Capture hides other app windows, suppresses shortcuts during selection,
restores the original panel frame and decodes/deletes its temporary PNG immediately.
Do interactive capture testing only with the stable Apple Development-signed Xcode
app; unsigned verification products can invalidate macOS Screen Recording consent.

## One selected model

Install a complete recommended package from **Settings → Local Models**, then use
the ordinary model picker. That model handles text, screenshots and search answers.
There is no independent local image-model preference or setup section. See
[model selection](Local-Model-Selection.md) for hardware gates and legacy migration.

Apple Vision OCR remains a local internal optimization. Confident text-heavy
captures and short word/value/error lookups can send the original question plus
OCR text to the selected model without pixels. Colors, shapes, spatial relationships,
layout, diagrams and other visual questions send the image to that same model;
relevant OCR accompanies it as untrusted data. The model is instructed to treat
screenshot content as quoted data rather than user instructions.

| Mode | Model selection | Image permission |
|---|---|---|
| Local | Ordinary selected local model | Pixels never leave this Mac |
| Auto | Normal Auto policy, including task complexity/context | Selected local model is the privacy/offline fallback; cloud pixels require consent |
| Cloud | Ordinary selected cloud model | Image-capable selected model and explicit consent required |

Legacy text-only models retain chat/OCR functionality. When pixels are needed,
choose a recommended text-and-image package. Another installed image model is
never silently selected to read the screenshot. Existing cloud-upload permission
and its explanation remain in **Screen** settings, off by default. Revocation is
checked before every image-bearing request and after retrieval. Cloud OCR can send
extracted text under the existing routing policy; permission specifically controls
image uploads. Local mode keeps both OCR and pixels local to model inference.

## Search controls retrieval

Without Search, the selected model answers directly. With Search and an attachment,
one hidden model call resolves the question against the image/OCR and produces a
focused query. Brave retrieves evidence; the same selected model receives the
original question, screenshot context and fitted evidence, then streams its answer.
There is no separate observation model or text-model handoff. Text-only chat with
Search keeps the existing direct-question retrieval path.

Planning output never appears in the transcript or visible answer. Invalid,
empty or oversized queries, retrieval failure, missing keys and context failures
retain the draft and attachment before acceptance. Stop cancels the active stage
and prevents late events from mutating a replacement request. Source links appear
beneath answers and persist with chat history. No-search requests never call Brave.
Derived queries can contain relevant screen details; full OCR, pixels and history
are not attached to Brave. Model instructions request relevant, non-sensitive query
content, but do not guarantee perfect interpretation or redaction.

The 1,568-pixel image limit, context reservations, complete-turn history fitting,
first-token acceptance, in-memory sent-image previews and persistence exclusions
remain. Screenshot pixels/OCR are not saved with history; only the original question,
answer and source links are persisted. Native layout/streaming scroll behavior and
**⌘⇧H / Hide Inactive Tools** remain unchanged.

## Automated verification

Run the shared build, test and analyzer commands in [AGENTS.md](../AGENTS.md).
Deterministic tests inject capture/OCR, search, provider and runtime boundaries.
Controlled loopback subprocess tests verify model reuse, switching, cancellation
and idle cleanup without downloading a model or selecting a desktop region.

For an optional real model check, create `/tmp/AI-Spotlight-Vision-Smoke.json`:

```json
{
  "model": "file:///absolute/path/model.gguf",
  "projector": "file:///absolute/path/mmproj.gguf",
  "server": "file:///absolute/path/llama-server",
  "prompts": ["Describe the shapes and colors in this image in one sentence."],
  "expectedAnswerTerms": ["red", "circle", "blue", "square"]
}
```

Run `scripts/verify-xcode.sh test '-only-testing:EnigmaTests/ScreenNativeSmokeTests'`.
The test copies into an isolated temporary library, uses synthetic shapes, checks
ordinary text arithmetic, and verifies the model stays resident across requests.

The seven-case OCR/search matrix reads a test library and its normal selection.
Create `/tmp/AI-Spotlight-Screen-Search-Smoke.json`:

```json
{
  "modelsDirectory": "file:///absolute/path/to/test-library/",
  "modelID": "the-normally-selected-multimodal-model-id",
  "liveSearch": false
}
```

Run `scripts/verify-xcode.sh test '-only-testing:EnigmaTests/ScreenSearchNativeSmokeTests'`.
Fixed public evidence is the default. `liveSearch: true` explicitly authorizes using
the configured Brave credential and normal API usage; routine verification does
not need it. Both tests are skipped in CI unless the explicit fixtures exist.
Remove the opt-in JSON files after running. Results contain synthetic inputs and
public evidence only. See [verification results](Screen-Search-Verification.md).

Interactive region selection, permission dialogs, secondary-display capture and
Zoom capture-exclusion testing remain with the owner. Automated tests do not claim
to verify those desktop interactions. [Screen-sharing privacy](Screen-Sharing-Privacy.md)
documents the limitations of the existing macOS window-sharing flag.
