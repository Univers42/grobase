import type { VercelRequest, VercelResponse } from "@vercel/node";
import crypto from "node:crypto";

/**
 * callback — GitHub redirects here after the App is installed (with `installation_id` +
 * `state`). The relay HMAC-signs the forward (it holds ONLY the relay secret — it cannot
 * mint a token) and POSTs it to the grobase (fly) control plane, which verifies the
 * signature, records the installation, and marks the nonce ready for the CLI poll.
 *
 * The signed body is the EXACT bytes forwarded — grobase hashes the raw body — so the
 * same JSON string is both hashed and sent.
 */
export default async function handler(req: VercelRequest, res: VercelResponse): Promise<void> {
  const installationId = firstValue(req.query.installation_id);
  const state = firstValue(req.query.state);
  if (!installationId || !state) {
    res.status(400).send("missing installation_id or state");
    return;
  }
  const secret = process.env.GITHUB_RELAY_SECRET;
  const flyUrl = process.env.GROBASE_FLY_URL;
  if (!secret || !flyUrl) {
    res.status(500).send("relay misconfigured (GITHUB_RELAY_SECRET / GROBASE_FLY_URL)");
    return;
  }
  const body = JSON.stringify({ installation_id: Number(installationId), state });
  const header = signRelay(secret, body);
  const resp = await fetch(`${flyUrl.replace(/\/$/, "")}/v1/github/callback`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-github-relay": header },
    body,
  });
  if (!resp.ok) {
    res.status(502).send(`relay forward failed: HTTP ${resp.status}`);
    return;
  }
  res.setHeader("content-type", "text/html; charset=utf-8");
  res.status(200).send(connectedPage());
}

/** Build the `v1.<ts>.<hexsig>` header grobase's verifyRelay expects (serviceauth v1). */
function signRelay(secret: string, body: string): string {
  const ts = Math.floor(Date.now() / 1000).toString();
  const bodyHash = crypto.createHash("sha256").update(body).digest("hex");
  const sig = crypto.createHmac("sha256", secret).update(`v1\n${ts}\n${bodyHash}`).digest("hex");
  return `v1.${ts}.${sig}`;
}

/** Read the first value of a query parameter (Vercel gives string | string[]). */
function firstValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}

/** The "you can close this tab" confirmation shown after a successful forward. */
function connectedPage(): string {
  return `<!doctype html><meta charset="utf-8"><title>Connected</title>
<body style="font-family:system-ui;max-width:32rem;margin:4rem auto;line-height:1.5">
<h1>&#10003; GitHub App connected</h1>
<p>You can close this tab and return to your terminal — <code>42ctl</code> is finishing the connection.</p>
</body>`;
}
