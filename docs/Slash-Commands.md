# Slash commands

Recognized commands stay blue in the composer and work at the start, middle, or
end of a message. Search activates its existing tool control without removing
`/search` from the draft. Capture commands run when you submit. `/think` applies
only to the current answer, including File Mode requests.

| Command | Action |
| --- | --- |
| `/search` | Search the web |
| `/screen` | Capture all displays |
| `/snapshot` | Select a screen region |
| `/think` | Request more careful reasoning |

Type `/` anywhere after whitespace to see commands, icons, and descriptions.
Suggestions filter by the text before the caret, case-insensitively. Use ↑/↓ to
select, Tab or Return to complete, or click a suggestion. Escape dismisses the
list before hiding the panel. Shift-Return inserts a newline. Completion edits
only the command at the caret and supports Undo.

Commands must be separate tokens; punctuation may follow them. Quoted examples,
backtick code, URLs, paths, and unknown commands remain literal text. Repeated
commands activate once; `/snapshot` takes precedence over `/screen` if both occur.
Screen and Search remain incompatible with attached File Mode selections.

![Command suggestions with icons and a blue command in the draft](images/slash-commands.png)

The screenshot above is intentionally checked in as UI review documentation.
Build products and generated test renders remain outside the repository. The
rendering test also retains the screenshot as an XCTest attachment.

Verification uses `scripts/verify-xcode.sh build`, `test`, and `analyze`.
Regression coverage includes placement, boundaries, Unicode caret offsets,
completion, undo, keyboard navigation, multiline entry, capture cancellation,
focus restoration, and conversation scrolling.
