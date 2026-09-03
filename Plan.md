# AI Spotlight Prototype and GitHub Bootstrap

## Project Summary

A lightweight, native macOS AI assistant designed around fast, keyboard-first access to local LLMs. The app runs models directly without requiring users to install tools such as Ollama or LM Studio, while still allowing optional online models and web search to be added later.

## Core Goals

- Native macOS app using Swift, AppKit, and SwiftUI.
- Global hotkey opens a small floating AI panel instantly.
- Keyboard-driven interaction with minimal mouse use.
- Local-first and fully usable offline after a local model is installed.
- Embedded `llama.cpp` first, with an adapter boundary for MLX later.
- No external AI runtime installation required.
- Automatic model downloading, storage, loading, and switching.
- Lightweight resource usage while inactive.
- Minimal/discreet macOS presence using appropriate native APIs.
- Best-effort screen-capture privacy where macOS APIs permit it.
- Modern macOS UI, including Liquid Glass on supported versions.
- Modular architecture for online AI providers and future web search.

## Design Principle

The app should feel like **Spotlight for AI**:

> Press a shortcut, ask something, get an immediate response, and dismiss it without interrupting the current workflow.

Prioritize speed, simplicity, native macOS behavior, local inference, and modularity over feature bloat.

## Prototype Scope

The first prototype includes Local, Cloud, and Auto modes only. Web search, Brave integration, citations, and the internet-mode icon are explicitly deferred. The app makes network requests only for explicit Cloud mode, Auto routes to Cloud, or a user-initiated local model download during setup.

## Implementation Steps

1. **Create the native app shell**

   - Create a SwiftUI macOS app with an AppKit application delegate.
   - Set `LSUIElement` and accessory activation so the app stays out of the Dock.
   - Set the visible app name to `AI Spotlight` and the executable name to `PrimaryAgent`; verify Activity Monitor displays the latter.
   - Add a menu-bar item with Open, New Chat, Privacy Hide, Settings, and Quit.
   - Check the UI style guidilines in the UI-Style.md file in the project folder.

2. **Build the keyboard-first panel**

   - Create a custom floating, nonactivating `NSPanel` that hosts SwiftUI.
   - Open or hide it with `⌥Space`; use `Escape` to hide, `⌘N` for a new chat, `⌘K` for the mode/model palette, and `⌘.` to stop streaming.
   - Use `⌘,` to open Settings. Provide a Help page above Developer Tools listing app shortcuts and standard text-editing shortcuts. Present Settings through an owned AppKit window so it also opens from the floating panel's menus.
   - Opening Settings preserves the chat panel's visibility and current session. Keep Settings at the panel's floating window level so both windows remain accessible.
   - Center the panel on the active display at 760×520 points; remember only its size.
   - Use a restrained Liquid Glass treatment: one outer glass container, glass composer, and compact mode controls.

3. **Embed local inference**

   - Add a `LocalModelEngine` protocol and integrate `llama.cpp` directly into the app through a small Swift/C++ bridge; do not require Ollama, LM Studio, or another runtime.
   - Keep the engine boundary compatible with a future MLX implementation without adding MLX to the first build.
   - Stream tokens into a selectable Markdown message view.
   - Load the model lazily on the first Local request and unload it when the app is inactive for the chosen idle policy, keeping inactive resource use low.
   - Treat model download as an explicit first-run setup action. Once installed, Local mode must work without network access.

4. **Add model management and local persistence**

   - Define a small model manifest with model ID, display name, download URL, expected size, license, and checksum.
   - Store models under Application Support, verify checksums, show download progress, and support loading/switching among installed models.
   - Define `ChatSession`, `ChatMessage`, `ChatMode`, `Route`, and `ChatProvider`.
   - Save chats to one atomic JSON file in Application Support.
   - Retain five chats sorted by last activity; creating a sixth removes the least recently used chat.
   - Provide recent-chat cycling with `⌃Tab` and a small recent-chat picker. Do not add sync, files, voice, images, or a database.

5. **Add Cloud mode**

   - Add direct `URLSession` streaming clients for OpenAI Responses and Anthropic Messages; do not add third-party cloud SDKs.
   - Store API keys only in Keychain. OpenAI API access requires separate API billing from a ChatGPT subscription.
   - Fetch and cache available models from each configured provider for 24 hours; allow a manual model ID if discovery fails.
   - Add Advanced Settings for API keys, connection tests, preferred cloud provider, and preferred cloud model.
   - Send cloud requests statelessly and disable OpenAI response storage with `store: false`.
   - Offer “Sign in with ChatGPT” through the locally installed Codex App Server, using the user's ChatGPT plan's Codex allowance. Keep this route separate from API billing and retain Keychain-backed API keys as an explicitly selected fallback.
   - Default the ChatGPT route to GPT-5.6 Luna with High reasoning while retaining manual model selection.
   - Keep Codex authentication in an isolated Application Support home with macOS Keychain credential storage. Use ephemeral, read-only, text-only requests; do not inherit the user's Codex plugins, hooks, or API credentials. No Apple development team or custom backend is required. See `docs/ChatGPT-Setup.md`.

6. **Add predictable Auto mode**

   - Route ordinary writing, summaries, and conversation locally.
   - Route coding, complex reasoning, or prompts beyond local context to the preferred cloud model.
   - Detect reasoning using whole-word actions and combined depth, constraint, and prompt-length signals; favor Cloud for demanding requests without another model call. Length alone does not escalate ordinary summaries.
   - Restore the saved Cloud connection when Auto first appears, as well as when switching modes.
   - Display the selected route and model before streaming begins.
   - If Cloud is not configured, remain Local and show a concise limitation notice. Explicit Local mode never makes a network request.

7. **Add privacy behavior**

   - Configure the panel to be invisible to other screen sharing apps using the old utility NSWindow.sharingType = .none / NSWindowSharingNone.(i know this is no longer full proof)
   -You may research if there is a better alternative for modern macOS, and if you find one, implement it. 

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

protocol LocalModelEngine {
    func install(_ model: LocalModel) async throws
    func stream(_ request: LocalModelRequest) -> AsyncThrowingStream<String, Error>
    func unload() async
}
```

`WebSearchProvider`, web mode, citations, Brave credentials, and internet UI are deferred.

## Test Plan

- Unit-test mode routing, context trimming, JSON recovery, five-chat eviction, model-manifest validation, checksum failures, and SSE event parsing.
- Mock `LocalModelEngine` to test model installation, loading, switching, unloading, cancellation, and partial-stream failures without requiring a large model in CI.
- Mock cloud networking to test missing credentials, offline state, authentication failures, rate limits, cancellation, and partial-stream failures.
- Verify Local mode creates zero external requests after model setup; model downloads occur only from the explicit setup flow.
- Manually verify Dock absence, menu-bar recovery, global shortcut behavior, Activity Monitor name, panel behavior across Spaces/full-screen apps, and the instant privacy-hide path.

## Assumptions

- Personal Xcode-run prototype on Apple silicon, macOS 26.6+.
- The first embedded runtime is `llama.cpp`; MLX remains a future engine adapter.
- Text and Markdown chat only.
- One transparent app process named `PrimaryAgent`; no disguised system process or background helper.
- GitHub repository: private `leow427/AI-Spotlight`, default branch `main`.
