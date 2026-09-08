# Local File Mode reliability evaluation

This evaluation uses synthetic disposable workspaces and the actual installed local inference runtime. Deterministic tests verify safety and recovery separately from live-model accuracy. The selected model, installed models and saved model settings were not changed, and no cloud inference or model download was used.

## Environment and method

- Baseline application revision: `e12305a2390d7b895f2562e63b5b763845f6a057`, with opt-in diagnostics, configurable generation/context budgets and the evaluation harness added before changing editing behavior.
- Model: Qwen 2.5 3B Instruct Q8_0, catalog ID `qwen2.5-3b-instruct-q8-0`. Verified GGUF SHA-256: `12491ec9f03aab7f0b96cdb7742695e6583d17ee129de48332d04b9cf6acd960`.
- Runtime: installed `llama-server` b10797, version `0.3.0-dev`, commit `832fd6f17`, Darwin arm64, AppleClang 21. The existing pinned runtime from an installed vision package also supports text GGUF inference.
- Host: macOS 26.6.2 (25G83), Xcode 26.6 (17F113).
- Selected model's production context: 4,096 tokens. The earlier smoke fixture reconstructed a model without its catalog metadata and therefore used the imported-model default of 8,192. Smoke tests now retain installed metadata when the file matches the selected model.
- Controlled response-limit comparison: 1,024, 2,048 and 4,096 output tokens, all with **8,192 context tokens**, identical task wording, model, tool schemas and sampling within each implementation. A 4,096-token output reservation cannot fit in a 4,096-token context with instructions and tools. Additional 1,024-output runs use the selected model's actual 4,096 context.
- Request settings: temperature 0, `cache_prompt: false`, `tool_choice: auto`, `parallel_tool_calls: false`, nonstreaming. Runtime flags include `--jinja`, `--offline`, `--no-context-shift`, `--cache-ram 0`, `--reasoning-budget 0`, `--fit off`, and one parallel slot. Loopback inference uses an ephemeral API key.
- Runtime defaults recorded from `/props`: top-k 40, top-p .95, min-p .05, repeat penalty 1, repeat-last-n 64, presence/frequency penalties 0, seed 4294967295 (runtime default). Request temperature and maximum tokens override the runtime defaults. Temperature zero does not guarantee identical GPU/runtime output.
- Each attempt starts with new files, a new workspace journal and a cold model process. Latency includes load, inference, tools and unload; it excludes fixture creation and independent post-run assertions/Undo. Results are sequential, not concurrent benchmarks. The OS file cache and machine thermals were not reset between attempts.

Each model response records the rendered prompt token count, requested output/context budgets, available generated/input token usage, finish reason, runtime sampling defaults, elapsed time and a bounded response preview. The controller records tool names, bounded arguments/results, errors, discarded speculative calls, duplicate suppression and recovery. Every attempt records exact-content and RTF attribute checks, actual file hashes/previews, error, elapsed time and byte-for-byte Undo. Opt-in traces contain synthetic text; production does not log document contents.

All attempts, including unsuccessful development pilots and deterministic test failures, are retained. The runner refuses to overwrite output, appends a start record before each attempt, flushes finish records before assertions, and reports unfinished attempts. A failed evaluation exits nonzero after collecting every scheduled case. There is no retry-until-green filtering.

## What was confirmed

