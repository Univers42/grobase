# Grobase marketing site

The standalone marketing website for **Grobase** — the engine-agnostic BaaS built in
`apps/baas/mini-baas-infra`. Three static pages (Astro): the landing page with the
scroll-reactive **tenant galaxy**, `/pricing` (radical-transparency pricing: retail AND
live-measured infra cost), and `/compare` (honest vs Supabase / PocketBase / Firebase).

Docker-first like the rest of the repo — **no host npm**. All numbers on the site are
transcribed from `apps/baas/wiki/{cost-analysis,service-tiers,nano-edition}.md` into
`src/data/tiers.ts` (single source of truth). When the wiki numbers move (e.g. nano's
measured 5.1 MB / 2.0 MiB), update `src/data/*.ts` — nothing else hardcodes them.

## Run

```bash
make grobase-up      # dev server with hot reload → http://127.0.0.1:4324
make grobase-logs    # follow logs
make grobase-down    # stop
make grobase-audit   # FULL quality gate (see below) → exit code is CI-gateable
```

## Quality gate (`make grobase-audit`)

One-shot container (Dockerfile `audit` stage: node:22-alpine + apk chromium) that runs
`scripts/audit/run-all.mjs`:

1. unit tests — galaxy layout purity (`node --experimental-strip-types --test`)
2. `astro build` (production)
3. `html-validate` over `dist/`
4. `csp-check.mjs` — real `securitypolicyviolation` events in headless Chromium; asserts the
   per-page meta CSP has SHA-256 hashes and no `unsafe-inline`
5. `pa11y` (WCAG2AA) on `/`, `/pricing/`, `/compare/`
6. Lighthouse: **all 4 categories ≥ 90 on all 3 pages** (override: `GROBASE_LH_MIN=…`)

## Architecture notes

- **CSP**: Astro `security.csp` emits a per-page `<meta>` CSP with hashes for every inline
  style/script it generates. Zero inline `style=` attributes anywhere (engine/tier accents are
  classes, e.g. `.tier--nano` sets `--tier-color`). Diagrams are inline SVG styled by classes.
- **Galaxy** (`src/scripts/galaxy/`): vanilla TS, no deps, no d3. ~120 deterministic tenants
  (mulberry32), pure per-section layout functions (nebula / engines / tiers / isolation /
  planes / cta), critically-damped morphs, glow-sprite Canvas2D renderer, IntersectionObserver
  scroll director. Reduced motion → static frames; no JS → `<noscript>` SVG starfield; init is
  idle-deferred so the H1 stays the LCP element. Keyboard path: the "Explore example tenants"
  buttons in the hero (`role="status"` mirror for screen readers).
- **Fonts**: self-hosted latin-subset woff2 (Sora 700 / Inter 400+600 / IBM Plex Mono 400,
  ~78 KB total); only the first two are preloaded.
- **Prod image** (`Dockerfile` `prod` stage): nginx serves `dist/` with the HTTP-layer headers
  the meta CSP can't carry (`frame-ancestors`, `X-Frame-Options`). Not deployed yet.
