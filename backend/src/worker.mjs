const APPLE_ISSUER = "https://appleid.apple.com";
const APPLE_KEYS_URL = "https://appleid.apple.com/auth/keys";
const SESSION_ISSUER = "ai-spotlight-backend";
const SESSION_AUDIENCE = "ai-spotlight-macos";
const DEFAULT_SESSION_TTL_SECONDS = 30 * 24 * 60 * 60;
const DEFAULT_DAILY_REQUEST_LIMIT = 100;
const MAX_BODY_BYTES = 1_048_576;
const encoder = new TextEncoder();
let appleKeyCache;

export default {
  fetch(request, env) {
    return handleRequest(request, env);
  },
};

export async function handleRequest(request, env, services = {}) {
  const fetchImpl = services.fetchImpl ?? fetch;
  const nowSeconds = services.nowSeconds ?? (() => Math.floor(Date.now() / 1_000));
  const consumeQuotaImpl = services.consumeQuotaImpl ?? consumeQuota;
  const url = new URL(request.url);

  if (request.method === "GET" && url.pathname === "/health") {
    return json({ status: "ok" });
  }

  if (request.method === "POST" && url.pathname === "/v1/auth/apple") {
    try {
      const body = await readJSON(request);
      const claims = await verifyAppleIdentityToken(
        body.identity_token,
        body.nonce,
        env,
        fetchImpl,
        nowSeconds()
      );
      const ttl = boundedInteger(env.SESSION_TTL_SECONDS, DEFAULT_SESSION_TTL_SECONDS, 300, DEFAULT_SESSION_TTL_SECONDS);
      const accessToken = await signSessionToken(claims.sub, env.SESSION_SECRET, nowSeconds(), ttl);
      return json({ access_token: accessToken, token_type: "Bearer", expires_in: ttl });
    } catch (error) {
      if (error instanceof HTTPError) return apiError(error.status, error.code, error.message);
      return apiError(401, "invalid_apple_credential", "Sign in with Apple could not be verified.");
    }
  }

  const route = providerRoute(request.method, url.pathname);
  if (!route) return apiError(404, "not_found", "Route not found.");

  let session;
  try {
    session = await authenticateRequest(request, env.SESSION_SECRET, nowSeconds());
  } catch (error) {
    if (error instanceof HTTPError) return apiError(error.status, error.code, error.message);
    return apiError(401, "invalid_session", "Sign in again to continue.");
  }

  const providerKey = route.provider === "openai" ? env.OPENAI_API_KEY : env.ANTHROPIC_API_KEY;
  if (!providerKey) {
    return apiError(503, "provider_unavailable", `${providerDisplayName(route.provider)} is not configured.`);
  }

  try {
    if (route.operation !== "models") {
      const allowed = await consumeQuotaImpl(env, session.sub, nowSeconds());
      if (!allowed) {
        return apiError(429, "usage_limit_reached", "Your daily AI Spotlight cloud allowance has been reached.");
      }
    }

    const upstreamRequest = route.operation === "models"
      ? makeModelsRequest(route.provider, providerKey)
      : await makeChatRequest(request, route.provider, providerKey);
    const upstreamResponse = await fetchImpl(upstreamRequest);
    return passThrough(upstreamResponse);
  } catch (error) {
    if (error instanceof HTTPError) return apiError(error.status, error.code, error.message);
    return apiError(502, "provider_request_failed", "The cloud provider could not be reached.");
  }
}

function providerRoute(method, pathname) {
  const match = pathname.match(/^\/v1\/providers\/(openai|anthropic)\/(models|responses|messages)$/);
  if (!match) return undefined;
  const [, provider, operation] = match;
  if (operation === "models" && method === "GET") return { provider, operation };
  if (provider === "openai" && operation === "responses" && method === "POST") {
    return { provider, operation };
  }
  if (provider === "anthropic" && operation === "messages" && method === "POST") {
    return { provider, operation };
  }
  return undefined;
}

function makeModelsRequest(provider, providerKey) {
  if (provider === "openai") {
    return new Request("https://api.openai.com/v1/models", {
      headers: { Authorization: `Bearer ${providerKey}` },
    });
  }
  return new Request("https://api.anthropic.com/v1/models?limit=1000", {
    headers: {
      "x-api-key": providerKey,
      "anthropic-version": "2023-06-01",
    },
  });
}