1. **The original tiny-file response-length incident was not reproduced in the controlled baseline.** At 8,192 context, all 60 core attempts finished with correct files; responses were far below 1,024 tokens. The old generic error log cannot establish the historical cause. Increasing the response limit is not a demonstrated fix for that incident.
2. **Output truncation did occur on medium-file tasks.** Captured responses reached `finish_reason: length` at 1,024 generated tokens, with about 2,777–2,778 prompt tokens. The model quoted the document in its answer, sometimes before editing and sometimes after a correct edit. This is measured output truncation, not context exhaustion. Raising the limit sometimes allowed that unnecessary quotation to finish, at much greater latency.
3. **Context exhaustion and repeated calls were separate observed failures.** In 20 baseline core attempts at the selected 4,096 context, the file became correct but the agent continued read/rewrite calls after an invalid patch. All 20 eventually hit the context guard. Individual responses were roughly 124–178 tokens; the prompt/history grew instead. This does not prove that repetition caused the earlier response-length incident.
4. **Speculative batches and invalid arguments were common.** Baseline core responses batched list/read, an invalid patch using the filename as `old_text`, a correct full write and another read. The dependent edit was proposed before the model saw the read result. The native runtime emitted batches despite `parallel_tool_calls: false`.
5. **Wrong edits were not fixed by a larger output allowance.** Observed errors included empty `old_text` for append, copying adjacent unchanged lines, an extra newline inside a Swift string, dropping RTF punctuation, and claiming completion after a failed mutation. These were valid-length responses with tool/semantic errors.
6. **Baseline inputs had avoidable ordering variation.** Network schemas were sorted, but attachment context and encoded tool results were not. They are now sorted too. This is an implementation difference and a confound in interpreting individual historical limit/context comparisons; ordering alone was not isolated as the cause. File size, task wording, runtime variation and history can all affect behavior. The final limit comparison uses stable ordering throughout.

The 5,306-character medium fixture sometimes caused long quotation while a 54,106-character file could succeed. This is evidence against assuming a simple file-size threshold. The controller formerly allowed reads of 32,000 characters, making large histories and quotations easier, although the app did not explicitly demand full-file replacements for targeted tasks. The core fixture deliberately requests a full five-character replacement; the broader tasks do not.

## Changes

- Execute one complete call per inference step, discard speculative dependent calls and remove their content from history. Never execute partial JSON or assistant prose.
- Use 2,000-character query-centered excerpts with pagination metadata. Query searches the whole authorized file even when a model also sends a previous offset. Stable ordering applies to all model-visible JSON.
- Add `append_file` through the shared workspace/document layer. UTF-8 and text-only RTF append without asking the model to reproduce existing content. Receipts read the actual tail even when the appended text occurs earlier.
- Require local patches to match an observed read/search excerpt. Reject ambiguous/missing matches separately. Require full affected lines for structural newline changes and reject accidental copying of the next unchanged line. Errors explain how to supply a wider exact match; legitimate structural edits remain expressible.
- Return bounded read-back receipts, explicit move/delete existence results and actionable argument errors. A missing authorized leaf is distinguished from a blocked link/special file; exhausted argument recovery includes the last error. Verify actual journal after-images before completion and before acknowledging a duplicate. This checks disk state, not the semantic correctness of the model's chosen replacement.
- Allow at most two fresh-response recoveries for truncation or premature completion after a correctable failed mutation. Allow at most two recoverable tool errors, stop three identical unproductive results, and retain the overall 16-step cap. Never accept completion with an unresolved failed mutation.
- Deduplicate identical successful mutations by tool name and canonical arguments across call IDs. Verify current state before acknowledging one. Hash canonical read paths to reject external changes even before the first write; recovery and Undo do not overwrite newer external work.
- Reserve the complete requested output budget and 64-token margin after exact tool-template tokenization. Distinguish output truncation, context exhaustion and runtime HTTP failures. Default output/context settings remain unchanged.

The shared service continues to own scope checks, classification, cloud consent, snapshots, rollback and Undo. Inference remains in the inference engine. No shell, expanded filesystem access, cloud fallback, new dependency or permission-policy exception was added.

## Results

Definitions: **first-pass** means correct files/formatting, successful controller completion and exact Undo without an inference/tool error or duplicate recovery. It does not mean a single model response or perfect model output: the controller's normal filtering of speculative batches is counted separately, not as a retry. **Eventual** permits the bounded recoveries. **Correct** independently checks the final file set and contents/formatting even if the controller later fails. Undo checks original names and bytes after every attempt, including failures. Assistant prose cannot override the file oracle.

For the English ambiguous-task prompt, success additionally requires no mutation and a clarification identifying the occurrence/First/Second choice. The automated rubric requires a target term (`occurrence`, `first`, `second`) and a question/choice term (`which`, `choose`, `specif`, `?`); the recorded replies are also inspected. This stricter criterion was added after a pilot safely preserved files but asked about an incorrect path. It is applied consistently to all earlier records by the summarizer without rewriting raw scores; the CSV retains both recorded and adjusted success. All baseline ambiguity replies meet it. File correctness remains an independent column.

Baseline core, 20 attempts per row:

