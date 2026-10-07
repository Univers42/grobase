# Incident — credentials exposed in public repositories (2026-10)

**Status: OPEN.** Rotation is outstanding on items 1 and 2. Nothing below is closed by the
code changes that accompany this document; a redaction is cleanup, not remediation.

A credential that reached a public repository is **compromised**, whatever happens to the
file afterwards. GitHub serves deleted blobs by SHA, forks keep their own copies, and
mirrors and scrapers index continuously. The only thing that revokes access is rotating
the credential at its issuer.

```
detect → revoke → generate replacement → update vault42 → update consumers → verify the old one fails
   └── remove from history: optional cleanup, never the fix
```

---

## What was exposed

| # | Credential | Where | Since | Status |
|---|---|---|---|---|
| 1 | Supabase pooler DSN password (project `zcnlwipvjmwbofawoqit`) | `vendor/vite-gourmand/wiki/history.md` ×9, `FIX_SUPPABASE.md` ×1 | `92da41b0`, 2026-06-18 | **redacted in tree, still live — delete the project** |
| 2 | MongoDB Atlas DSN password (user `devprophoto_db_user`, cluster `vite-gourmand`) | `vendor/vite-gourmand/wiki/history.md` | `92da41b0`, 2026-06-18 | **redacted in tree, still live — delete the user** |
| 3 | `GH_PAT` GitHub token | `.env.local` (gitignored, never committed) — but `HUMAN-ATOMS.md:356-360` records it was pasted into AI-generated docs and agent transcripts | — | **needs revoking** |
| 4 | Google account `dev.pro.photo@gmail.com` credentials | 42ctl GitHub Pages history (`Univers42/42ctl`, `gh-pages`), per the owner | unknown | **owner action** |
| 5 | vault42 contents prior to 2026-10-07 | reachable by whoever held item 4 | — | superseded: new account, new org, new scope keys |

Items 1 and 2 are the urgent ones: both are live hosted databases reachable from the
internet with high-entropy real passwords. Neither is used by anything in this repo
(see §1-2 below), so they can be deleted outright rather than rotated.

### Why the gate did not catch 1 and 2

`.gitleaks.toml` allowlisted **whole directories**, `vendor/` among them. Scanning the
tree with the allowlist removed surfaced them immediately. The policy now allowlists
individual files, and `vendor/` and `scripts/seed/` are scanned again. A planted fake DSN
in `vendor/` and a fake `mbk_` key in `scripts/seed/` are both caught — pre-commit and CI.

**A directory-wide allowlist is a blind spot with a schedule, not a configuration choice.**

---

## Remediation

### 1 and 2. Supabase and MongoDB Atlas — DELETE rather than rotate (owner action)

**Nothing in grobase uses either one.** Established by grep, not assumption:

- `vendor/vite-gourmand/GROBASE.md:4` — the app runs "entirely on a local Grobase BaaS
  — no NestJS server, **no Supabase**". It was re-platformed onto an owner-scoped local
  Postgres mount; gate `m149-gourmand-baas.sh` talks to Kong, never to Supabase.
- The only callers of the legacy tooling (`scripts/supabase/setup-supabase.sh`,
  `scripts/db/connect.sh`) are vite-gourmand's own `mk_extensions/*.mk`, which nothing
  in grobase's build, CI or gates invokes.
- `scripts/seed/gourmand-tenant.sh:114` only *detects* a Supabase DSN if an operator
  supplies one; it embeds no credential.
- `scripts/report/portal.mjs:348` is a link to supabase.com/pricing.

So these are leftovers of the pre-grobase backend, and the strongest remediation is also
the cheapest: **delete the Supabase project and the Atlas database user (or the whole
cluster)**. A deleted resource cannot be reached with a leaked password at all, and
there is nothing left to keep in step.

If the data is still wanted: Supabase → Settings → Database → **Reset database
password**; Atlas → Database Access → user `devprophoto_db_user` → **Edit password** →
Autogenerate. Either way the old value stops working on save, and knowing it is not an
input. Nothing in this repo needs updating afterwards — no in-repo file holds the value.

### 3. GitHub token (owner action)

github.com/settings/tokens → **Revoke** the exposed PAT. Mint a replacement as a
fine-grained token with `Contents: read` on `Univers42/42ctl` only — it exists to read
that repo's releases, nothing more.

Store it in vault42 (`infra/GH_PAT`, personal), not in `.env.local`.
`scripts/env/assemble-env.sh` already refuses to copy a GitHub-token-shaped value into
`.env`, because every container reads that file.

### 4. Google account (owner action)

In this order, so you cannot lock yourself out:

1. Confirm the recovery phone and email are current and reachable.
2. Confirm 2FA is on — this alone defeats a password-only attacker.
3. Security → Your devices → sign out anything unfamiliar; revoke app passwords.
4. Security → Third-party apps with account access → remove what you do not recognise.
5. Change the password.

Data is untouched by a password change; devices simply re-authenticate.

To find what leaked and where, without printing values:

```sh
git clone https://github.com/Univers42/42ctl && cd 42ctl
git fetch origin 'refs/heads/*:refs/heads/*'
gitleaks git --redact -v        # every branch, gh-pages included
```

`--redact` is not optional: it is what keeps the values out of your terminal, your shell
history and any transcript.

### 5. vault42 (done, 2026-10-07)

Superseded rather than rotated. A new admin account, a new org (`Univers42`, slug
`univers-42`), project `grobase`, and fresh X25519 scope keys for `local`/`dev`/
`staging`/`prod` mean nothing sealed to the old identity is readable with the new one.
`VAULT42_REGISTER_TOKEN` on the authority was rotated, so previously shared invite tokens
no longer admit anyone.

The pre-2026-10-07 org is intact and untouched. It was not pruned: it may hold other
members' data, and in a zero-knowledge store deletion is unrecoverable.

---

## What changed in the repo

| Change | Effect |
|---|---|
| `.gitleaks.toml` allowlists files, not directories | `vendor/`, `scripts/seed/` scanned again; custom `mbk_` and credentialed-DSN rules |
| `scripts/ci/check-secrets.sh` | scans the git-visible tree; a missing scanner is now a **failure**, not a skip |
| `.githooks/pre-commit` + `make hooks` | gitleaks over the staged diff before a commit lands |
| `.gitignore` | `/secrets/`, keystores, `*.pem`, `*-key.pem`, `*.p12/.pfx/.jks`, `id_rsa*`, `credentials*.json` |
| 62 compose entries → `${KEY:?}` | no stack boots on a credential published in this repo |
| `GROBASE_ENV` + preflight | a dev env file cannot be used for a production bring-up |

---

## The lesson worth keeping

The exposure lasted ~4 months in a public repo with a secret-scanning gate that ran on
every push and reported clean, because the scanner had been told not to look in the
directory where the credentials were. A green gate over an unscanned path is more
dangerous than no gate: it buys confidence without providing coverage.

Related: [`configuration.md`](configuration.md) ·
[`wiki/security/remediation-tracker-2025-07-14.md`](../../wiki/security/remediation-tracker-2025-07-14.md)
