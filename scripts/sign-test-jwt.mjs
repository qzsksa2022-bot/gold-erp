#!/usr/bin/env node
/**
 * Minimal, dependency-free HS256 JWT signer for scripts/run_postgrest_http_
 * test.sh — this project has no jsonwebtoken/jose dependency (deliberately;
 * it is not needed anywhere else), so this uses Node's built-in `crypto`
 * module directly rather than adding a new dependency purely for one test
 * script. Standard JWT construction: base64url(header) + "." +
 * base64url(payload), HMAC-SHA256-signed with the shared secret, base64url-
 * encoded — exactly what a real Supabase project's GoTrue issues and what
 * PostgREST's jwt-secret config verifies.
 *
 * Usage: node scripts/sign-test-jwt.mjs <secret> <sub-uuid> <role>
 */
import { createHmac } from "node:crypto";

function base64url(input) {
  return Buffer.from(input).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

const [, , secret, sub, role] = process.argv;
if (!secret || !sub || !role) {
  console.error("Usage: node scripts/sign-test-jwt.mjs <secret> <sub-uuid> <role>");
  process.exit(1);
}

const header = { alg: "HS256", typ: "JWT" };
const now = Math.floor(Date.now() / 1000);
const payload = {
  sub,
  role,
  iat: now,
  exp: now + 3600,
};

const encodedHeader = base64url(JSON.stringify(header));
const encodedPayload = base64url(JSON.stringify(payload));
const signingInput = `${encodedHeader}.${encodedPayload}`;
const signature = createHmac("sha256", secret).update(signingInput).digest("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

console.log(`${signingInput}.${signature}`);
