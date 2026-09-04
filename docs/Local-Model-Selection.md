# Automatic local model selection

AI Spotlight detects the Mac before first-run model setup and recommends a
curated GGUF download. Advanced Settings → Local Models uses the same catalog,
compatibility checks, measurements, and installation state. Developer Tools has
**Detect Mac Capabilities** and **Test First-Run Model Selection** buttons.
The latter replays setup without clearing the installed library or preferences.

## Hardware and safety policy

`LocalHardwareProfile` reads physical memory, Apple Silicon support, Metal and
unified-memory availability, chip/model strings, active CPU and performance-core
counts, non-purgeable free disk space on the model volume, low-power mode, and
Metal's recommended working set and maximum buffer length. No serial number is
collected. Detection runs off the main actor. A report is saved locally and is
refreshed on launch, by the developer button, and before a download.

The inference budget is the smallest of:

- 60% of physical memory;
- physical memory minus the larger of 4 GiB or 25% for macOS/other applications;
- 80% of Metal's recommended working set, when available.

The budget is deliberately a conservative capacity estimate, not a promise of
free RAM under arbitrary memory pressure. macOS may still impose pressure when
other applications grow. Runtime estimates include weights, a full 4,096-token
F16 KV cache, and allocation/compute headroom. They are calculated as
`1.2 × GGUF size + KV bytes at the selected context + 0.75 GiB` for this catalog.
Measured peak memory can increase a model's memory requirement, never decrease it.
Native context allocation uses the installed candidate's context, so a larger
context from a future catalog is not silently evaluated at a smaller setting.

Before ranking, candidates must pass descriptor validation, the native
compatibility allowlist, minimum Mac memory, runtime memory budget, Metal buffer
limits, and disk space. The download needs `2 × download size + 2 GiB` because the
existing atomic installer copies the verified file. Installed candidates do not
need another download's disk allowance. Disk space is checked again immediately
before the installation copy. The downloader rejects excess bytes, checks the
exact size and SHA-256, and cleans partial files on failure or cancellation.
Inference also rechecks hardware fit before loading a curated model.

Apple unified-memory Metal and CPU-only inference are supported. Discrete Metal
GPU configurations are conservatively excluded from automatic catalog selection
until a separate CPU/GPU memory policy is reviewed. The bridge chooses CPU
execution when its compiled runtime has no GPU offload support. Maximum Metal
buffer length is checked against a conservative largest-tensor estimate, not the
total GGUF size (large models can consist of many smaller tensors).

## Ranking and measurements

Quality scores are **editorial relative priorities**, not claimed benchmark
results or universal intelligence measurements. The current priorities are 38,
52, 70, 83, and 91 for the Qwen 2.5 1.5B, 3B, 7B, 14B, and 32B families. Q5_K_M
adds one point and Q8_0 two points over Q4_K_M. Review these scores when adding
models; changing a score must not bypass a safety gate.

Performance starts with a conservative heuristic based on CPU resources,
acceleration, weight size, parameter count, and low-power mode. It is not a
chip-name lookup or a specification for the Mac's memory bandwidth. UI text
explicitly distinguishes estimates from measurements.

- **Recommended:** highest-quality safe candidate predicted to produce at least
  8 tokens/second and a first token within 5 seconds for the reference prompt.
- **Faster:** highest-quality responsive alternative with less runtime memory
  and at least 20% faster generation.
- **Smarter:** highest-quality safe candidate above Recommended's quality,
  allowing at least 3 tokens/second and at most 12 seconds to the first token.
- Missing alternatives remain absent. If nothing is responsive, onboarding
  explains this rather than offering an unsafe default. The manager still shows
  memory-safe slow candidates with their warning labels.

After installation, the shared view model blocks other model/chat operations
while the native benchmark runs. Version 1 uses a fixed public home-office
prompt, greedy decoding, and up to 64 actual llama.cpp output tokens. It requires
at least 16 output tokens, checks cancellation between tokens, and stops at a
60-second generation deadline. Native loading and an individual synchronous
prompt decode cannot be interrupted mid-call. Failures and cancellation retain
the verified installation; Settings offers **Check Performance** to retry.

Recorded values:

- First-token latency starts before prompt preparation and excludes model load.
- Generation tokens/second uses actual generated token count and time spent in
  native token sampling/decoding, not text fragments or character counts.
- Prompt tokens/second uses the native formatted/tokenized prompt count divided
  by preparation and prompt evaluation time.
- Memory is the highest sampled total app memory at load, after prompt
  processing, and after each token. Each sample is the greater of Mach physical
  footprint and resident size, avoiding double-counting shared allocations. It
  includes app overhead and mapped weights; it is not isolated model memory or
  a continuous OS high-water measurement.
- Model load time, prompt/output token counts, context, checksum, hardware
  fingerprint, power mode, benchmark version, and llama.cpp build are also kept.

Results live in `~/Library/Application Support/AI Spotlight/Model Recommendations/`
as `hardware.json` and `benchmarks.json`. At most 100 benchmark records are kept.
Recommendations use compatible records from this Mac and power mode for 90 days.
Exact checksum/context measurements override estimates. The latest compatible
same-architecture measurement also calibrates other candidates by weight and
parameter ratios. Upward extrapolation is limited to twice the initial resource
estimate; downward corrections are not suppressed. A measured slowdown can
therefore favor a smaller model, and strong results can favor a smarter one.

