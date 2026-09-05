# Screen and Search verification — 2026-09-05

The reported dictionary failure had two reproducible causes. Submission could
finish capture before SwiftUI processed `/search`, leaving the command in the
question and starting generation with Search off. Separately, using SmolVLM 500M
for query planning and answering often produced only a transcription.

## Fixes

- Resolve leading Screen and Search commands together before capture or sending.
  Both orders, mixed case, duplicate commands and immediate Return are covered.
- Let confident short OCR supply dictionary words, memory values and error codes.
  Low-confidence or blank OCR still needs vision. Explicit appearance questions
  still use vision, while confident OCR preserves the lookup spelling.
- After local vision reads the image, use the selected local text-only model for
  query refinement and the answer. No model selection or installation is changed.
- Keep the original question, OCR, relevant observations and retrieved query in
  the final context. Intermediate output never becomes the visible answer.
- Schedule scrolling from measured layout size instead of message-publication callbacks.
  Context fitting retains room for sources without truncating the user's question.

## Real model and search checks

The installed SmolVLM 500M Q8_0 and selected Qwen2.5 3B Q8_0 were exercised through
the production inference engines. Screenshots were generated in memory, read by
the actual macOS Vision OCR service, and routed through `submitScreen`. Tests used
isolated chat storage. Model files were read from the existing library.

Before the fix, forcing the 500M vision model through all stages produced query
`Yes.` and answer `serenipity` for the dictionary prompt. RAM and HTTP prompts
returned little more than `59.7 MB` and `HTTP 429`. Separate runs also showed
vision confusing `serendipity` with `serenity` and HTTP 429 with HTTP 500 despite
correct OCR. This was a model transcription/planning problem, not an OCR failure.

The corrected pipeline completed all seven cases below with exactly one real
Brave request each, the expected lookup subject and visible Brave source links.
The existing app Keychain credential was used by the stable development-signed
test host; credentials were never printed. Fixed public evidence was also tested
to separate application behavior from changing search results.

| Screen | Prompt | Observed search query |
| --- | --- | --- |
| serendipity | Can you look up what this word means from the dictionary? | serendipity dictionary definition |
| Memory: 59.7 MB | How much RAM am I using, and can you search whether that is a lot? | 59.7 MB RAM usage is lot? |
| serendipity | What color is the word, and can you look up its dictionary definition? | color serendipity dictionary definition |
| ubiquitous | Find a dictionary definition of the word shown here and explain it simply. | ubiquitous dictionary definition simple explanation |
| Memory: 57 MB | Is this a lot of RAM? Please look it up. | 57 MB RAM usage high? |
| HTTP 404 | What does this mean? Search for an explanation. | HTTP 404 error meaning |
| HTTP 429 | Look up what this error means and how to fix it. | HTTP 429 error meaning and fix |

These are pipeline results, not a claim that all seven answers were correct.
Dictionary answers gave definitions, and error answers explained the codes.
The live RAM answers sometimes confused MB with percentages or assumed a total
RAM capacity from unrelated web excerpts. The color question searched correctly
but did not identify the text's color. OCR read the words, numbers and units
correctly. Those remaining answer-quality issues are left for model evaluation
and the owner's model upgrade, as requested. A better model is not guaranteed to
resolve every issue; the opt-in report makes the same cases repeatable.

## Native UI and regression coverage

Final local verification passed: shared-scheme build and static analyzer, plus
258 discovered tests with zero failures (257 passed; the opt-in model matrix was
skipped after its separate real runs). All 11 native panel tests also passed five
iterations each, for 55 successful checks. Build products and reports remain
outside the repository. GitHub CI status is recorded on the pull request.

Hosted native panel tests submit through the actual composer, including Return
before the draft-change callback, and verify one search, clean saved questions,
source links, draft clearing and final scroll position after an 80-fragment burst.
The original `onChange(of: Array<ChatMessage>)` warning did not appear in the final
test logs. Unrelated AppKit/Core Animation diagnostics can still appear in hosted
rendering tests; this is not a claim that all framework logging is silent.

In the signed app launched from Xcode, `/search Look up the dictionary definition
of serendipity.` produced a definition, five live source links and an empty focused
composer. The older build's actual capture flow also exposed the literal `/search`
command and uncleared draft. Automated dragging of macOS's region selector was
unreliable, so a complete physical capture-to-answer run on the corrected build
is **not verified**. Native injected capture tests and real synthetic-image
OCR/model/Brave tests cover those boundaries separately. No unsigned verification
app was launched interactively for capture.

Reproduction instructions and opt-in configuration are in
[Screen setup](Screen-Skill.md#real-screensearch-model-matrix). Remove the optional
configuration after use. Normal CI uses deterministic fixtures and does not
download models or call Brave.
