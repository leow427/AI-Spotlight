# One local model for text and images

AI Spotlight detects the Mac and recommends one complete model package for chat,
screenshots, reasoning and search answers. Use **Find a Model for This Mac** in the
normal model picker or **Settings → Local Models**. Both setup and settings show
up to ten suitable choices in descending order, with a one-sentence description
under every name. There is no separate image-model selection.

**Install** downloads the model, its matching vision encoder/projector, and the
reviewed llama.cpp runtime with its libraries. All components have immutable URLs,
exact byte counts and SHA-256 checksums. Users never select component files during
normal setup. The complete package becomes selected only after installation commits.
The same picker also labels existing text-only models honestly.

![Local model setup](images/local-model-manager.png)

## Catalog reviewed on 2026-09-06

Catalog version 3 contains **12 multimodal packages from four makers**: Alibaba /
Qwen, Google, Mistral AI and OpenBMB. Every entry uses the publisher's own GGUF
repository, a matching projector from the same immutable revision, and the pinned
llama.cpp b10797 runtime. Google uses its official QAT Q4_0 weights; the others use
Q4_K_M. Publisher model cards identify all included weights as Apache-2.0. These
are optional downloads, not weights bundled in the app.

| Package | Maker | Complete download¹ | Runtime memory floor² | Minimum Mac memory | Editorial priority³ |
|---|---|---:|---:|---:|---:|
| Qwen3-VL 4B Instruct | Alibaba / Qwen | 3.34 GB | 6.85 GiB | 12 GiB | 76 |
| Qwen3-VL 8B Instruct | Alibaba / Qwen | 6.20 GB | 10.04 GiB | 24 GiB | 84 |
| Qwen3-VL 32B Instruct | Alibaba / Qwen | 20.97 GB | 27.42 GiB | 64 GiB | 90 |
| Google Gemma 4 E2B | Google | 4.35 GB | 7.17 GiB | 16 GiB | 77 |
| Google Gemma 4 E4B | Google | 6.16 GB | 9.63 GiB | 24 GiB | 86 |
| Google Gemma 4 26B A4B | Google | 15.65 GB | 21.19 GiB | 48 GiB | 91 |
| Google Gemma 4 31B | Google | 18.86 GB | 29.94 GiB | 64 GiB | 93 |
| Mistral Ministral 3 3B | Mistral AI | 3.00 GB | 6.15 GiB | 12 GiB | 70 |
| Mistral Ministral 3 8B | Mistral AI | 6.07 GB | 9.83 GiB | 24 GiB | 81 |
| Mistral Ministral 3 14B | Mistral AI | 9.13 GB | 13.44 GiB | 32 GiB | 85 |
| OpenBMB MiniCPM-V 4 | OpenBMB | 3.16 GB | 5.77 GiB | 12 GiB | 68 |
| OpenBMB MiniCPM-V 4.5 | OpenBMB | 6.13 GB | 9.97 GiB | 24 GiB | 83 |

¹ Decimal bytes including the arm64 runtime; the x64 runtime differs by less than
0.1 MB. ² Capacity estimates, not measurements of free memory. The actual Mac must
also pass OS/Metal reserves, buffer limits and disk checks. An 8 GB Mac receives an
explanation. A typical 24 GiB Apple Silicon profile currently offers eight suitable
choices; the list never inserts unsafe or duplicate quantizations to reach ten.

³ Priorities are editorial estimates of general text and screenshot usefulness,
informed by the publishers' text/vision evaluations and intended tasks. They are
**not benchmark scores, a universal leaderboard, or guarantees that more parameters
produce better answers**. Google E4B provides a balanced general alternative;
Qwen3-VL and MiniCPM-V prioritize document/image understanding; Ministral provides
another general chat/instruction-following family. Small variants trade reasoning
capacity for footprint; larger variants need both memory and acceptable speed.
MiniCPM-V 4.5 is an OpenBMB model built on Qwen3 and SigLIP2, disclosed in its row.

The ranking applies resource safety first, puts responsive choices ahead of slower
ones, then orders by editorial priority, speed and stable model ID. The first
responsive choice receives Recommended. Only the first ten runnable choices appear
in the main list; **Other models and hardware limits** preserves access to the rest,
including reasons and disabled Install buttons for incompatible packages. Slow
choices explicitly say “May be slow” and never receive the Recommended badge.

