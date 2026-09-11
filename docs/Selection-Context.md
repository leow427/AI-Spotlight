# Selection Context

![Selected text context card](images/selection-context-card.png)

Highlight text in another app and tap **Option twice** to start a new temporary
Enigma chat bar close to the pointer. **Shift–Option–Space** is the conventional backup.
Option–Space still toggles the existing panel. Help contains all shortcuts,
an Accessibility status and Settings button, a choice of Option/Command/Shift for the
solo double tap, an enable switch, and Fast/Normal/Relaxed timing.

When Accessibility is missing, the composer asks to enable Selection Context and
provides **Open Accessibility Settings…**. This requests system trust and opens the
Accessibility page directly even if macOS suppresses a repeated popup. Enable
**Enigma** (the current macOS display name for Enigma). Permission status and shortcut
monitors refresh when switching apps, so granting access does not require a restart.

The source is captured before the panel becomes key. The small “Selected text ·
App” card stays above the composer across follow-ups. Removing it revokes the
replacement capability and excludes the attachment from subsequent requests.
Earlier answers may naturally mention material already discussed. Questions remain
ordinary conversation messages; there are no rewrite/explain/verify workflows.

## Architecture and privacy

- `ConversationContext` is a provider-neutral, session-only attachment with identity,
  kind, source attribution and a text representation. Screenshot, file, webpage and
  image kinds leave room for future payloads without changing conversation routing.
  Existing screenshot/file flows can coexist with selected text.
- `ChatContextPreparer` expands attachments in request copies before token counting.
  JSON-encoded source material is explicitly described as untrusted context, never
  instructions. Drafts and displayed messages remain unchanged. Local, cloud,
  multimodal, Auto, and File Mode paths receive the same text representation.
- Web Search uses the selected model to derive a bounded query from the question
  and attachment, then follows the existing evidence preparation path. Relevant
  selection details can reach Brave when search is enabled (including existing
  automatic-search preferences); the composer explains this. Capture itself makes
  no network request. Local mode never uses a cloud model to derive a query.
- One temporary session lives in memory. It does not write the chat archive or count
  against the five saved conversations. It is discarded on a new invocation or on
  switching to another chat. Hiding/reopening the panel retains it until then or
  app exit. Invoking a new chat stops an in-progress response using the existing
  request-cancellation protections; saved message contents remain intact.
- The shortcut observes event metadata only. Accessibility text reads happen only
  during deliberate capture or explicit replacement. Secure Event Input, secure
  roles/subroles and protected ancestors block both Accessibility and copy fallback.
  Unknown/inaccessible focus or ancestry fails closed. Text is not logged.

## Capture and replacement

Capture first reads nonempty AXSelectedText, then AXStringForRange or the selected slice of AXValue. A bounded copy fallback
handles editors with incomplete selection text APIs. A known empty native AX range never
copies (some editors otherwise copy the current line). Browser canvas editors such
as Google Docs can expose an empty hidden input while document text is selected,
so supported browsers can fall back to copy when AX provides no selected text. Known copy-line editors
also require a range. Selected text is limited to 256 KB; model-specific input
budgets can be smaller and reject the request while preserving the draft.

Clipboard fallback eagerly saves every readable representation of every item,
including rich text, images and file data. If a representation cannot be preserved
or the clipboard changes during the snapshot, fallback is declined. A private
marker distinguishes unchanged clipboard contents from a copy result. Restoration
uses change-count ownership, so a subsequent user clipboard write wins. Keyboard,
mouse, scroll and focus changes abort capture. Synthetic events are
addressed to the source process and marked to distinguish them from user input.

## Revision cards and automatic replacement

When the user asks to revise the selected text, the model gives a short
acknowledgement followed by a separate **Revised text** card. **Edit** turns the
card into an editable draft; **Done** returns to its preview. **Replace text**
pastes that draft with one click. Follow-up requests receive the latest proposed
revision, including manual changes. Each response retains its own draft in the
temporary conversation. Normal questions, explanations, and verification requests
remain ordinary conversation responses.

**Settings → Selection Context → Automatically replace selected text** is off by
default. When enabled before a request begins, a successfully completed revision
is pasted directly, with no revision card or confirmation click. It never applies
ordinary responses, malformed/incomplete revisions, failed or cancelled requests,
or a response whose context has been removed. Turning the setting on does not
apply responses already in progress; turning it off cancels pending automatic
work and makes unsent drafts available for manual review.

The provider-neutral prompt asks the model to choose whether a revision is
appropriate, then emit acknowledgement plus one explicit JSON revision payload.
The UI hides that payload while streaming. Only a valid completed payload can
be applied; formatting failures show a notice instead. No keyword-based rewrite
workflow or separate intent-classification model is used. Local, cloud, vision,
Auto and File Mode share this request formatting; web-search query refinement
receives the latest draft as source material without the editing-output protocol.
Revision state and formatting metadata are session-only. If a completed response
omits the revision block (including a list of options), one additional request to
the same model interprets the user's intent and prepares a single revision as JSON.
It includes the original selection, conversation and latest manually edited draft.
An explicit `answer` result leaves ordinary conversation unchanged. Invalid recovery
shows a visible notice; it never treats arbitrary prose as replacement text or
retries a paste. This recovery can add latency and still depends on model compliance.

Capture still occurs only on double-Option (or the configured backup). Bounded
readiness retries allow an editor time to expose a fresh AX selection. Cmd+C may
retry once only if the clipboard marker remains untouched and the same safe source
is still focused. These retries end on cancellation, user input or focus changes;
there is no background selection monitoring.

## Applying a revision

