# Publishing `@mini-baas/js`

This package is **publish-ready but intentionally NOT auto-published**. Pushing to the public npm
registry is an irreversible, money/identity-bearing action, so it is left as a deliberate human
step. CI does not run `npm publish`.

## The one human step

From the `sdk/` directory, authenticated against npm as a maintainer of the `@mini-baas` scope:

```sh
npm publish --access public
```

`--access public` is also pinned in `package.json` (`publishConfig.access`), so the flag is belt-and-suspenders.

## What runs automatically on publish

`prepublishOnly` rebuilds and runs the test suite before the tarball is assembled:

```sh
npm run build && npm test
```

If either fails, the publish aborts.

## Verify the artifact before publishing (Docker-first, no host Node)

Confirm a clean build + tarball without touching the host toolchain:

```sh
docker run --rm -v "$PWD":/w -w /w node:20-alpine sh -c \
  'npm ci --ignore-scripts && npm run build && npm test && npm pack --dry-run'
```

The tarball should contain only `dist/` (JS + `.d.ts` types + the `baas` CLI bin), `package.json`,
`README.md`, `CHANGELOG.md`, and `LICENSE` — no `src/`, `tests/`, or `node_modules/`.

## Pre-publish checklist

- [ ] `version` in `package.json` bumped (semver) and a matching entry added to `CHANGELOG.md`.
- [ ] `npm pack --dry-run` tarball contents look sane (see above).
- [ ] Logged in to npm with publish rights to the `@mini-baas` scope (`npm whoami`).
- [ ] You intend to publish — this is public and not easily undone (`npm unpublish` is restricted).

## Notes

- The package is ESM-only (`"type": "module"`) and ships pre-built JS + types; consumers do not
  build from source.
- Provenance/2FA publishing (`npm publish --provenance` from a trusted CI environment) is the
  preferred long-term path but is a separate human/CI setup task, not wired here.