New families were reviewed against publisher configurations, embedded GGUF
architecture/template metadata and the pinned runtime's implementations. Gemma's
PLE weights and all MoE experts count in full. Gemma 4 12B's unified architecture
is deferred pending its own review. Publisher instructions flag extreme image
aspect ratios as a Ministral quality limitation. Response-quality testing for the
new families is left to the owner as requested; no new-family response results are
claimed. The existing Qwen 4B fixtures remain documented in
[verification](Screen-Search-Verification.md).

Primary sources:

- [Google Gemma 4 capabilities, memory and QAT guidance](https://ai.google.dev/gemma/docs/core)
- [Mistral Ministral 3 model card](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512)
- [OpenBMB MiniCPM-V 4](https://huggingface.co/openbmb/MiniCPM-V-4), [4.5](https://huggingface.co/openbmb/MiniCPM-V-4_5) and [Apache license](https://github.com/OpenBMB/MiniCPM-V/blob/main/LICENSE)
- [Qwen 4B official files](https://huggingface.co/Qwen/Qwen3-VL-4B-Instruct-GGUF/tree/1cd86afb9a95c410a6038ab3b40d8b578c892266), [8B](https://huggingface.co/Qwen/Qwen3-VL-8B-Instruct-GGUF/tree/f982a07559d4a2f6c8744d840bf6fccab30eea96), [32B](https://huggingface.co/Qwen/Qwen3-VL-32B-Instruct-GGUF/tree/e3e1fe0c76de7ee58ea65db420c643adfe2e457c)
- [Google Gemma 4 E2B: official card and pinned files](https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/tree/675cff42a74c774d6cb76f76d8eacb49b48c9b93)
- [Google Gemma 4 E4B: official card and pinned files](https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf/tree/4b4a2c1d584be7264f87aac328a1bc739ce81b6c)
- [Google Gemma 4 26B A4B: official card and pinned files](https://huggingface.co/google/gemma-4-26B-A4B-it-qat-q4_0-gguf/tree/d1c082be9cf3c8a514acf63b8761f4b41935842e)
- [Google Gemma 4 31B: official card and pinned files](https://huggingface.co/google/gemma-4-31B-it-qat-q4_0-gguf/tree/59dde24573e7e61570dba08b18a2e1fe246955ed)
- [Mistral Ministral 3 3B: official card and pinned files](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/tree/eb599d408350ea2bb60452cb86be7c7b2fc28227)
- [Mistral Ministral 3 8B: official card and pinned files](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF/tree/0102285ad796bd99af90f58de616092e5630e970)
- [Mistral Ministral 3 14B: official card and pinned files](https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF/tree/74fac473c43357d7fb2671713608183cc72496d0)
- [OpenBMB MiniCPM-V 4: official card and pinned files](https://huggingface.co/openbmb/MiniCPM-V-4-gguf/tree/c548a86e76648fe1cef8250ba60d7f2d9ba0996e)
- [OpenBMB MiniCPM-V 4.5: official card and pinned files](https://huggingface.co/openbmb/MiniCPM-V-4_5-gguf/tree/8bfaecb5b1a65f068b86c32b997a3d5d8902eb36)
- [Pinned Gemma implementation](https://github.com/ggml-org/llama.cpp/blob/b10797/src/models/gemma4.cpp), [Ministral](https://github.com/ggml-org/llama.cpp/blob/b10797/src/models/mistral3.cpp), [MiniCPM 4](https://github.com/ggml-org/llama.cpp/blob/b10797/docs/multimodal/minicpmv4.0.md), [MiniCPM 4.5](https://github.com/ggml-org/llama.cpp/blob/b10797/docs/multimodal/minicpmv4.5.md)
- [Runtime release and checksums](https://github.com/ggml-org/llama.cpp/releases/tag/b10797), [server protocol](https://github.com/ggml-org/llama.cpp/blob/b10797/tools/server/README.md)

## Hardware policy

Detection reads physical memory, Apple Silicon, Metal/unified memory, CPU resources,
non-purgeable free disk, low-power mode and Metal working-set/buffer limits. No
serial number is collected. The inference budget remains the smallest of:

- 60% of physical memory;
- physical memory minus the larger of 4 GiB or 25% for macOS and other apps;
- 80% of Metal's recommended working set, when present.

For these packages, estimated memory is `1.2 × (language weights + vision weights)
+ full F16 KV cache + 2 GiB`. The cache uses the actual 8,192-token allocation:
`sum(layer KV heads × head dimension) × 4 bytes for K+V × context`.
Qwen 4B/8B and MiniCPM 4.5 use 36×8×128; Qwen 32B uses 64×8×128;
Ministral 3B/8B/14B use 26/34/40×8×128; MiniCPM 4 uses 32×2×128.
Gemma uses per-layer sums for its different global/sliding dimensions and heads:
E2B `(28×1×256 + 7×1×512)`, E4B `(35×2×256 + 7×2×512)`,
26B `(25×8×256 + 5×2×512)`, 31B `(50×16×256 + 10×4×512)`.
We conservatively reserve full context even on shared/sliding layers. Actual GGUF
weight bytes include Gemma PLE tables and all MoE experts; active parameter counts
never determine capacity. The additional reserve covers vision activations,
compute buffers, runtime and application overhead. Image input is bounded to
4,096 tokens and the preprocessor's existing 1,568-pixel longest edge. The runtime
cannot silently increase context or allocate a separate 8 GiB prompt cache.

Weights, encoder and runtime all count toward disk admission:
`2 × complete download + 2 GiB`. Free disk is checked again before installation.
Installed candidates avoid a new-download disk gate for selection, while an actual
update still checks the full required space. Apple unified-memory Metal and CPU
execution are supported; discrete Metal remains excluded from recommendations.
Metal buffer limits apply to a conservative largest-tensor bound.

Safety gates precede ranking. Recommended requires an estimated/measured 8 tokens/s
and a first token within 5 seconds. The existing faster-alternative suggestion for
underperforming benchmarks still requires less memory and at least 20% more speed.
The speed estimate is a conservative CPU/acceleration/weight-size heuristic for a
reference text prompt. Image encoding and cold model loading add latency.

After installation, **Check Performance** measures a fixed public text prompt on
the selected runtime with 64 generated tokens and a 60-second generation deadline.
The multimodal runtime reports actual prompt/generation token counts and speeds;
first-token timing starts after loading. Combined application/server resident
memory is sampled every 20 ms and after completion. This conservative RSS sum can
double-count shared library pages; it is not a continuous OS high-water mark or a
measurement of every possible image. The image/cache memory floor still applies.

Benchmark failures/cancellation keep the verified installation. Measurements are
stored locally and scoped to runtime build, hardware, power mode, checksum and
context; they expire after 90 days. Exact measurements override speed estimates and
can increase the memory requirement. Same-architecture calibration is bounded to
twice the resource prior. The embedded engine remains for legacy text models only.

## Installation, upgrades and migration

Transfers report cumulative received bytes across all three artifacts, reject
oversized responses while receiving, and verify exact size and checksum. After
100% received, the UI says it is verifying/installing. Cancel remains available
through verification. Runtime extraction validates paths and symlinks, checks
executable support and retains its accompanying libraries.

The installer copies into fresh immutable filenames. An atomic metadata write is
the commit point. Cancellation is checked between copies and before committing.
Failures remove uncommitted files/runtime and keep the previous selection and bytes.
A successful same-ID update keeps the existing main selection and retires only the
replaced package's app-owned files. Different legacy models are never deleted.
A fully committed package remains installed if cancellation arrives after commit.
An interrupted process cannot expose a partial package as installed; retrying is
safe. A hard crash can leave unused staging files, which are never selected.

Existing single-record and library metadata still decode. The obsolete
`screen.localVisionModelID` preference is retired without changing the normal
selection, consent settings or model files. A selected text-only model continues
text chat and suitable OCR requests. Visual questions explain how to install and
select a capable package in the existing Local Models tab. Already installed
compatible image packages remain selectable for all requests, with legacy labels.
The known incompatible original SmolVLM 2.2B image package gets explicit replacement
guidance; its text/OCR use and files are retained. No migration downloads anything.

Signed remote updates retain signature verification, bounded responses, monthly
checks, anti-rollback caching and offline fallback. Bundled catalog version 2
replaces the old text recommendations. Older text descriptors still decode but
cannot become new recommendations/downloads. A signed catalog cannot expand the
reviewed architecture, context, runtime or artifact validation. Remote publishing
is still unconfigured; activation requires `LocalModelCatalogURL` and the base64
Ed25519 `LocalModelCatalogPublicKey` in Info.plist. Never bundle the private key.

## Runtime lifecycle

A single authenticated loopback-only llama-server serves the selected package.
Text, OCR, image planning and final-answer requests reuse the process and weights.
Each request supplies its prepared conversation; prompt-cache reuse is disabled,
and no conversation or screenshots are saved by the server. Switching models,
request cancellation/failure, application termination, and explicit unloading close that child and its
network session. Idle unloading occurs after five minutes without generation.
Cleanup from an older request cannot terminate a newer model process. Startup and
shutdown are bounded, with forced child termination if graceful shutdown stalls.
The embedded b5046 bridge remains only for existing text-only installations.
