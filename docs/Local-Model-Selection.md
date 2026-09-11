# Enigma local model catalogue

Enigma offers five choices for each memory class, organized as Lightweight,
Middleweight and Heavyweight in both setup and Settings → Local Models. The
16–18 GB group also supplies the starting list below 16 GB (with memory warnings);
the 32 GB group supplies the starting list above 32 GB. Other
quantizations remain available under **Models for other memory sizes**.

Settings → **Discover** also offers a [searchable Hugging Face browser](Model-Discovery.md)
for public vision and audio models, with direct downloads and Gemma 4 26B-A4B
(MoE) Q4_K_M featured independently of the Mac’s recommendation tier. Its default
selection includes all 13 packages without switching memory tiers.

## Catalogue version 5 — reviewed September 10, 2026

These are the requested planning estimates, not measured memory guarantees.
Each distinct quantization has its own ID, immutable revision, byte count and
SHA-256 checksum. Repeated choices share the same descriptor and download.

| Mac RAM | Weight class | Model | Quantization | Model modalities | Planning RAM |
|---|---|---|---|---|---|
| 16–18 GB | Lightweight | SmolVLM2 2.2B | Q8_0 | Vision | ~3.5–4.5 GB |
| 16–18 GB | Middleweight | Qwen3.5 4B | Q4_K_M | Vision | ~4–6 GB |
| 16–18 GB | Middleweight | Gemma 4 E4B | Q4_K_M | Vision + Audio | ~7–9 GB |
| 16–18 GB | Heavyweight | Ministral 3 8B | Q4_K_M | Vision | ~7–10 GB |
| 16–18 GB | Heavyweight | MiniCPM-o 4.5 | Q4_K_M | Vision + Audio | ~8–11 GB |
| 24 GB | Lightweight | Qwen3.5 4B | Q5_K_M | Vision | ~4.5–6 GB |
| 24 GB | Middleweight | Qwen3.5 9B | Q5_K_M | Vision | ~8.5–11 GB |
| 24 GB | Middleweight | MiniCPM-o 4.5 | Q5_K_M | Vision + Audio | ~9–13 GB |
| 24 GB | Heavyweight | Gemma 4 12B | Q5_K_M | Vision + Audio | ~10–13 GB |
| 24 GB | Heavyweight | Ministral 3 14B | Q5_K_M | Vision | ~12–15 GB |
| 32 GB | Lightweight | Qwen3.5 4B | Q8_0 | Vision | ~6–8 GB |
| 32 GB | Middleweight | MiniCPM-o 4.5 | Q5_K_M | Vision + Audio | ~9–13 GB |
| 32 GB | Middleweight | Gemma 4 12B | Q5_K_M | Vision + Audio | ~10–13 GB |
| 32 GB | Heavyweight | Ministral 3 14B | Q8_0 | Vision | ~17–21 GB |
| 32 GB | Heavyweight | Gemma 4 26B-A4B | Q4_K_M | Vision | ~21–25 GB |

There are 13 distinct packages. Qwen3-VL, MiniCPM-V and the earlier QAT Gemma
recommendations are retired from new downloads. Existing installed packages remain
in the library and are not deleted or silently replaced.

## Availability and memory

**MiniCPM-o 4.5 is listed but cannot be installed in this release.** Its publisher
provides a dedicated runtime and separate vision/audio components. Enigma's pinned
upstream llama.cpp b10797 integration has not been validated for that package.
The catalogue keeps its exact metadata and explains the missing runtime. Both
Local Models and Discover offer **Download files**, which opens an in-app file
chooser and downloads the chosen files for use in an appropriate external runtime.

**Audio is a model capability, not an Enigma feature yet.** The current app sends
text and images. Gemma and MiniCPM-o entries explicitly distinguish model audio
capability from the app's available inputs and outputs. Installation packages do
not promise speech support or include the MiniCPM audio/TTS pipeline.

The requested RAM ranges are shown as planning estimates. Recommendations retain
the existing conservative memory budget: at most 60% of physical RAM, physical
RAM minus
at least 4 GiB or 25% reserved for macOS, and 80% of Metal's recommended working
set. Capacity includes 1.2 × weights plus projector, full-context F16 KV cache,
and 2 GiB runtime/compute reserve. All MoE and Gemma PLE weights count in full.
Qwen3.5 reserves KV for its eight full-attention layers (4 KV heads × 256 head
dimension); its recurrent state is covered by the runtime reserve. SmolVLM2 uses
a conservative 24 × 32 × 64 full-context cache bound. Context remains 8,192 tokens.

Some heavyweight entries exceed the recommended budget on their named memory
class, including Gemma 26B on 32 GB. Users can still install compatible packages:
a warning below the install controls explains possible slowdown, swapping or load
failure. This applies to all compatible catalog packages, including the featured
Gemma 26B Q4. Disk space, Metal-buffer support, checksums and architecture checks
remain required. A memory warning cannot hide an actual disk-space failure.
Packages above the memory budget do not load automatically for a post-installation
benchmark; users can choose Check Performance explicitly.

Recommended is selected from the current RAM tier's responsive candidates; it
requires at least an estimated/measured 8 tokens/s and first token within five
seconds. Editorial priorities are not benchmark scores. Check Performance records
actual speed after installation; no response-quality or real-model inference
results are claimed for this catalogue update.

## Download provenance

Model weights and projector pairs come from the same repository and immutable
revision. Mistral and OpenBMB use publisher repositories; SmolVLM2 uses ggml-org's
conversion. The requested Qwen and smaller Gemma quantizations use Unsloth;
Gemma 26B uses Bartowski's exact Q4_K_M, not Unsloth's UD-Q4_K_M variant.
The pinned runtime remains llama.cpp b10797; no dependency upgrade was introduced.

- [SmolVLM2 conversion](https://huggingface.co/ggml-org/SmolVLM2-2.2B-Instruct-GGUF)
- [Qwen3.5 4B quantizations](https://huggingface.co/unsloth/Qwen3.5-4B-GGUF), [9B](https://huggingface.co/unsloth/Qwen3.5-9B-GGUF)
- [Gemma E4B quantizations](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF), [12B](https://huggingface.co/unsloth/gemma-4-12b-it-GGUF), [26B](https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF)
- [Ministral 8B](https://huggingface.co/mistralai/Ministral-3-8B-Instruct-2512-GGUF), [14B](https://huggingface.co/mistralai/Ministral-3-14B-Instruct-2512-GGUF)
- [MiniCPM-o 4.5 publisher package and runtime instructions](https://huggingface.co/openbmb/MiniCPM-o-4_5-gguf)
- [Pinned runtime multimodal support](https://github.com/ggml-org/llama.cpp/blob/b10797/tools/mtmd/README.md), [Qwen3.5 implementation](https://github.com/ggml-org/llama.cpp/blob/b10797/src/models/qwen35.cpp)

## Enigma name and upgrade identity

The app, executable, Xcode targets/shared scheme, menu-bar label, settings titles,
assistant identity, permission guidance and Codex client service metadata now use
Enigma. The repository and source folder retain AI-Spotlight names. The existing
bundle identifier, Keychain service identifier and Application Support paths stay
stable to preserve credentials, chats, model files, preferences and macOS consent.
These are compatibility identifiers, not visible product branding.

![Enigma local model setup](images/local-model-manager.png)

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
checks, anti-rollback caching and offline fallback. Bundled catalog version 5
replaces the previous recommendations. Older text descriptors still decode but
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
