import assert from "node:assert/strict";
import { webcrypto } from "node:crypto";
import test from "node:test";
import {
  consumeQuota,
  handleRequest,
  signSessionToken,
  verifySessionToken,
} from "../src/worker.mjs";

if (!globalThis.crypto) globalThis.crypto = webcrypto;

const sessionSecret = "test-session-secret-that-is-longer-than-thirty-two-characters";

test("Sign in with Apple verifies the nonce and returns a scoped session", async () => {
  const now = 2_000_000_000;
  const nonce = "one-time-nonce-123";
  const apple = await makeAppleIdentityToken({ nonce, now });
  const request = new Request("https://api.example/v1/auth/apple", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identity_token: apple.token, nonce }),
  });
  const response = await handleRequest(request, {
    APPLE_CLIENT_ID: "com.leow427.AISpotlight",
    SESSION_SECRET: sessionSecret,
  }, {
    nowSeconds: () => now,
    fetchImpl: async () => Response.json({ keys: [apple.publicJWK] }),
  });

  assert.equal(response.status, 200);
  const payload = await response.json();
  assert.equal(payload.token_type, "Bearer");
  assert.equal(payload.expires_in, 30 * 24 * 60 * 60);
  const claims = await verifySessionToken(payload.access_token, sessionSecret, now);
  assert.equal(claims.sub, "apple-user-123");
  assert.equal(claims.aud, "ai-spotlight-macos");
});

test("Sign in with Apple rejects a mismatched nonce", async () => {
  const now = 2_000_000_000;
  const apple = await makeAppleIdentityToken({ nonce: "original-nonce-123", now });
  const response = await handleRequest(new Request("https://api.example/v1/auth/apple", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identity_token: apple.token, nonce: "replayed-nonce-123" }),
  }), {
    APPLE_CLIENT_ID: "com.leow427.AISpotlight",
    SESSION_SECRET: sessionSecret,
  }, {
    nowSeconds: () => now,
    fetchImpl: async () => Response.json({ keys: [apple.publicJWK] }),
  });

  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, "invalid_apple_credential");
});

test("Authenticated OpenAI requests are constrained and streamed through", async () => {
  const now = 2_000_000_000;
  const session = await signSessionToken("apple-user-123", sessionSecret, now, 300);
  let upstreamRequest;
  const response = await handleRequest(new Request("https://api.example/v1/providers/openai/responses", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "gpt-test",
      input: [{ role: "user", content: "Hello" }],
      stream: false,
      store: true,
      previous_response_id: "must-not-be-forwarded",
    }),
  }), {
    SESSION_SECRET: sessionSecret,
    OPENAI_API_KEY: "provider-secret",
  }, {
    nowSeconds: () => now,
    consumeQuotaImpl: async () => true,
    fetchImpl: async (request) => {
      upstreamRequest = request;
      return new Response("data: {\"type\":\"response.completed\"}\n\n", {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    },
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "text/event-stream");
  assert.equal(upstreamRequest.url, "https://api.openai.com/v1/responses");
  assert.equal(upstreamRequest.headers.get("authorization"), "Bearer provider-secret");
  const upstreamBody = await upstreamRequest.json();
  assert.deepEqual(upstreamBody, {
    model: "gpt-test",
    input: [{ role: "user", content: "Hello" }],
    stream: true,
    store: false,
  });
});

