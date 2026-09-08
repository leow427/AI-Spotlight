# Unified local model verification — 2026-09-06

The implementation replaces the separate image-model setup and SmolVLM/text-model
handoff with one normally selected multimodal model. The existing branch is
`feat/screen-capture`, stacked in draft PR #3 on `feat/automatic-local-model-selection`.
The starting head was `5a3ef9c`, whose GitHub CI passed. Its historical two-model
results remain available in Git history; they are not current setup instructions.

## Catalog expansion checks

Catalog version 3 expands the choices to twelve packages across Alibaba/Qwen,
Google, Mistral AI and OpenBMB. Setup and settings show up to ten compatible choices
in descending hardware-aware order, each with one sentence of description. See
[the catalog and source review](Local-Model-Selection.md) for exact pinned packages,
licenses, memory estimates and the editorial ranking policy.

On the catalog implementation:

- Required shared-scheme build and static analyzer passed.
- Full automated suite: **273 discovered, 271 passed, two opt-in real-model tests
  skipped, zero failures**. All 12 native panel regressions passed.
- Focused catalog/runtime suite: 46 tests passed. After fixing the rendering tests
  to use a deterministic 24 GiB Mac profile, all 22 local-vision tests passed again.
- New regressions cover twelve complete packages/four makers, descriptions,
  deterministic top-ten ordering, resource gates, fewer-than-ten behavior,
  architecture-specific memory floors, measured demotion across families and
  legacy descriptor decoding without changing package identity.
- Native settings/onboarding renders were inspected. No interactive region
  selection was performed and no app formatter was introduced.

The owner requested to perform new-family response testing separately. Temporary
candidate downloads were stopped and their partial files removed; no candidate
was installed in the owner's library. New-family text/image output quality and
real resource use have not been measured here. The pre-existing two optional
native tests remain intact. The prior Qwen 4B results below describe the earlier
unified runtime verification, not a new benchmark of this expanded catalog.

The first catalog CI run (`b4d8c79`) had one failure: OCR in the UI fixture read
“Google Gemma 4 E4B” as “Goocle Gemma 4e48”. All other automated tests passed.
The UI fixture now renders at an explicit 3× scale independent of the runner's
backing scale; the exact model-name and description assertions are retained.

The exact committed revision and final GitHub CI outcome are recorded on
[draft PR #3](https://github.com/leow427/AI-Spotlight/pull/3).

## Prior unified-runtime local checks (`577fad3`)

On the preceding unified-runtime implementation, Xcode 26.6, macOS, Apple M5 Pro, 24 GiB memory:

- `scripts/verify-xcode.sh build`: passed.
- `scripts/verify-xcode.sh test`: **270 tests, zero failures, zero skips**, including
  both explicitly enabled native model tests.
- `scripts/verify-xcode.sh analyze`: passed.
- `git diff --check`: passed.
- All 12 native Screen/panel regressions passed, including rapid streaming,
  immediate combined commands, scrolling after layout, retained attachments and
  source rendering. Interactive region selection was not performed.

CI uses the existing shared-scheme GitHub workflow. Its latest result and exact
commit are recorded on [draft PR #3](https://github.com/leow427/AI-Spotlight/pull/3).
CI does not download model weights; the two optional native fixtures are expected
to be skipped there. No workflow or assertion was weakened.

## Regression coverage

Hardware matrices cover memory/disk classes, Metal limits, CPU execution, speed
ranking and calibration. All newly recommended models require a reviewed
multimodal package. Invalid or extreme metadata, mutable URLs, mismatched projectors,
unsupported architectures, contexts/builds, signature tampering, stale catalogs and
rollback are rejected. Legacy text metadata still decodes.

The ordinary Install action downloads and verifies all parts, selects only a
complete package, preserves unrelated model files, and survives failed upgrades.
Existing tests retain truncation, oversized transfers, checksum failures, HTTP
errors, disk changes, metadata failures, cancellation and rollback coverage.
Migration retires the obsolete local image preference without changing the main
selection or cloud consent. Normal settings render all package choices together;
updates and legacy models remain visible.

Pipeline fixtures assert that image planning and final answering use the same
selected model ID, with no hidden text-engine preparation or inference. OCR-only
screenshots use that model without images. Search on/off, Local/Auto/Cloud routing,
Auto's screenshot context allowance, permission revocation, offline fallback to
the selected local model, query validation, retained drafts, cancellation,
replacement requests, source persistence and image-preview exclusions are covered.

A controlled authenticated loopback subprocess verifies reuse through alternating
text/image requests, switching to another model, cancellation, retry, idle unload,
and immediate cleanup on application termination. Request/process identities
prevent stale cleanup from killing a newer request. Performance checks use server
counts and timings; no model output is shown as a benchmark answer.

## Real Qwen3-VL 4B checks

The official Q4_K_M weights, matching F16 projector and official arm64 b10797
runtime were downloaded to a temporary test directory. Exact publisher sizes and
SHA-256 digests matched. No replacement was downloaded into the owner's installed
library, no cloud screenshot was uploaded, and no live Brave key was used.

The production Swift runtime passed three synthetic red-circle/blue-square
questions. Every answer contained both colors and both shapes. The same resident
process then answered text-only `19 + 23` with `42`. The first cold run took about
19 seconds; subsequent image requests in that run took about 0.6–1.3 seconds.
Later warm-file-cache runs loaded faster. These figures are observations on this
Mac, not advertised latency guarantees.

The seven-case production OCR/search matrix passed using the same selected Qwen
model, a retained runtime and fixed public evidence: serendipity, ubiquitous,
59.7 MB, 57 MB, HTTP 404, HTTP 429, and a visual color-plus-dictionary question.
Queries retained the subject and intent; answers and independently rendered source
links passed their semantic/persistence checks. Intermediate queries remained hidden.

The production performance check generated 64 actual tokens. One final warm-model
run measured approximately 0.060 seconds to first text, 89.8 generation tokens/s,
816 prompt tokens/s, and 5.06 GB combined sampled resident memory. Prompt length
was 46 tokens. Model loading is excluded from first-token latency. These are text
benchmark measurements; the hardware gate separately reserves image processing,
full context/cache memory and headroom.

## Limits and unrelated diagnostics

The 8B and 32B packages have official artifact/checksum, license and architecture
reviews, but were not executed locally. Real-model checks do not certify every
hardware class, dense screenshot, language, diagram or answer. Some shape answers
added an unsupported black-border description despite identifying the requested
objects correctly. Fixed retrieval fixtures verify orchestration and grounding
basics, not Brave availability or complete factual correctness.

The first full run exposed a changed legacy text-import selection behavior. The
installer was corrected and the original failing assertion retained; the final
suite passed. The pre-existing Codex subprocess EOF/timeout test passed in the final
run. There are no unresolved local test failures. Xcode's existing AppIntents
metadata notice and nonfatal AppKit/host-service diagnostics remain; no new
multiple-updates-per-frame warning appeared in the final logs.

The owner retains interactive desktop/region-selection, Screen Recording consent,
secondary-display and Zoom checks. A hard process crash during installation may
leave unused staging files; the committed library stays recoverable and retry is
safe. Answer quality, current system memory pressure and disk availability can
still affect usability. No merge was performed.
