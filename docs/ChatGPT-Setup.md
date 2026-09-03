# ChatGPT subscription setup (checkpoint 5)

1. Install a current [Codex CLI](https://learn.chatgpt.com/docs/cli). This integration was developed against Codex 0.151.0. AI Spotlight checks Homebrew's standard locations, `~/.local/bin`, the Codex app bundle, and the launch environment's PATH. A custom absolute executable path can be supplied with `AI_SPOTLIGHT_CODEX_PATH` in the Xcode Run environment.
2. Build and run the shared `AI-Spotlight` scheme. No Apple development team, Sign in with Apple entitlement, or backend is needed.
3. Open Settings, choose **Sign in with ChatGPT**, and finish the browser login. On this Mac, macOS may ask permission for Codex to use Keychain.
4. Select **ChatGPT via Codex** and switch the main panel to **Cloud**. A successful login selects the ChatGPT provider automatically. The default is **GPT-5.6 Luna with High reasoning** (`gpt-5.6-luna`); you can choose a different model in Advanced Cloud Settings.

On the first launch after this default change, an empty ChatGPT model preference or the previous Sol selection is updated to Luna once. Other saved model choices and API-provider preferences are preserved. Later model selections, including Sol, are kept across restarts. Luna requests explicitly use High reasoning; other models retain Codex's default reasoning. Model discovery never silently replaces Luna with the first listed model. If your account does not offer Luna, select an available model explicitly.

This uses the ChatGPT plan's **Codex allowance**, with its plan-specific limits and available models. It does not turn a ChatGPT subscription into general OpenAI API credit, and it is not a wrapper around the ChatGPT website. The OpenAI and Anthropic API-key routes remain separately billed alternatives and are never automatic fallbacks.

## Authentication and data handling

- The app starts the official `codex app-server` over local standard input/output and uses its `account/login/start` browser OAuth flow. It does not read or copy tokens from the user's existing Codex installation.
- Codex owns token storage and refresh. The child runtime uses `~/Library/Application Support/AI Spotlight/Codex` as its own Codex home and `cli_auth_credentials_store="keyring"`, so credentials are stored in macOS Keychain rather than the repository or app preferences. Signing out affects only this app's isolated login.
- The runtime receives a minimal environment with no inherited OpenAI API keys. ChatGPT authentication and the OpenAI model provider are explicitly selected. A missing/expired ChatGPT login is an error, not a switch to API billing.
- Each response starts an ephemeral Codex thread with the selected chat's supplied conversation. Threads are unsubscribed after completion; Stop interrupts active generation. The app retains its existing five-chat local history. Ephemeral threads avoid additional Codex transcript files; OpenAI's service-side data policies still apply.
- Shell execution, browser/computer use, connectors, plugins, hooks, image tools, and agent delegation are disabled. Threads use read-only permissions and never approve external actions. This checkpoint adds text chat only, not web search or Auto routing.
- The retired Apple/backend prototype was removed. Previously stored API keys remain in Keychain and are used only when the corresponding API provider is selected.

## Verification

Automated tests mock the JSON-RPC boundary and cover account-type checks, OAuth completion/cancellation, model discovery, streamed text, failures, and Stop. CI does not require Codex installation, a ChatGPT login, or paid requests.

Manual check: sign in, send a short Cloud message, stop a second response, restart the app and verify the account is restored, then sign out and verify Cloud sending is disabled. Confirm Local mode still works offline. Browser authentication requires the user's participation.

Official references: [Codex authentication](https://learn.chatgpt.com/docs/auth), [App Server protocol](https://learn.chatgpt.com/docs/app-server), and [credential/configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
