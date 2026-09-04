# Screen panel regression verification

Verified on macOS with the signed Xcode Debug product on 2026-09-05.
Baseline: `b085945` on `feat/screen-capture`.

## Reproduction and cause

Computer accessibility and screenshot inspection recorded the complete Auto
panel before capture, after restoration, immediately after submission, and after
asynchronous work settled. An OCR request completed normally. A subsequent
capture required vision; with screenshot uploads disabled and no local vision
model, submission added the expected inline routing explanation. The controls
then disappeared visually, although accessibility still exposed the history,
attachment, prompt, and explanation.

LLDB inspection of the native view hierarchy established a layout failure:

- The window and root hosting view remained **752 × 462**.
- The navigation split expanded to **752 × 1343.5**, with a vertical offset of
  **−440.5** inside the root.
- The prompt field was positioned near **y = 1288.5** in the split's detail
  column, outside the visible panel.
- The process was alive and its main thread was in the event loop. The blocked
  route had correctly kept the draft and attachment instead of starting a
  provider request.

The native split view's unconstrained column measurement allowed vertically
fixed, wrapped composer text to become its minimum height. The resulting split
was centered beyond the panel's bounds. The error was unreachable visually,
which made the intentional routing rejection appear to be a stalled send.

A separate focus defect was confirmed by typing after successful completion:
the first-token acceptance callback requested focus while the text field was
still disabled. Typing was ignored until the field was clicked.

## Fix

A `GeometryReader` at the navigation detail boundary keeps its intrinsic
measurement independent of the transcript, attachment, and wrapped notices.
The detail continues to lay out within the space assigned by the panel. Focus
is released while a request is busy and restored when that request finishes.
No delayed redraw or window-opacity workaround is added. Capture still uses
`orderOut` and normal restoration.

## Conditions checked

| Condition | Evidence and result |
| --- | --- |
| Two captures versus two submissions | The full-panel regression retakes before sending and checks request counts. The original code also fails on a first blocked request in a fresh chat; a second-send counter is not required. |
| Plus → Screen versus `/screen` | Both were used in signed manual runs. The full-panel test sends through the actual native composer, including slash-command capture and automatic submission. |
| OCR versus vision | Repeated OCR requests completed. A wrapped blocked-vision explanation reproduced the overflow. Successful image routing and serialization remain covered by deterministic provider/local-vision tests; live cloud image upload was not enabled. |
| Same versus fresh conversation | Manual runs completed seven OCR requests across three chats, including repeated requests in each. The regression checks persisted user prompts and stable conversation identity. |
| Remove or retake | Manual retake preserved the draft and recovered from a blocked route. Removal cleared the attachment and error. Tests verify replacement IDs and discard OCR that arrives after removal. |
| First response still active | The visual failure was reproduced after the first response completed. UI capture/submission controls are disabled while busy. A controlled-stream regression queues old events, stops that request, starts its replacement, and verifies the old task cannot clear the new draft or finish the new request. |
| Cancellation and overlapping capture | A suspended capture test rejects a second begin attempt, confirms one begin/end pair, cancels the first operation, and verifies panel visibility and key focus. A duplicate end leaves the restored panel visible. |

The system picker was not claimed as a successful injected-Escape test.
Cancellation is verified deterministically. Screen Recording permissions and
cloud screenshot permission were not changed. Only the signed Xcode product
was used for interactive capture; isolated verification products were used only
by the verification helper.

## Regression evidence

`testRepeatedScreenSubmissionsKeepFullPanelInsideWindow` checks native split,
sidebar and composer bounds, rendered detail content, focus, request counts,
attachment clearing, capture/generation state, and conversation persistence.
The final test failed against the original `AppShellView`, including a
**1406.5-point** split on the first blocked request and a **1340-point** split on
a later wrapped error. It passed with the fix restored. The explicit completion
focus assertion likewise failed before the focus change and passed afterward.

The native glass sidebar uses a separate rendering surface that bitmap caching
does not reliably include. The automated test therefore checks its native view,
scroll content, collapse state and bounds; manual Computer screenshots and
accessibility inspection verify the visible sidebar. No screenshot-only blank
surface is treated as proof that state was deleted.

`ViewBridge ... NSViewBridgeErrorCanceled` also appeared during successful
capture/response cycles. No evidence linked that message to the overflow; the
measured view geometry and failing regression identify the causal transition.

## Final validation

- Screen, OCR, routing, providers, local vision and panel tests: **45 passed**.
- `scripts/verify-xcode.sh build`: passed.
- `scripts/verify-xcode.sh test`: **222 passed**, no failures.
- `scripts/verify-xcode.sh analyze`: passed.

The signed app was stopped after visual debugging and relaunched from Xcode,
restoring its normal window-sharing privacy setting.