| Context | Output limit | First-pass | Eventual | Correct | Undo | Median seconds |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8,192 | 1,024 | 0/20 | 20/20 | 20/20 | 20/20 | 5.31 |
| 8,192 | 2,048 | 0/20 | 20/20 | 20/20 | 20/20 | 5.41 |
| 8,192 | 4,096 | 0/20 | 20/20 | 20/20 | 20/20 | 5.42 |
| 4,096 | 1,024 | 0/20 | 0/20 | 20/20 | 20/20 | 23.88 |

Final core with the production implementation held fixed, 20 attempts per row:

| Context | Output limit | First-pass | Eventual | Correct | Undo | Median seconds |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 8,192 | 1,024 | 20/20 | 20/20 | 20/20 | 20/20 | 7.03 |
| 8,192 | 2,048 | 20/20 | 20/20 | 20/20 | 20/20 | 7.05 |
| 8,192 | 4,096 | 20/20 | 20/20 | 20/20 | 20/20 | 7.43 |
| 4,096 | 1,024 | 20/20 | 20/20 | 20/20 | 20/20 | 7.05 |

Final core responses used at most 124 generated tokens; rendered prompts ranged from 1,583 to 1,875 tokens. Median inference calls rose from three to five because reads and writes are now sequential. This adds about 1.7–2.0 seconds to the successful 8,192-context baseline, while eliminating executed invalid calls in this sample. The larger output limits provided no core-task correctness benefit.

Broader baseline: 12 tasks × three attempts per output limit, all at 8,192 context. Tasks cover targeted replacements in 102/5,306/54,106-character files, create, append, two targeted changes, two files, formatted RTF, protected Swift fallback, ambiguity, delete and move.

| Output limit | First-pass | Eventual | Correct | Undo | Median seconds | Recorded failures |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1,024 | 21/36 | 24/36 | 26/36 | 36/36 | 4.27 | 4 output truncations, 7 incorrect edits, 1 step limit |
| 2,048 | 21/36 | 25/36 | 25/36 | 36/36 | 4.33 | 2 output truncations, 8 incorrect edits, 1 step limit |
| 4,096 | 18/36 | 22/36 | 23/36 | 36/36 | 3.84 | 4 context-budget failures, 10 incorrect edits |

Failure labels can overlap: a run can have wrong final contents and a later host error. Low latency in a failing run is not evidence of useful performance.

Final broader comparison, the same 108 tasks and 8,192 context:

| Output limit | First-pass | Eventual | Correct | Undo | Median seconds | Failures |
| ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1,024 | 24/36 | 30/36 | 33/36 | 36/36 | 4.80 | 3 wrong RTF punctuation, 3 incorrect clarifications |
| 2,048 | 24/36 | 30/36 | 33/36 | 36/36 | 4.79 | Same |
| 4,096 | 24/36 | 30/36 | 33/36 | 36/36 | 4.83 | Same |

The final **selected-context** matrix (4,096 context/1,024 output, three repeats per task) also produced **24/36 first-pass, 30/36 eventual, 33/36 correct and 36/36 exact Undo**, median 4.78 seconds, with the same punctuation and clarification failures. No larger context or model was needed for its successful tasks.

No final broader run hit output truncation, a context guard or the step limit. At 1,024 output, medium-file correctness increased from 1/3 to 3/3 and median latency fell from 16.41 to 4.33 seconds. Larger-file correctness increased from 0/3 to 3/3. Append and multiple targeted edits each rose from 1/3 to 3/3. Protected Swift stayed 3/3, with the new guard recovering the observed extra newline. Small-file median latency rose from 3.54 to 7.50 seconds because the guard rejected and recovered an extra newline. These are small task-specific samples, not independent proof of each change's contribution.

**The unquoted RTF punctuation task regressed in this sample:** it failed all nine final broad attempts. The controller verifies the actual chosen edit but cannot recognize that the model dropped the requested `!`. This remains an explicit limitation, not a passing formatting result. Where visible text length was wrong, the equal-length attribute comparison also could not pass; this is not evidence that the codec discarded formatting. All failed edits remained undoable.

Development pilots at 4,096 context/1,024 output, one attempt per broad task, retained in order:

