# Repository Guidelines

## Project Structure & Architecture

AI Spotlight is a native macOS app written in Swift 6. The Xcode project is
`AI-Spotlight.xcodeproj`; its shared `AI-Spotlight` scheme builds the app and
the `AI SpotlightTests` XCTest target. The app currently targets macOS 26.0.

- `AI-Spotlight/App/` contains application lifecycle, menu-bar/panel, shortcuts,
  settings, and top-level SwiftUI composition.
- `AI-Spotlight/Chat/` contains chat state, presentation, Markdown, streaming,
  and request lifecycle code.
- `AI-Spotlight/Cloud/`, `LocalInference/`, `Search/`, `Screen/`, and `Files/`
  implement the corresponding product capabilities. Keep feature-specific code
  with its capability; share only genuinely cross-cutting types.
- `AI-Spotlight/Resources/` contains `Info.plist`, asset catalogs, and bundled
  notices. Add app resources here and update the Xcode project when needed.
- `AI-SpotlightTests/` contains the XCTest suite. Name tests after the behavior
  or subsystem they cover and use existing test support before adding helpers.
- `Packages/LlamaBridge/` is a local Swift package that wraps the pinned
  llama.cpp XCFramework. Its C++ bridge and public header are deliberately
  isolated from the Swift app target.
- `scripts/` contains verification and file-mode evaluation helpers.
- `docs/` records feature design, verification, and operational notes;
  `UI-Style.md` is the visual-design reference.

Do not commit `DerivedData`, `xcuserdata`, `.DS_Store`, credentials, generated
artifacts, or local model/runtime caches. Preserve the existing `.gitignore`
rules when adding tools or local state.

## Build, Test, and Development Commands

Use the shared scheme and the verification helper for local checks:

```sh
scripts/verify-xcode.sh build
scripts/verify-xcode.sh test
scripts/verify-xcode.sh analyze
```

The helper uses `/tmp/AI-Spotlight-Verification`, disables signing, avoids
Launch Services registration, and unregisters any temporary test host before
and after each action. Pass normal `xcodebuild` options after the action; for
example, `scripts/verify-xcode.sh test -only-testing:AI\ SpotlightTests/ScreenViewTests`.

Do not use the helper's unsigned product for interactive Screen Recording or
accessibility testing: its changing code identity can invalidate macOS consent.
Run the interactive app from Xcode using a stable Apple Development signing
identity and selected team instead.

GitHub Actions currently runs `xcodebuild test` on `macos-26` for pushes to
`main` and pull requests. It does not run the helper's separate `build` or
`analyze` actions, so run those locally when they are relevant to the change.

## Implementation and Test Expectations

- Follow the existing Swift style and local patterns; use clear, feature-based
  names and comments only for non-obvious intent.
- Keep SwiftUI UI changes consistent with `UI-Style.md`, and update related
  screenshots or documentation when the visible behavior materially changes.
- Keep native llama.cpp integration within `Packages/LlamaBridge`; do not add
  C++ or binary-framework details to app feature code without a clear boundary.
- Start with the smallest relevant XCTest target while developing. Before
  publishing, run the affected tests and the appropriate build/test/analyze
  checks above.
- Do not delete, disable, or weaken tests to make a check pass. Add regression
  coverage for fixes where practical, keeping tests deterministic and offline.
- For permission-sensitive Screen, Files, selection, or cloud behavior, retain
  the existing privacy and fallback behavior and exercise failure paths.

## Definition of Done

A change is complete when the requested behavior is implemented, its relevant
tests pass, the final diff contains no unrelated changes, and any limitation is
explicitly reported. For a completed feature, also run the applicable local
verification commands, publish the focused commit to `main` when repository
rules permit it, and confirm the required GitHub Actions check passes on that
commit. Do not claim completion while a change-caused required check is failing.

## Commit, Pull Request, and Repository Safety

- The owner has authorized publishing completed work to `main`. Work may use a
  feature branch and pull request when repository rules require it; do not
  bypass required review or branch protection.
- Keep commits focused and imperative, for example `Add selection revision card`.
  Inspect `git status` and the final diff before committing so untracked local
  design assets or generated output are not included accidentally.
- In pull requests, explain the behavior change, implementation decisions,
  verification performed, and any known limitation. Include screenshots for
  visible UI changes and link relevant issues where applicable.
- After publishing, verify the commit is on `origin/main`, review the required
  CI result, and leave the checkout on the updated `main` branch.
- Never commit secrets, certificates, tokens, or `.env` contents. Do not
  force-push, rewrite history, modify repository protections, or change GitHub
  secrets without explicit authorization.
- Avoid unrelated dependency upgrades. Before adding a dependency, assess its
  maintenance, license, security, and app bundle/runtime impact.
