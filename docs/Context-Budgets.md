# Conversation context and budgets (Group A)

Saved `ChatSession.messages` remains the complete transcript. Request preparation
copies a suffix of complete user/assistant turns and the new user message, once.
It discards empty assistant placeholders and unanswered/orphaned history from the
request only. An oversized recent turn ends the suffix; older disconnected turns
are not substituted. Partial, nonempty assistant replies remain usable context.
The chat displays a notice whenever any saved messages are omitted. No archive or
model-library migration is needed.

A current message that cannot fit is rejected before transcript insertion and
before the composer acceptance callback. Its original draft, including whitespace,
remains editable. Local acceptance waits for model loading and exact tokenization.
All Cloud clients enforce preparation again at their serialization boundary.

## Single source of limit policy

`Chat/ChatContext.swift` owns `ModelContextPolicy`, `ContextBudget`, and Cloud
serialization estimates. `CloudModel.contextBudget`, Auto routing, the view model,
and outgoing Cloud clients use it. Group E added `CloudModelCapabilities` as the
shared source of reviewed endpoint compatibility and published model limits.
See [Cloud-Model-Selection.md](Cloud-Model-Selection.md) for exact IDs and provider
sources. Unknown IDs do not inherit limits from a name prefix. Compatibility and
limit metadata do not certify account access or billing.

| Route/model | Context window or application policy | Reserved output | Reserved protocol | Input cap |
|---|---:|---:|---:|---:|
| Local | Smaller of runtime allocation, GGUF training context, and configured context (default 4,096) | 512 by default | Exact template/special tokens counted, plus 1 spare token | Remaining capacity |
| OpenAI GPT-5.6 Luna/Terra/Sol and `gpt-5.6` API alias | 1,050,000 supported context | 4,096, sent as `max_output_tokens` | 512 | 32,768 |
| OpenAI GPT-5.4 Mini and GPT-5 Mini, reviewed IDs | 400,000 supported context | 4,096 | 512 | 32,768 |
| OpenAI GPT-4.1 / Mini, reviewed IDs | 1,047,576 supported context | 4,096 | 512 | 32,768 |
| OpenAI GPT-4o / Mini, reviewed IDs | 128,000 supported context | 4,096 | 512 | 32,768 |
| Other OpenAI IDs and Anthropic IDs | Conservative 8,192 application policy | 4,096, sent as `max_output_tokens`/`max_tokens` | 512 | Remaining 3,584 |
| Codex GPT-5.6 Luna/Terra/Sol, exact IDs | 1,050,000 supported context | 128,000 | 8,192 | 32,768 |
| Other Codex IDs | Conservative 32,768 application policy | 16,384 | 8,192 | Remaining 8,192 |

The actual input allowance is the smaller of the cap and context minus output and
protocol reserves. Unknown/manual IDs stay usable under a conservative policy;
these values do not certify their actual provider limits. Known incompatible
OpenAI model families are rejected before sending. An unverified model with a
smaller window or incompatible endpoint can still reject a request. The app does not
assume every manually entered model has 128,000 tokens. Expanding verified
metadata belongs in the shared policy, with provider sources and regression tests.

Cloud input is conservatively charged one token per UTF-8 byte of serialized
message roles/content, including JSON escaping. Codex charges its actual supplied
text, including the conversation prefix and JSON envelope. Protocol reserves cover
hidden/provider instructions separately. This can retain less history than a
provider tokenizer would allow, particularly for ASCII prose. There is no token
counting network request or tokenizer dependency. Auto uses a conservative byte
estimate to choose a route; Local then measures its selected GGUF exactly.

Codex App Server 0.151.0's generated `TurnStartParams` has no maximum-output-token
field. The Codex reserve is headroom, not an enforced response-length control;
for the known models it reserves the published full 128,000-token maximum.
Unknown Codex model output behavior and server-added prompt overhead cannot be
certified locally. No unsupported configuration override is sent. Existing Stop,
server interruption, ephemeral thread cleanup, and text-only restrictions remain
in place.

## Native Local behavior

`LocalModelRequest` carries ordered messages. `AISLlamaEngineCountChatTokens` and
`AISLlamaEngineBeginCompletion` share the native multi-message formatter and the
selected model's tokenizer. The bridge refuses missing/unsupported chat templates
instead of falling back to a latest-prompt-only string. Choose a compatible GGUF
instruct/chat model if this error occurs. Embedded null characters are rejected
rather than silently truncating C strings.

Every completion clears its KV cache and replays only the prepared conversation,
which prevents cross-chat/model leakage. The native boundary also checks the full
output reserve, so callers cannot squeeze input in by silently reducing output.
Explicit Local uses installed files only. Legacy text-only models use the
embedded bridge. Recommended multimodal packages use the pinned local server with
8,192 tokens, a 512-token output reserve, 256 protocol tokens and up to 4,096 image
tokens. Text is conservatively charged one token per UTF-8 byte plus message
framing. Context shifting and prompt-cache reuse are disabled. See
[the current local model policy](Local-Model-Selection.md).

## References checked 2026-09-04

- [GPT-5.6 Luna](https://developers.openai.com/api/docs/models/gpt-5.6-luna),
  [Terra](https://developers.openai.com/api/docs/models/gpt-5.6-terra), and
  [Sol](https://developers.openai.com/api/docs/models/gpt-5.6-sol): supported context
  and maximum output sizes. Only exact IDs listed above receive these limits.
- [Codex App Server](https://learn.chatgpt.com/docs/app-server) and the installed
  CLI's generated JSON schema: thread/turn controls and model-list fields.
- llama.cpp b5046 headers from the project's pinned binary: model training context,
  template application, tokenizer, allocated context size, and batch capacity.
