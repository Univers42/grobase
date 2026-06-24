# Self-hosted fonts

NO runtime Google Fonts (CSP forbids `fonts.googleapis.com`). Drop the woff2 files
here and `src/styles/fonts.css` will pick them up.

## Required

- `instrument-serif-italic.woff2` — Instrument Serif, italic, weight 400.
  Used for the big display headlines (landing hero, page titles).
  Source: <https://fonts.google.com/specimen/Instrument+Serif> (OFL).
  Until the file is present, the `@font-face` 404s harmlessly and the CSS falls
  back to `Georgia, serif` (declared in the `font-display` stack) — the layout is
  unaffected, only the typeface differs.

## Optional (Inter is loaded from the system fallback by default)

- `inter-var.woff2` — Inter variable. If absent, the body uses the system UI stack
  (`system-ui, -apple-system, Segoe UI, Roboto`) which is near-identical.

## How to add

1. Download the OFL woff2 from the foundry (do NOT hotlink Google's CDN).
2. Place it here as the exact filename above.
3. Rebuild (`vite build`) — no code change needed; the `@font-face` already points
   at `/fonts/<name>.woff2`.