| Candidate | First-pass | Eventual | Correct | Undo | Finding that motivated the next change |
| --- | ---: | ---: | ---: | ---: | --- |
| 1 | 9/12 | 11/12 | 12/12 | 12/12 | Move completed but model guessed paths afterward; append used empty match |
| 2 | 7/12 | 7/12 | 7/12 | 12/12 | Speculative label-only patches and wrong newlines; shorter-looking schemas did not ensure accuracy |
| 3 | 5/12 | 5/12 | 5/12 | 12/12 | Query combined with old pagination offset hid the target; recovery feedback lacked the excerpt |
| 4 | 8/12 | 8/12 | 8/12 | 12/12 | Search-based patches needed observation credit; append and premature completion needed recovery |
| 5 | 8/12 | 8/12 | 9/12 | 12/12 | Extra line break in small text/Swift; dropped punctuation and incorrect clarification |
| 6 | 8/12 | 10/12 | 11/12 | 12/12 | Newline errors recovered; punctuation and clarification still wrong |
| 7 | 8/12 | 8/12 | 9/12 | 12/12 | Added path/punctuation instructions regressed other tasks without fixing punctuation; instructions reverted |

Candidate 3 additionally had 20/20 first-pass core results at the selected context (median 6.76 seconds). It is development evidence, not substituted for the final rerun. These small pilots were used for development and are not independent estimates of general reliability.

Seven additional prompts were first evaluated after the main controller was frozen: Unicode, a 1,920,018-byte text file, appending repeated text at the tail, selecting the second occurrence, ordinary RTF, quoted RTF punctuation, and three distinct file edits. Three runs each at the selected 4,096 context yielded **18/21 eventual, 9/21 first-pass, 18/21 correct, 21/21 exact Undo**, median 7.33 seconds. Both RTF tasks passed all three runs, including the same `before` → `after!` replacement when quoted and specified as six characters. All three failures guessed Windows-style paths for the second-occurrence task. That evidence motivated the separate missing-file error fix; the final rerun of these prompts is additional validation, not an untouched held-out estimate.

The 8,192-context comparisons above precede only that final missing-leaf error classification and exhausted-error wording change. Their executed paths did not reach either changed error branch. The final selected-context evaluations and deterministic tests also cover the final error handling. Model-visible instructions and schemas match the measured main controller after reverting candidate 7.

The final additional-task rerun retained **18/21 eventual, 9/21 first-pass, 18/21 correct and 21/21 exact Undo**, median 7.34 seconds. The three incorrect-path attempts now stop with the specific missing-path error and retain unchanged files. This improves diagnosis, not their task-success rate.

Across **558 recorded evaluation attempts**, every started attempt has a finish record and every Undo check restored the original files exactly. For every response with runtime usage available, its actual prompt-token count matched the preflight count. These checks include all baseline and development failures; they do not convert incorrect edits into successes.

## Reproduction and evidence

```sh
# Default: 20 core attempts at each output limit with 8192 context.
python3 scripts/evaluate-file-mode.py --output /tmp/file-core.jsonl --phase validation
# Actual selected Qwen context.
python3 scripts/evaluate-file-mode.py --output /tmp/file-selected.jsonl --context 4096 --limits 1024 --runs 20
# Three repeats of each of 12 broader tasks, at each output limit.
python3 scripts/evaluate-file-mode.py --output /tmp/file-matrix.jsonl --matrix --runs 3
# Seven additional prompts, including Unicode and a file close to the 2 MiB limit.
python3 scripts/evaluate-file-mode.py --output /tmp/file-held-out.jsonl --held-out --context 4096 --limits 1024 --runs 3
# Export every completed attempt; an existing CSV path is rejected.
python3 scripts/evaluate-file-mode.py --summarize /tmp/file-core.jsonl /tmp/file-matrix.jsonl --csv /tmp/file-attempts.csv
```

Run from the repository with the installed selected model and compatible local runtime. No model is downloaded. Changing the selected model is a separate user action, not part of this evaluator. The recorded machine also had smaller text/vision models installed, but no stronger compatible text model for a controlled larger-model comparison.

The reviewed per-attempt CSV under `docs/evaluations/` is intentional research evidence, an exception to excluding generated build output. Raw bounded JSONL traces and Xcode logs are kept in the local evidence archive; they are not production logs. Deterministic tests and live evaluations remain separate so CI needs no model download or network inference.