test("Authenticated Anthropic requests receive only server-side provider credentials", async () => {
  const now = 2_000_000_000;
  const session = await signSessionToken("apple-user-123", sessionSecret, now, 300);
  let upstreamRequest;
  const response = await handleRequest(new Request("https://api.example/v1/providers/anthropic/messages", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-test",
      messages: [{ role: "user", content: "Hello" }],
      max_tokens: 4_096,
      stream: false,
    }),
  }), {
    SESSION_SECRET: sessionSecret,
    ANTHROPIC_API_KEY: "anthropic-provider-secret",
  }, {
    nowSeconds: () => now,
    consumeQuotaImpl: async () => true,
    fetchImpl: async (request) => {
      upstreamRequest = request;
      return new Response("data: {\"type\":\"message_stop\"}\n\n", {
        status: 200,
        headers: { "Content-Type": "text/event-stream" },
      });
    },
  });

  assert.equal(response.status, 200);
  assert.equal(upstreamRequest.url, "https://api.anthropic.com/v1/messages");
  assert.equal(upstreamRequest.headers.get("x-api-key"), "anthropic-provider-secret");
  assert.equal(upstreamRequest.headers.get("authorization"), null);
  assert.equal(upstreamRequest.headers.get("anthropic-version"), "2023-06-01");
  assert.deepEqual(await upstreamRequest.json(), {
    model: "claude-test",
    messages: [{ role: "user", content: "Hello" }],
    max_tokens: 4_096,
    stream: true,
  });
});

test("Provider routes require a valid AI Spotlight session", async () => {
  const response = await handleRequest(
    new Request("https://api.example/v1/providers/anthropic/models"),
    { SESSION_SECRET: sessionSecret, ANTHROPIC_API_KEY: "provider-secret" }
  );

  assert.equal(response.status, 401);
  assert.equal((await response.json()).error.code, "missing_session");
});

test("The daily allowance stops a request before provider access", async () => {
  const now = 2_000_000_000;
  const session = await signSessionToken("apple-user-123", sessionSecret, now, 300);
  let providerWasCalled = false;
  const response = await handleRequest(new Request("https://api.example/v1/providers/anthropic/messages", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${session}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-test",
      messages: [{ role: "user", content: "Hello" }],
    }),
  }), {
    SESSION_SECRET: sessionSecret,
    ANTHROPIC_API_KEY: "provider-secret",
  }, {
    nowSeconds: () => now,
    consumeQuotaImpl: async () => false,
    fetchImpl: async () => {
      providerWasCalled = true;
      return new Response();
    },
  });

  assert.equal(response.status, 429);
  assert.equal(providerWasCalled, false);
});

test("D1 quota tracking hashes the provider subject", async () => {
  let boundValues;
  const database = {
    prepare() {
      return {
        bind(...values) {
          boundValues = values;
          return { first: async () => ({ request_count: 1 }) };
        },
      };
    },
  };

  const allowed = await consumeQuota(
    { QUOTA_DB: database, DAILY_REQUEST_LIMIT: "25" },
    "private-apple-subject",
    2_000_000_000
  );

  assert.equal(allowed, true);
  assert.match(boundValues[0], /^[a-f0-9]{64}$/u);
  assert.notEqual(boundValues[0], "private-apple-subject");
  assert.equal(boundValues[1], "2033-05-18");
  assert.equal(boundValues[2], 25);
});

async function makeAppleIdentityToken({ nonce, now }) {
  const keyPair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"]
  );
  const publicJWK = await crypto.subtle.exportKey("jwk", keyPair.publicKey);
  publicJWK.kid = crypto.randomUUID();
  publicJWK.alg = "RS256";
  const header = encode({ alg: "RS256", kid: publicJWK.kid, typ: "JWT" });
  const nonceHash = Buffer.from(await crypto.subtle.digest("SHA-256", Buffer.from(nonce))).toString("hex");
  const claims = encode({
    iss: "https://appleid.apple.com",
    aud: "com.leow427.AISpotlight",
    sub: "apple-user-123",
    nonce: nonceHash,
    iat: now,
    exp: now + 300,
  });
  const signingInput = `${header}.${claims}`;
  const signature = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    keyPair.privateKey,
    Buffer.from(signingInput)
  );
  return { token: `${signingInput}.${base64URL(Buffer.from(signature))}`, publicJWK };
}

function encode(value) {
  return base64URL(Buffer.from(JSON.stringify(value)));
}

function base64URL(value) {
  return value.toString("base64url");
}
