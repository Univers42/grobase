# Media generator

`gen-media.mjs` is a zero-dependency Node script that renders procedural SVG
ocean/surf art for every surfind beach — no npm deps, no external photos.

For each of the 30 beaches it writes three layered scenes into
`../public/media/beaches/`:

- `<slug>-cover.svg` — 1600×900 hero
- `<slug>-1.svg`, `<slug>-2.svg` — 1200×800 gallery

Each scene is a sky gradient + a glowing sun on the horizon, 4 translucent
bezier wave bands with foam crests, a horizon line and a beach-name/region
label. Everything (palette, sun x-position, wave amplitude/phase) is derived
deterministically from a hash of the slug, so the same beach always renders the
same art and different beaches look distinct. Idempotent — it overwrites.

## Run

```sh
node gen-media.mjs        # writes 90 SVGs (3 × 30 beaches)
```

Docker-first (no host Node):

```sh
docker run --rm -v "$PWD/..":/app -w /app/scripts node:20-alpine node gen-media.mjs
```

Wire-up: set `beaches.cover_image = '/media/beaches/<slug>-cover.svg'` and point
`beach_images` rows at `-1.svg` / `-2.svg`. `grobase/serve.mjs` already serves
`.svg` as `image/svg+xml`.