See [all 558 attempt rows](evaluations/file-mode-attempts.csv), including each failure, latency, token counts, tool errors, discarded calls, recovery and restoration. Raw output filenames in the CSV correspond to the local JSONL/log archive. New evaluator runs additionally record the parent revision and source hashes in a `.metadata.json` file.

## Project verification

- `scripts/verify-xcode.sh build` and `scripts/verify-xcode.sh analyze` passed.
- The complete local suite ran **371 tests, eight optional skips**. After updating the UI mock to assert structured receipt status/path/read-back instead of the retired `File edited` string, all File Mode tests passed. Six assertions in four untouched native focus tests still failed: the two settings-focus tests in `AppCommandTests`, overlapping-capture focus restoration in `ScreenCaptureTests`, and repeated-screen-submission focus in `ScreenViewTests`.
- A separate detached worktree at unmodified `e12305a` reproduced **the same six assertions across 33 tests**. These local focus failures are reported separately; their assertions and production window code were not changed. The initial full run with the obsolete receipt assertion is also retained.
- All three original real Qwen smoke tests passed at the production context: text, protected Swift fallback and RTF, including exact contents and Undo. The optional cloud smoke was not enabled.
- Added deterministic coverage includes malformed/partial calls, dependent batches, repeated calls, idempotent append, bounded truncation recovery, unresolved edits, actual read-back, query/Unicode boundaries, RTF text/attributes, cancellation before and after a successful edit, failures after modified/created/deleted/moved operations, context accounting, permissions/consent and external changes during reads, recovery, rollback and Undo.
- The initial new RTF append test compared implicit paragraph defaults as if they were explicit attributes. Native unchanged RTF round-trip evidence identified the mismatch. The corrected test compares those implicit defaults against an unchanged native export while retaining direct checks of every supplied attribute, exact text and exact original-byte Undo. Its failing runs remain in the archive.
- Required GitHub CI results are available on [draft PR #4](https://github.com/leow427/AI-Spotlight/pull/4/checks). No merge is authorized.

## Limits and manual checks

**Keep the 1,024-token response limit for these small-model targeted edits.** The final core/broad runs used at most 124/135 generated tokens per response, and the broader rendered prompts peaked at 1,958. Increasing the output allowance to 2,048 or 4,096 did not improve their outcomes. At 4,096 context, reserving 2,048 output tokens leaves fewer than 1,984 prompt tokens after the margin; reserving 4,096 leaves no room for instructions. The tested 8,192 context accommodates all three output settings, but larger budgets reduce space for history and can allow unnecessary output to consume more time. Production limits and the selected model remain unchanged.

An inherently long creation/full replacement can need a larger response than a targeted patch. This evaluation does not establish reliable large full-file generation with the 3B model. Use precise excerpts, targeted edits or small creation requests; the physical 2 MiB file limit is not a promise that a model can generate 2 MiB in one response.

No finite sample establishes universal reliability. Most repeated tests use identical synthetic prompts, temperature zero and one machine/runtime. Three repeats per broad task have limited power to characterize rare failures. The final implementation is a bundle of changes; individual contributions are established only where an observed failure and regression/pilot directly support them.

Physical verification cannot detect every valid but wrong replacement or prove that every requested file was edited. Exact punctuation and multi-part instructions remain model limitations. Conservative patch guards can require a wider read/match or an explicit follow-up. Legitimate repeated identical appends must be expressed as one append containing the intended repetition; automatic retries intentionally cannot replay an identical successful mutation.

For manual checks, run the stably signed Xcode app with disposable attachments. Quote literal replacements and include their character count when punctuation matters; that wording passed three additional RTF attempts, but is not a guarantee. Use exact relative file paths and identify the surrounding text for repeated occurrences. Verify protected fallback and cloud disclosure, inspect Review against the original task (including punctuation, final newlines and all requested files), inspect RTF formatting in TextEdit, then Undo and compare originals. Stop between operations and confirm that earlier changes remain reviewable. Edit a changed file externally before Undo and confirm a conflict preserves the newer edit. Do not use the isolated unsigned verification app for interactive Screen testing.