async function makeChatRequest(request, provider, providerKey) {
  const body = await readJSON(request);
  const model = validateModel(body.model);

  if (provider === "openai") {
    const input = validateMessages(body.input);
    return new Request("https://api.openai.com/v1/responses", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${providerKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ model, input, stream: true, store: false }),
    });
  }

  const messages = validateMessages(body.messages);
  const maxTokens = boundedInteger(body.max_tokens, 4_096, 1, 8_192);
  return new Request("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": providerKey,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ model, messages, max_tokens: maxTokens, stream: true }),
  });
}

function validateModel(value) {
  if (typeof value !== "string" || !/^[A-Za-z0-9._:-]{1,128}$/.test(value)) {
    throw new HTTPError(400, "invalid_request", "A valid model ID is required.");
  }
  return value;
}

function validateMessages(value) {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) {
    throw new HTTPError(400, "invalid_request", "Between 1 and 100 messages are required.");
  }
  let totalCharacters = 0;
  return value.map((message) => {
    if (!message || !["user", "assistant"].includes(message.role) || typeof message.content !== "string") {
      throw new HTTPError(400, "invalid_request", "Each message must have a valid role and text content.");
    }
    totalCharacters += message.content.length;
    if (message.content.length > 200_000 || totalCharacters > 500_000) {
      throw new HTTPError(413, "request_too_large", "The conversation is too large.");
    }
    return { role: message.role, content: message.content };
  });
}

async function readJSON(request) {
  const declaredLength = Number(request.headers.get("content-length") ?? 0);
  if (declaredLength > MAX_BODY_BYTES) {
    throw new HTTPError(413, "request_too_large", "The request body is too large.");
  }
  const bytes = await request.arrayBuffer();
  if (bytes.byteLength > MAX_BODY_BYTES) {
    throw new HTTPError(413, "request_too_large", "The request body is too large.");
  }
  try {
    return JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    throw new HTTPError(400, "invalid_json", "The request body must be valid JSON.");
  }
}

async function authenticateRequest(request, secret, now) {
  const header = request.headers.get("authorization") ?? "";
  const match = header.match(/^Bearer (\S+)$/);
  if (!match) throw new HTTPError(401, "missing_session", "Sign in to continue.");
  try {
    return await verifySessionToken(match[1], secret, now);
  } catch {
    throw new HTTPError(401, "invalid_session", "Sign in again to continue.");
  }
}

