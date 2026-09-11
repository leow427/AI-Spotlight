# Discover models

Settings → **Discover** browses Hugging Face's public vision and audio model
listings. **All**, **Vision** and **Audio** filter the task categories; the task
menu narrows the list to image chat, speech recognition, speech generation,
document understanding, image/video processing and the other listed tasks.
**Search** (or Return) searches model names and publishers. **Load more models**
continues through every matching task's pages, with no fixed catalog-size cutoff.

The browser uses Hugging Face's published task tags, including secondary tags,
and includes the `any-to-any` category in both modality filters. That category is
labelled **Multimodal** rather than assuming every model accepts both images and
audio. Models with missing or incorrect publisher tags may not appear in a
capability search. Download order applies to the results loaded so far, not a
claim that the entire Hub has been downloaded or ranked. Duplicate repositories
are shown once.

The featured **Gemma 4 26B-A4B (MoE), Q4_K_M** card is visible on every Mac,
independently of recommendation tier or search filters. It uses the existing
verified Bartowski package, pinned to revision
`10f3b41bcf8d3047f4e136e7197ffc2dd1654c9d`, with the matching F16 image projector
and Enigma's pinned runtime. **Install Q4_K_M**, **Update Q4_K_M** or **Use Model**
uses the existing installer and selection flow. Progress, failure and cancellation
are shown in Discover. The card explains memory or disk limits when unavailable;
it does not broaden the legacy Gemma 12B memory exception. Full MoE weights count
toward memory admission. Gemma 26B is a text-and-image model, without audio input.

**Open on Hugging Face** opens each listing's model card. **See local packages**
appears when the exact repository has an approved package in Local Models.
Browsing does not turn unreviewed Hub listings into installable Enigma packages.
Enigma currently accepts text and images; browsing an audio or image-generation
model does not enable those tasks in the app.

## Networking and failure behavior

- Only opening Discover, submitting a search, changing filters, or requesting
  another page/retry fetches public model metadata. No weights are downloaded by
  browsing, and no chat content, keys or Hugging Face credentials are sent.
- The client uses an ephemeral session without cookies, credentials or a cache.
  Searches are sent to Hugging Face only on submission; typing alone sends nothing.
- At most four task requests run concurrently. Pages request 20 models per task,
  cap responses at 2 MB, and retain Hugging Face's opaque pagination cursors.
- Pagination and redirects stay on HTTPS `huggingface.co/api/models`; next pages
  must retain the search and filters. Repeated pagination links are rejected.
- Partial failures preserve available results. Retry requests only failed task
  pages. Empty searches, connection failures and rate limits have distinct states.
- Changing search or leaving Discover cancels pending work. Late responses cannot
  overwrite a newer search. The bundled featured card remains available offline.

## Verification

Offline XCTest coverage checks query encoding, task coverage, secondary modality
tags, decoding, pagination, duplicate removal, partial failures, retries, late
responses, empty/offline states, the exact Gemma package and memory admission.
Native view rendering checks the app’s dark glass presentation under both light
and dark system appearances. The existing settings render test includes the Discover destination using offline fixtures.

Local verification passed with `scripts/verify-xcode.sh build`, `test` and
`analyze`: 509 tests, 10 optional skips, no failures on the final full run. An
existing welcome-tour click test failed on the first full run, then passed three
isolated repetitions and the full rerun without code or test changes.

![Discover models in dark appearance](images/model-discovery-dark.png)

Live metadata checks also verified two pages each for image chat, audio chat and
speech recognition. A live all-task Gemma 26B search returned the requested
Bartowski Q4 repository with no failed task requests. No model-weight download or
real-model inference benchmark was performed for this discovery change.

Sources checked September 11, 2026:
[Hugging Face search](https://huggingface.co/docs/huggingface_hub/en/guides/search),
[task taxonomy](https://huggingface.co/api/tasks),
[Gemma 26B model card](https://huggingface.co/google/gemma-4-26B-A4B-it),
[Q4 package](https://huggingface.co/bartowski/google_gemma-4-26B-A4B-it-GGUF).
