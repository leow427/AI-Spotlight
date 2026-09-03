# AI Spotlight Backend

This Cloudflare Worker exchanges a verified Sign in with Apple identity token for a short-lived AI Spotlight session. Authenticated app requests are then streamed to OpenAI or Anthropic with provider credentials held only as Worker secrets.

The service intentionally stores no prompts or responses. D1 stores only a one-way hash of the Apple subject, a UTC date, and that day's request count.

## Configure

1. Enable Sign in with Apple for the `com.leow427.AISpotlight` app identifier in the Apple Developer portal. Use a different bundle identifier only if `APPLE_CLIENT_ID` and the Xcode target are changed together.
2. Create a D1 database and replace the placeholder `database_id` in `wrangler.jsonc`.
3. Apply the quota migration with `npx wrangler@4 d1 migrations apply ai-spotlight-quota --remote`.
4. Add `SESSION_SECRET`, `OPENAI_API_KEY`, and `ANTHROPIC_API_KEY` with `npx wrangler@4 secret put NAME`. Generate `SESSION_SECRET` with at least 32 random characters.
5. Deploy with `npx wrangler@4 deploy`.
6. Set the Xcode build setting `AI_SPOTLIGHT_BACKEND_URL` to the deployed HTTPS origin. Do not include `/v1` or a trailing API path.

For local Worker development, copy `.dev.vars.example` to `.dev.vars` and replace every placeholder. `.dev.vars` is ignored by Git.

## Security boundaries

- Apple identity tokens are verified using Apple's published signing keys, issuer, app audience, expiration, and a per-attempt SHA-256 nonce.
- AI Spotlight session tokens use HS256, expire after 30 days by default, and are stored by the Mac app in Keychain.
- Provider keys never leave the Worker and should exist only as encrypted Worker secrets.
- The Worker reconstructs provider requests from an allowlisted schema. OpenAI storage is always disabled with `store: false`.
- D1 enforces a per-user daily request allowance before a provider request starts. The default is 100 and can be changed with `DAILY_REQUEST_LIMIT`.

Run the deterministic backend tests with `npm test` from this directory.
