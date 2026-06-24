import type { VercelRequest, VercelResponse } from "@vercel/node";

/**
 * connect-start — the entry the grobase `install_url` points at. Redirects the operator
 * to the GitHub App install page carrying `state=<nonce>` so the install callback can be
 * tied back to the pending connect. Holds no secret; only the App slug.
 */
export default function handler(req: VercelRequest, res: VercelResponse): void {
  const nonce = firstValue(req.query.nonce);
  const slug = process.env.GITHUB_APP_SLUG;
  if (!nonce) {
    res.status(400).send("missing ?nonce");
    return;
  }
  if (!slug) {
    res.status(500).send("relay misconfigured (GITHUB_APP_SLUG)");
    return;
  }
  const target = `https://github.com/apps/${encodeURIComponent(slug)}/installations/new?state=${encodeURIComponent(nonce)}`;
  res.redirect(302, target);
}

/** Read the first value of a query parameter (Vercel gives string | string[]). */
function firstValue(value: string | string[] | undefined): string | undefined {
  return Array.isArray(value) ? value[0] : value;
}
