# AI Spotlight Prototype and GitHub Bootstrap

## Summary

Build a local-first, keyboard-driven macOS 26+ Swift app at `/Users/leo/Documents/AI-Spotlight`.

The first prototype includes Local, Cloud, and Auto modes only. Web search, Brave integration, citations, and the internet-mode icon are explicitly deferred. The app will make network requests only when the user selects Cloud or Auto routes to Cloud.

## Implementation Steps

1. **Create the native app shell**

   - Create a SwiftUI macOS app with an AppKit application delegate.
   - Set `LSUIElement` and accessory activation so the app stays out of the Dock.
   - Set the visible app name to `AI Spotlight` and the executable name to `Glass Chat Agent`; verify Activity Monitor displays the latter.
   - Add a menu-bar item with Open, New Chat, Privacy Hide, Settings, and Quit.

2. **Build the keyboard-first panel**

   - Create a custom floating, nonactivating `NSPanel` that hosts SwiftUI.
   - Open or hide it with `⌥Space`; use `Escape` to hide, `⌘N` for a new chat, `⌘K` for the mode/model palette, and `⌘.` to stop streaming.
   - Center the panel on the active display at 760×520 points; remember only its size.
   - Use a restrained Liquid Glass treatment: one outer glass container, glass composer, and compact mode controls.

3. **Implement local chat first**

   - Add a `FoundationModelProvider` around Apple’s on-device Foundation Models framework.
   - Require Apple Intelligence availability; show a setup/error state instead of silently using cloud when unavailable.
   - Stream responses into a selectable Markdown message view.
   - Keep one in-memory Foundation Models session per open chat and trim old context before reaching the on-device model’s context limit.

4. **Add lightweight local persistence**

   - Define `ChatSession`, `ChatMessage`, `ChatMode`, `Route`, and `ChatProvider`.
   - Save chats to one atomic JSON file in Application Support.
   - Retain five chats sorted by last activity; creating a sixth removes the least recently used chat.
   - Provide recent-chat cycling with `⌃Tab` and a small recent-chat picker. Do not add sync, files, voice, images, or a database.

5. **Add Cloud mode**

   - Add direct `URLSession` streaming clients for OpenAI Responses and Anthropic Messages; do not add third-party SDKs.
   - Store API keys only in Keychain. OpenAI API access requires separate API billing from a ChatGPT subscription.
   - Fetch and cache available models from each configured provider for 24 hours; allow a manual model ID if discovery fails.
   - Add Advanced Settings for API keys, connection tests, preferred cloud provider, and preferred cloud model.
   - Send cloud requests statelessly and disable OpenAI response storage with `store: false`.

6. **Add predictable Auto mode**

   - Route ordinary writing, summaries, and conversation locally.
   - Route coding, complex reasoning, or prompts beyond local context to the preferred cloud model.
   - Display the selected route and model before streaming begins.
   - If Cloud is not configured, remain Local and show a concise limitation notice. Explicit Local mode never makes a network request.

7. **Add honest privacy behavior**

   - Configure the panel as a standard AppKit utility panel; do not use private APIs or system shielding window levels.
   - Offer `sharingType = .none` as an experimental best-effort setting, clearly labelled as unreliable.
   - Do not promise screen-share exclusion. The dependable privacy action is instant dismissal through `Escape`, `⌥Space`, or the menu-bar Privacy Hide command.

## Interfaces

```swift
enum ChatMode { case auto, local, cloud }

struct Route {
    let mode: ChatMode
    let providerID: String
    let modelID: String
    let usesNetwork: Bool
}

protocol ChatProvider {
    func stream(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}
```

`WebSearchProvider`, web mode, citations, Brave credentials, and internet UI are deferred.

## Test Plan

- Unit-test mode routing, context trimming, JSON recovery, five-chat eviction, Keychain failures, and SSE event parsing.
- Mock cloud networking to test missing credentials, offline state, authentication failures, rate limits, cancellation, and partial-stream failures.
- Verify Local mode creates zero external requests.
- Manually verify Dock absence, menu-bar recovery, global shortcut behavior, Activity Monitor name, panel behavior across Spaces/full-screen apps, and the instant privacy-hide path.

## Assumptions

- Personal Xcode-run prototype on Apple silicon, macOS 26.6+.
- Text and Markdown chat only.
- One transparent app process named `Glass Chat Agent`; no disguised system process or background helper.
- GitHub repository: private `leow427/AI-Spotlight`, default branch `main`.