export async function verifyAppleIdentityToken(token, nonce, env, fetchImpl = fetch, now = Math.floor(Date.now() / 1_000)) {
  if (typeof token !== "string"
      || token.length > 16_384
      || typeof nonce !== "string"
      || nonce.length < 16
      || nonce.length > 256) {
    throw new HTTPError(401, "invalid_apple_credential", "Sign in with Apple could not be verified.");
  }
  if (!env.APPLE_CLIENT_ID) throw new HTTPError(503, "server_not_configured", "Apple sign-in is unavailable.");

  const { header, claims, signingInput, signature } = decodeJWT(token);
  if (header.alg !== "RS256" || typeof header.kid !== "string") throw new Error("Unexpected Apple token algorithm");
  const key = await appleVerificationKey(header.kid, fetchImpl, now);
  const cryptoKey = await crypto.subtle.importKey(
    "jwk",
    key,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const validSignature = await crypto.subtle.verify(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    signature,
    encoder.encode(signingInput)
  );
  const audiences = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
  const expectedNonce = await sha256Hex(nonce);
  if (!validSignature
      || claims.iss !== APPLE_ISSUER
      || !audiences.includes(env.APPLE_CLIENT_ID)
      || typeof claims.sub !== "string"
      || claims.sub.length < 1
      || typeof claims.exp !== "number"
      || claims.exp < now - 60
      || typeof claims.iat !== "number"
      || claims.iat > now + 60
      || claims.exp <= claims.iat
      || claims.nonce !== expectedNonce) {
    throw new Error("Invalid Apple identity claims");
  }
  return claims;
}

async function appleVerificationKey(kid, fetchImpl, now) {
  if (!appleKeyCache || appleKeyCache.expiresAt <= now || !appleKeyCache.keys.some((key) => key.kid === kid)) {
    const response = await fetchImpl(APPLE_KEYS_URL, {
      headers: { Accept: "application/json" },
      cf: { cacheTtl: 3_600, cacheEverything: true },
    });
    if (!response.ok) throw new Error("Unable to retrieve Apple verification keys");
    const payload = await response.json();
    if (!Array.isArray(payload.keys)) throw new Error("Invalid Apple key response");
    appleKeyCache = { keys: payload.keys, expiresAt: now + 3_600 };
  }
  const key = appleKeyCache.keys.find((candidate) => candidate.kid === kid && candidate.kty === "RSA");
  if (!key) throw new Error("Apple verification key was not found");
  return key;
}

export async function signSessionToken(subject, secret, now = Math.floor(Date.now() / 1_000), ttl = DEFAULT_SESSION_TTL_SECONDS) {
  requireSessionSecret(secret);
  const header = encodeJSON({ alg: "HS256", typ: "JWT" });
  const claims = encodeJSON({
    iss: SESSION_ISSUER,
    aud: SESSION_AUDIENCE,
    sub: subject,
    iat: now,
    exp: now + ttl,
  });
  const signingInput = `${header}.${claims}`;
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", key, encoder.encode(signingInput));
  return `${signingInput}.${base64URLEncode(new Uint8Array(signature))}`;
}

export async function verifySessionToken(token, secret, now = Math.floor(Date.now() / 1_000)) {
  requireSessionSecret(secret);
  if (typeof token !== "string" || token.length > 4_096) throw new Error("Invalid session token");
  const { header, claims, signingInput, signature } = decodeJWT(token);
  if (header.alg !== "HS256") throw new Error("Unexpected session token algorithm");
  const key = await crypto.subtle.importKey(
    "raw",
    encoder.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["verify"]
  );
  const valid = await crypto.subtle.verify("HMAC", key, signature, encoder.encode(signingInput));
  if (!valid
      || claims.iss !== SESSION_ISSUER
      || claims.aud !== SESSION_AUDIENCE
      || typeof claims.sub !== "string"
      || typeof claims.iat !== "number"
      || claims.iat > now + 60
      || typeof claims.exp !== "number"
      || claims.exp <= claims.iat
      || claims.exp < now) {
    throw new Error("Invalid session token");
  }
  return claims;
}

function requireSessionSecret(secret) {
  if (typeof secret !== "string" || secret.length < 32) {
    throw new Error("SESSION_SECRET must contain at least 32 characters");
  }
}

export async function consumeQuota(env, subject, now = Math.floor(Date.now() / 1_000)) {
  if (!env.QUOTA_DB) throw new HTTPError(503, "quota_unavailable", "Usage metering is unavailable.");
  const limit = boundedInteger(env.DAILY_REQUEST_LIMIT, DEFAULT_DAILY_REQUEST_LIMIT, 1, 10_000);
  const day = new Date(now * 1_000).toISOString().slice(0, 10);
  const userID = await sha256Hex(subject);
  const row = await env.QUOTA_DB.prepare(`
    INSERT INTO daily_usage (user_id, usage_day, request_count)
    VALUES (?1, ?2, 1)
    ON CONFLICT(user_id, usage_day) DO UPDATE SET request_count = request_count + 1
    WHERE request_count < ?3
    RETURNING request_count
  `).bind(userID, day, limit).first();
  return row !== null;
}

function passThrough(response) {
  const headers = new Headers();
  for (const name of ["content-type", "cache-control", "retry-after", "x-request-id", "request-id"]) {
    const value = response.headers.get(name);
    if (value) headers.set(name, value);
  }
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Cache-Control", "no-store");
  return new Response(response.body, { status: response.status, headers });
}

function decodeJWT(token) {
  const parts = token.split(".");
  if (parts.length !== 3) throw new Error("Invalid JWT");
  const header = JSON.parse(new TextDecoder().decode(base64URLDecode(parts[0])));
  const claims = JSON.parse(new TextDecoder().decode(base64URLDecode(parts[1])));
  return {
    header,
    claims,
    signingInput: `${parts[0]}.${parts[1]}`,
    signature: base64URLDecode(parts[2]),
  };
}

function encodeJSON(value) {
  return base64URLEncode(encoder.encode(JSON.stringify(value)));
}

function base64URLEncode(bytes) {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function base64URLDecode(value) {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/") + "=".repeat((4 - value.length % 4) % 4);
  const binary = atob(base64);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

async function sha256Hex(value) {
  const digest = await crypto.subtle.digest("SHA-256", encoder.encode(value));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function boundedInteger(value, fallback, minimum, maximum) {
  const number = Number(value);
  return Number.isInteger(number) && number >= minimum && number <= maximum ? number : fallback;
}

function providerDisplayName(provider) {
  return provider === "openai" ? "OpenAI" : "Anthropic";
}

function json(value, init = {}) {
  const headers = new Headers(init.headers);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(JSON.stringify(value), { ...init, headers });
}

function apiError(status, code, message) {
  return json({ error: { code, message } }, { status });
}

class HTTPError extends Error {
  constructor(status, code, message) {
    super(message);
    this.status = status;
    this.code = code;
  }
}
