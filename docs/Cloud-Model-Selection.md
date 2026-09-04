# Cloud model selection (Group E)

AI Spotlight's OpenAI client implements streaming text conversations with
`POST /v1/responses`, string user/assistant messages, `store: false`, and a bounded
`max_output_tokens`. The general [OpenAI Models API](https://developers.openai.com/api/reference/resources/models)
is an account model listing, not a certification that each entry accepts this
request. A model-list check never sends a generation request.

## Compatibility and defaults

`CloudModelCapabilities` owns both reviewed endpoint compatibility and published
context/output limits. `ModelContextPolicy` uses that metadata for the existing
Group A budgets; catalog selection, settings, Auto, and request preparation do
not maintain separate model-limit tables.

OpenAI discovery returns only exact IDs reviewed for text input/output, Responses,
and streaming. The table below is the app's fallback order, not alphabetical or
provider-list order. It favors Luna for the lightweight default, then smaller
general-purpose alternatives before larger models. Within a row the alias is
preferred, followed by the listed snapshots. This is a product selection policy,
not a live price comparison or a guarantee of account access.

| Preference | Reviewed API IDs (in order) | Published context | Published maximum output | Provider source |
|---|---|---:|---:|---|
| 1 | `gpt-5.6-luna` | 1,050,000 | 128,000 | [Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna) |
| 2 | `gpt-5.4-mini`, `gpt-5.4-mini-2026-03-17` | 400,000 | 128,000 | [GPT-5.4 Mini](https://developers.openai.com/api/docs/models/gpt-5.4-mini) |
| 3 | `gpt-5-mini` | 400,000 | 128,000 | [GPT-5 Mini](https://developers.openai.com/api/docs/models/gpt-5-mini) |
| 4 | `gpt-4.1-mini`, `gpt-4.1-mini-2025-04-14` | 1,047,576 | 32,768 | [GPT-4.1 Mini](https://developers.openai.com/api/docs/models/gpt-4.1-mini) |
| 5 | `gpt-4o-mini`, `gpt-4o-mini-2024-07-18` | 128,000 | 16,384 | [GPT-4o Mini](https://developers.openai.com/api/docs/models/gpt-4o-mini) |
| 6 | `gpt-5.6-terra` | 1,050,000 | 128,000 | [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra) |
| 7 | `gpt-5.6-sol`, `gpt-5.6` | 1,050,000 | 128,000 | [Sol and its API alias](https://developers.openai.com/api/docs/models/gpt-5.6-sol) |
| 8 | `gpt-4.1`, `gpt-4.1-2025-04-14` | 1,047,576 | 32,768 | [GPT-4.1](https://developers.openai.com/api/docs/models/gpt-4.1) |
| 9 | `gpt-4o`, `gpt-4o-2024-11-20`, `gpt-4o-2024-08-06` | 128,000 | 16,384 | [GPT-4o](https://developers.openai.com/api/docs/models/gpt-4o) |

Sources reviewed on **2026-09-04**. This is intentionally a reviewed subset, not
an exhaustive provider catalog. Other aliases, older/deprecated snapshots, new
models, and fine-tuned IDs remain available through manual entry with unverified
feedback. Supporting another automatic choice requires reviewing its exact ID,
text modality, endpoint, streaming, request options, and limits in provider docs,
then updating this shared metadata and regression coverage.

Image, embedding, video, speech, transcription, realtime, and moderation families
are unsupported by this app's text-chat request. Family matching is only used to
identify these incompatible categories, using an exact name or hyphen boundary;
it never grants compatibility. The [official model catalog](https://developers.openai.com/api/docs/models/all)
documents these specialized categories. Unknown names are unverified rather than
assumed to work because they begin with `gpt-`.

Anthropic and Codex retain their provider-supplied chat model order. Anthropic's
[Models API](https://platform.claude.com/docs/en/api/models/list) lists the models
available for its API, with newer releases first. Codex uses its existing
`model/list` integration. Neither route inherits the OpenAI API allowlist. The
existing Codex Luna default and its three exact GPT-5.6 limit entries are retained;
the OpenAI `gpt-5.6` alias is not certified for Codex.

## Saved and manual choices

- Only an empty preference can receive an automatic default. A nonempty saved or
  manual choice survives discovery, cache loading, provider changes, connection
  checks, and an absent entry in a later list.
- A reviewed compatible ID can be entered manually even when discovery fails or
  the account list omits it. The feedback explicitly separates chat compatibility
  from account access and billing.
- An unsupported ID stays visible and editable. Sending is disabled, and request
  preparation also rejects it before accepting a draft or inserting transcript
  messages. Direct provider calls get the same rejection before network access.
- An unknown ID stays usable under Group A's conservative budget. Settings and
  idle Cloud feedback identify it as unverified. The provider can reject it when
  the user sends; no free compatibility claim or implicit paid probe is made.

A syntactically valid empty list, or a list with no reviewed compatible choices,
is a successful account/model-list check with zero compatible models. Settings
explain how to refresh or enter an ID. An empty preference remains empty; an
existing preference remains intact. Authentication errors and malformed lists
remain errors.

## Caches, request limits, and verification

The cache format and 24-hour lifetime are unchanged. Raw discovered IDs stay in
the cache; every read reapplies current compatibility rules, including reads of
pre-fix caches. Duplicate, empty, and wrong-provider entries are excluded. No
model files, chat archives, or preferences require migration. Users with a saved
incompatible choice must explicitly choose a different model.

All reviewed OpenAI models retain the app's 32,768-token input cap, 4,096-token
reply cap, and 512-token protocol reserve. Unknown models retain the conservative
8,192-token application policy. See [Context-Budgets.md](Context-Budgets.md) for
the complete estimation and trimming behavior. Compatibility does not certify
quotas, billing, account entitlement, model answer quality, or future availability.

`CloudModelSelectionTests` exercises production catalog/cache/settings logic,
request preparation, and the Responses client through controlled network seams.
It covers the mixed-list regression, no-compatible results, preserved selections,
manual feedback, account/compatibility separation, in-flight preference changes,
and shared-budget boundaries. No API key or live paid request is needed.