Generation below 60% of its prediction, or first-token latency above both
5 seconds and 175% of its prediction, triggers a Faster suggestion when one is
available. Recommendations never download, replace, or select a model by
themselves. Imported GGUFs retain their existing manual workflow; their native
template is checked on load and benchmark results are stored, but unverified
imports do not calibrate curated model recommendations.

## Bundled catalog and compatibility

There are 15 separately pinned candidates: Q4_K_M, Q5_K_M, and Q8_0 for each of
Qwen 2.5 1.5B/3B/7B/14B/32B Instruct. `BundledLocalModels.swift` records the exact
Hugging Face LFS sizes/checksums and repository commits reviewed on 2026-09-04.
The original 1.5B Q4_K_M ID, revision, and checksum are preserved for installed
library compatibility. Curated metadata is persisted with installed models;
legacy libraries decode without migration or file movement.

The bridge remains pinned to **llama.cpp b5046**. This catalog admits `qwen2`,
`chatml`, and the three named quantizations, with context from 4,096 through
32,768 tokens. A signed catalog cannot expand those native capabilities. Qwen3
and other newer architectures need an explicit bridge/app compatibility review.
Qwen 2.5 3B carries the Qwen Research License; the other listed sizes carry
Apache-2.0. Each model's license and model-card link appear in Settings.

Primary metadata and compatibility sources:

- [1.5B GGUF repository](https://huggingface.co/bartowski/Qwen2.5-1.5B-Instruct-GGUF)
- [3B GGUF repository](https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF)
- [7B GGUF repository](https://huggingface.co/bartowski/Qwen2.5-7B-Instruct-GGUF)
- [14B GGUF repository](https://huggingface.co/bartowski/Qwen2.5-14B-Instruct-GGUF)
- [32B GGUF repository](https://huggingface.co/bartowski/Qwen2.5-32B-Instruct-GGUF)
- [Qwen's 7B GGUF model card](https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF)
- [Qwen's 3B GGUF model card and license](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF)
- [Embedded llama.cpp release](https://github.com/ggml-org/llama.cpp/tree/b5046)

## Trusted remote updates

The app always has a bundled fallback. Remote publishing is **not configured**
because no publisher endpoint or signing identity has been supplied. To activate
the implemented update path, the app publisher must add these Info.plist values:

- `LocalModelCatalogURL`: an HTTPS endpoint serving a signed envelope.
- `LocalModelCatalogPublicKey`: the base64-encoded 32-byte Ed25519 public key.

Keep the private signing key outside the repository and application. The response
is a JSON `SignedLocalModelCatalog` with base64 `payload` and `signature` fields.
The signature covers the exact payload bytes. The payload is the Codable JSON
representation of `LocalModelManifest`: an increasing integer `version` and
`models` with the same required fields as the bundled descriptors. Model URLs
must use Hugging Face HTTPS, a 40-character repository revision, and one GGUF
file. Every file requires its exact SHA-256 and size. Multipart GGUF downloads
are not currently supported.

Responses are capped at 1 MiB, signatures are verified before parsing the model
catalog, duplicate IDs/checksums and invalid metadata are rejected, and lower or
same remote versions cannot replace the active catalog. Signed cached envelopes
are verified again on load. Only successfully verified updates are atomically
cached. Offline, HTTP, decoding, signature, and compatibility problems preserve
the cache or bundled fallback. Cached unknown architectures remain visibly
Unsupported and cannot be downloaded through the manager.

A configured source is checked at launch and when the panel is presented, at
most once every 30 days. Failed attempts are also throttled. **Refresh
Recommendations** explicitly retries sooner. No background OS service, account,
analytics upload, or new package dependency is required.

## Verification

The shared Xcode scheme covers deterministic resource matrices, quality ordering,
CPU/Metal behavior, unsupported candidates, metadata/signature tampering,
rollback/offline fallback, successful remote caching, native-install metadata,
download truncation/oversize/checksum/HTTP/disk failures, onboarding persistence,
developer replay, benchmark persistence, performance calibration, and
installation/benchmark cancellation and failure. Native SwiftUI previews are
rendered into XCTest attachments and `docs/images/`.

Hosted unit tests suppress normal app startup so they do not open first-run UI,
register global shortcuts, or request the developer's real Keychain credentials.
The existing controller, shortcut, storage, and conversation tests still run.

Real benchmark smoke verification used the existing SmolLM2 135M Q4_K_M file in
a temporary library, through the production Swift `LlamaCPPModelEngine.benchmark`
and the embedded C++ bridge. It produced 64 tokens from a 146-token prompt,
0.045-second first-token latency, 329 tokens/second generation, 3,444 prompt
tokens/second, and about 280 MiB peak process memory. These numbers validate the
measurement plumbing on this Mac, not the latency estimates of the 15 Qwen
candidates. Running every multi-gigabyte candidate on every hardware class
remains a catalog-release validation responsibility.

Local validation on 2026-09-04: Xcode 26.6, shared `AI-Spotlight` scheme,
macOS destination, `CODE_SIGNING_ALLOWED=NO`: **build passed; all 176 tests
passed; static analysis passed; diff whitespace checks passed**. The only build
warning was the existing AppIntents metadata extraction notice. The first full
run was stopped while the existing app startup was blocked on Keychain access;
the test-host isolation described above resolved it without changing credentials.
GitHub CI status is reported on the pull request.
