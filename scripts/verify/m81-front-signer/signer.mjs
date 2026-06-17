// m81 front-signer — a MINIMAL but REAL RS256 ISSUER (zero npm deps, node:22-alpine).
//
// This is the half m64 skipped. m64's "signer" was a stub that the gate hit directly;
// here the signer is wired as a genuine *issuer* whose tokens are validated end-to-end
// THROUGH Kong (RS256 jwt-plugin) and then tenant-control (RS256/JWKS) — the live shape.
//
// It is the runbook's documented option-2 ("put a small JWKS-publishing signer in front")
// for the cases where the vendored gotrue (supabase/gotrue:v2.188.1, HS256-only) cannot
// itself issue RS256. It:
//   • generates ONE real RSA-2048 keypair (kid=KID) — the issuing key,
//   • serves a real .well-known/jwks.json (n,e of the public half) for tenant-control,
//   • serves the public key as SPKI PEM at /pem for Kong's rsa_public_key field,
//   • mints RS256 tokens (header alg=RS256, kid present) with iss=ISS so Kong keys on it,
//   • mints attack tokens (RS->HS forgery, wrong-key, unknown-kid, alg=none) that MUST 401.
//
// Crypto via node:crypto (RSA-SHA256 sign / HMAC) + base64url; no jose/PyJWT.

import http from 'node:http';
import crypto from 'node:crypto';

const KID = process.env.M81_KID || 'm81-key-1';
const ISS = process.env.M81_ISSUER || 'https://m81-issuer.test/auth/v1';
const HS_SECRET = process.env.M81_HS_SECRET || 'unset-hs-secret';
const b64url = (b) => Buffer.from(b).toString('base64url');

// The real issuing key (its public half is published in JWKS + PEM) and a SECOND,
// unrelated RSA key whose tokens must be REJECTED (wrong-key / signature-mismatch arm).
const real = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
const other = crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });

// JWKS doc for the REAL key only (n,e from its public JWK export) — for tenant-control.
const jwk = real.publicKey.export({ format: 'jwk' });
const jwks = { keys: [{ kty: 'RSA', kid: KID, alg: 'RS256', use: 'sig', n: jwk.n, e: jwk.e }] };
// SPKI PEM of the same public key — for Kong's rsa_public_key field.
const pem = real.publicKey.export({ format: 'pem', type: 'spki' }).toString();

const claims = (sub) => ({
  sub, email: sub + '@m81.test', role: 'authenticated', aud: 'authenticated', iss: ISS,
  iat: Math.floor(Date.now() / 1000), exp: Math.floor(Date.now() / 1000) + 3600,
});
const jws = (header, payload, signFn) => {
  const h = b64url(JSON.stringify(header));
  const p = b64url(JSON.stringify(payload));
  return `${h}.${p}.${signFn(`${h}.${p}`)}`;
};
const rsSign = (key, data) => crypto.sign('RSA-SHA256', Buffer.from(data), key).toString('base64url');
const hsSign = (secret, data) => crypto.createHmac('sha256', secret).update(data).digest('base64url');

const tokens = {
  // ACCEPT: a valid RS256 token, correct kid, signed by the published issuing key.
  valid: () => jws({ alg: 'RS256', typ: 'JWT', kid: KID }, claims('m81-user-valid'),
    (d) => rsSign(real.privateKey, d)),
  // REJECT: the classic RS->HS algorithm-confusion forgery — an HS256 token signed
  // using the RSA public-modulus bytes (which the attacker can read from the JWKS) as
  // the HMAC secret. A correct RS256 verifier (Kong + tenant-control) must NOT accept it.
  hsforge: () => {
    const n = Buffer.from(jwk.n, 'base64url');
    return jws({ alg: 'HS256', typ: 'JWT' }, claims('m81-attacker'), (d) => hsSign(n, d));
  },
  // REJECT: RS256, correct kid, but signed by an UNRELATED key (signature mismatch).
  wrongkey: () => jws({ alg: 'RS256', typ: 'JWT', kid: KID }, claims('m81-attacker'),
    (d) => rsSign(other.privateKey, d)),
  // REJECT: RS256, valid signature, but a kid that is NOT in the JWKS.
  unknownkid: () => jws({ alg: 'RS256', typ: 'JWT', kid: 'no-such-kid' }, claims('m81-attacker'),
    (d) => rsSign(real.privateKey, d)),
  // REJECT: alg=none downgrade (empty signature).
  none: () => `${b64url(JSON.stringify({ alg: 'none', typ: 'JWT' }))}.${b64url(JSON.stringify(claims('m81-attacker')))}.`,
  // PARITY helper: a legit HS256 token signed with the shared secret (for an HS256 arm).
  hs256: () => jws({ alg: 'HS256', typ: 'JWT' }, claims('m81-user-hs'),
    (d) => hsSign(HS_SECRET, d)),
};

http.createServer((req, res) => {
  const u = new URL(req.url, 'http://x');
  if (u.pathname === '/.well-known/jwks.json') {
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(JSON.stringify(jwks));
  }
  if (u.pathname === '/pem') {                       // SPKI PEM for Kong rsa_public_key
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end(pem);
  }
  const m = u.pathname.match(/^\/token\/(\w+)$/);
  if (m && tokens[m[1]]) {
    res.writeHead(200, { 'content-type': 'text/plain' });
    return res.end(tokens[m[1]]());
  }
  res.writeHead(404); res.end('nope');
}).listen(8080, () => console.error('m81-front-signer up on :8080 (REAL RS256 issuer; iss=' + ISS + ')'));