Capture remembers the source application (including its PID) and the context ID.
Replacement activates that same running application and sends one Cmd+V directly
to its PID using CGEvent. The app's normal paste command acts on its **current**
selection or insertion point. There is no original AX element, range, text,
document/URL, continuity, or expiry requirement. Moving the selection or opening
another document in the same source app does not revoke replacement.

The floating panel releases keyboard focus before the
source app is activated. Accessibility permission, a still-running source,
successful activation, Secure Event Input, and the current field's password or
protected status are checked. Unknown password status fails closed. No AX text
write, re-copy, re-selection, or post-paste readback is performed. All clipboard
items and representations are preserved; temporary content is tagged transient
and auto-generated. The pasteboard stays available for 600 ms before restoration.
A newer clipboard write wins. The same Enigma panel then returns. The notice says
"Replacement sent" because dispatch does not prove that an external editor
accepted the paste. A dispatched attempt consumes the replacement action and is
never retried automatically.

## Verification and compatibility limits

Automated tests cover remembered-PID delivery, replacing the current selection in
an NSTextView fixture, insertion into a different document with no selection range,
complete clipboard restoration, transient markers, competing clipboard writes,
failed activation, permission revocation, password/secure-input blocking, event
creation failure, and one-shot dispatch without editor acknowledgement. Existing
capture, shortcut, placement, temporary-chat, context-routing, and panel tests
remain in place. Original-selection guard tests were replaced to reflect the
explicitly requested September 9 change in behavior, not to hide failures.

The September 8 signed Safari editor test verified the previous paste route.
The process-targeted paste route has automated coverage; live Google Docs,
Gmail, and Word verification remains pending. Do not infer universal compatibility
from unit tests. Safari was left alone at the user's request. Use the stably signed
Xcode build for future interactive checks, never the unsigned verification host.
The September 10 revision-card changes add coverage for acknowledgement/payload
separation, local/manual follow-ups, cloud automatic application, draft-aware search,
setting persistence, mid-response setting changes, cancelled/failed/incomplete
responses, context removal, bounded readiness retries, and a native card render.
A paste still consumes its source target to avoid repeating an ambiguous mutation.
Refine drafts before applying them; to replace again after a successful paste,
select the desired source text and invoke a fresh temporary chat.

![Revision card](images/selection-revision-card.png)

Some editors may delay or reject paste; the clipboard has no universal consumption
acknowledgement, so unusually delayed apps may not receive the temporary text.

API references: [Apple AXSelectedText](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute)
and [Apple event monitoring](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/EventOverview/MonitoringEvents/MonitoringEvents.html).

The September 10 recovery fix was exercised against the installed Google Gemma 4
12B model in Auto mode with synthetic text: “make the text sound more professional”
produced a revision card. The real model also converted a deliberately unformatted
options response into a valid single revision. Neither check pasted into a source
application. Run this opt-in check with `TEST_RUNNER_ENIGMA_SELECTION_MODEL_SMOKE=1`
and `scripts/verify-xcode.sh test '-only-testing:EnigmaTests/SelectionContextTests/testInstalledGemmaAutoProducesRevisionCard'`
when that model is selected locally.


## Permission and capture recovery

Settings → General now starts with Accessibility and Screen Recording status and
prominent buttons opening the exact macOS privacy panes. Selection Context also
shows its required Accessibility access above editing preferences. Setup includes
these controls, and chat shows an Accessibility action when access is missing.
If an old development/demo copy is listed, replace it with the current Enigma app
in System Settings and reopen Enigma; consent belongs to the signed app identity.

Capture now enables the focused app's optional `AXManualAccessibility` interface
before bounded readiness retries (up to ten reads). This follows the
[Electron accessibility guidance](https://www.electronjs.org/docs/latest/tutorial/accessibility).
Empty AX selected-text results fall through to range-based text; unsupported
parameterized range reads fall back to the selected UTF-16 slice of AXValue.
Valid selected text is retained even when a browser omits a selection range.
Secure-field checks, focus-change cancellation, copy-line safeguards, and
clipboard ownership protections remain in place. A failed capture now explains
how to retry or manually paste, instead of silently opening an empty chat.

Automated coverage exercises empty-text fallback, UTF-16 boundaries, readiness
retries, and existing secure selection / clipboard behavior. Interactive capture
must be checked with the stable development-signed app, not the unsigned test host.

## Compact composer and upward expansion

Selection Context now starts with just the composer. The quote button opens the
attached selection, removal control, temporary-chat status, and existing routing
and permission notices in a popover. A warning icon indicates missing capture
access or a capture notice. Mode/model selection and slash suggestions also use
popovers so they remain usable outside the short bar. Multi-line drafts resize the
bar to the measured composer height.

The first accepted prompt grows the same panel upward from the bar with a brief
spring overshoot. The composer stays at the bottom; the conversation and context
appear above it. Placement keeps the window within the current display, shifting
down when there is too little room above. Reduce Motion expands immediately.
Empty or rejected submissions do not expand, and request failures expose details.
Follow-up sends retain the expanded panel. A fresh selection returns to the bar;
New Chat restores the previous ordinary window size. Hiding during the animation
settles its final frame so reopening cannot leave a partially expanded panel.

The interaction was informed by [Thuki’s input-to-conversation flow](https://github.com/quiet-node/thuki/blob/main/src/App.tsx), implemented here with native AppKit
window geometry and the existing SwiftUI composer. No dependency was added.

Regression coverage checks first-send acceptance, context delivery, repeat
invocation, display-edge geometry, Reduce Motion, interruption by hiding, normal
window restoration, and native renders of both states. These use synthetic text
and the unsigned test host; live capture and animation feel still require review
in the stable development-signed app.

![Compact selection composer](images/selection-compact-composer.png)

![Expanded selection conversation](images/selection-expanded-conversation.png)
