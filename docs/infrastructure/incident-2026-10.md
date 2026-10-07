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
| 1 | Supabase pooler DSN password (project `zcnlwipvjmwbofawoqit`) | `vendor/vite-gourmand/wiki/history.md` ×9, `FIX_SUPPABASE.md` ×1 | `92da41b0`, 2026-06-18 | **redacted in tree, NOT rotated** |
| 2 | MongoDB Atlas DSN password (user `devprophoto_db_user`, cluster `vite-gourmand`) | `vendor/vite-gourmand/wiki/history.md` | `92da41b0`, 2026-06-18 | **redacted in tree, NOT rotated** |
| 3 | `GH_PAT` GitHub token | `.env.local` (gitignored, never committed) — but `HUMAN-ATOMS.md:356-360` records it was pasted into AI-generated docs and agent transcripts | — | **needs revoking** |
| 4 | Google account `dev.pro.photo@gmail.com` credentials | 42ctl GitHub Pages history (`Univers42/42ctl`, `gh-pages`), per the owner | unknown | **owner action** |
| 5 | vault42 contents prior to 2026-10-07 | reachable by whoever held item 4 | — | superseded: new account, new org, new scope keys |

Item 1 and 2 are the urgent ones: both are live hosted databases reachable from the
internet, and the passwords are high-entropy real values, not placeholders.

### Why the gate did not catch 1 and 2

`.gitleaks.toml` allowlisted **whole directories**, `vendor/` among them. Scanning the
tree with the allowlist removed surfaced them immediately. The policy now allowlists
individual files, and `vendor/` and `scripts/seed/` are scanned again. A planted fake DSN
in `vendor/` and a fake `mbk_` key in `scripts/seed/` are both caught — pre-commit and CI.

**A directory-wide allowlist is a blind spot with a schedule, not a configuration choice.**

---

## Remediation

### 1. Supabase (owner action)

Dashboard → project `zcnlwipvjmwbofawoqit` → Settings → Database → **Reset database
password**. The console mints the new value; the old one stops working on save. Knowing
the old password is not an input to this.

Then update consumers — `vendor/vite-gourmand` reads it from its own env, and
`scripts/db/connect.sh` / `scripts/supabase/setup-supabase.sh` take it from the
environment, so no in-repo value changes.

Verify: connecting with the old password fails.

### 2. MongoDB Atlas (owner action)

Atlas → Database Access → user `devprophoto_db_user` → Edit → **Edit password** →
Autogenerate. Same reasoning.

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
