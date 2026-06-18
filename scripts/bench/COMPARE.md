# Competitive comparison graph generator

`compare-report.mjs` turns a single sourced dataset (`compare-data.json`) into a
self-contained competitive-benchmark report: hand-rolled SVG charts + an
`index.html` + a `report.md`, under `artifacts/bench/compare/`. It is the graph
half of the BENCHMARK REPORT: the dataset agent assembles the numbers, this
generator draws them.

- **Zero dependency.** Pure Node ESM (built-ins only) — runs in `node:22-bookworm`
  with no `npm install`. The SVG is hand-written (axes, gridlines, legend, value
  labels, winner annotation); there is no charting library.
- **Honest by construction** (kernel rule #4 / [`METHOD.md`](METHOD.md)). Every
  datapoint carries a `source`; the chart *style* encodes that source so a reader
  can see at a glance what we measured vs. what the vendor published vs. what we
  modeled. `na` series are omitted from the plot and listed in a footnote.

## Run it

```bash
# from mini-baas-infra/  — Docker-first, no host node
make bench-compare
# overrides:
make bench-compare DATA=/b/compare-data.json OUT=/b/artifacts/bench/compare
```

`DATA`/`OUT` are paths *inside the container* (the target mounts `scripts/bench`
at `/b` and `artifacts` at `/b/artifacts`). Defaults are the canonical paths, so
plain `make bench-compare` is the normal invocation. Output:

```
artifacts/bench/compare/
  index.html              # all charts inline + legend + per-chart source table
  report.md               # links the SVGs + a comparison table per metric
  charts/<key>.svg        # one SVG per metric and per scale curve
```

Direct (no make) — same container, useful for a custom fixture:

```bash
docker run --rm -u "$(id -u):$(id -g)" \
  -v "$PWD/scripts/bench":/b -v "$PWD/artifacts":/b/artifacts \
  -w /b public.ecr.aws/docker/library/node:22-bookworm \
  node compare-report.mjs --data /b/compare-data.json --out /b/artifacts/bench/compare
```

## The source-labeling convention (the whole point)

| `source` | chart style | what it MUST carry | meaning |
|---|---|---|---|
| `measured` | solid + filled, `★` on the winner | `artifact` — a path under `artifacts/` | **our** measurement, reproducible via a make target |
| `published` | hatched + dashed, `(pub)` tag | `note` — origin (vendor docs / pricing page / architecture) | the **vendor's** claim — never presented as ours |
| `modeled` | dotted, `(model)` tag | `note` — the method/formula | derived, not directly measured |
| `na` | omitted from plot, listed in a footnote | `note` — why there is no number | we have no honest number (e.g. Firebase has no self-host footprint) |

A fabricated precise number is a failure state. When unsure → `na` with a note.

## Data schema (`compare-data.json`)

```jsonc
{
  "meta": {
    "title": "…", "subtitle": "…",
    "generatedFrom": "scripts/bench/compare-data.json",
    "honestyNote": "…",
    "contenders": ["grobase-nano", "pocketbase", "supabase-selfhost", "..."]
    //   ^ controls bar/line order; if omitted it is derived from the data in
    //     canonical order (grobase-nano…grobase-max, pocketbase,
    //     supabase-selfhost, supabase-cloud, firebase)
  },
  "metrics": [                       // single-value comparisons → grouped bar chart
    {
      "key": "idle_footprint_mib",   // file name: charts/idle_footprint_mib.svg
      "label": "Idle footprint",
      "unit": "MiB",
      "lowerIsBetter": true,         // default true; false → highest bar wins
      "context": "resources — RSS at rest",
      "data": {
        "grobase-nano":      { "value": 2.008, "source": "measured",  "artifact": "artifacts/nano-vs-pocketbase.json" },
        "supabase-cloud":    { "value": 25,    "source": "published", "note": "supabase pro base, pricing page" },
        "grobase-pro":       { "value": 0.12,  "source": "modeled",   "note": "fly.io shared-cpu-1x / density" },
        "firebase":          { "value": null,  "source": "na",        "note": "fully managed, no self-host" }
      }
    }
  ],
  "scaleCurves": [                   // y vs tenant-count → line chart (log-x)
    {
      "key": "rss_vs_tenants",       // file name: charts/rss_vs_tenants.svg
      "label": "Data-plane RSS vs tenant count",
      "unit": "MiB",
      "context": "the density moat",
      "x": [200, 1000, 10000, 24887, 100000],
      "series": {
        "grobase-nano": { "y": [2.1, 2.3, 2.6, 2.6, null], "source": "measured", "artifact": "artifacts/scale/footprint-live-24887.json" },
        "pocketbase":   { "y": [13, 30, 180, null, 1800],   "source": "modeled",  "note": "linear per-tenant DB extrapolation" },
        "firebase":     { "y": null, "source": "na", "note": "no self-host RSS" }
      }
    }
  ]
}
```

Notes on the schema:
- A `value`/`y` of `null` is treated as missing for that point (the line just
  skips it; a bar with a null value is dropped). `y` arrays align with `x` by
  index.
- An `na` series, or an all-null series, is omitted and footnoted — the chart
  still renders for the remaining contenders.

## Add a contender

1. Pick a **canonical key** (see [`packages.json`](../../config/packages/packages.json)
   for the grobase tiers; the recognized keys are `grobase-nano`,
   `grobase-basic`, `grobase-essential`, `grobase-pro`, `grobase-max`,
   `pocketbase`, `supabase-selfhost`, `supabase-cloud`, `firebase`). A new key
   works too — it gets a fallback colour and sorts after the canonical ones.
2. Add a `data`/`series` entry for it under each metric/curve where you have a
   number. Omit it (or use `na` + a note) where you don't.
3. Optionally add it to `meta.contenders` to fix its order.
4. `make bench-compare`.

## Add a metric or scale curve

- **Metric** (single value): append an object to `metrics[]` with a unique
  `key`, `label`, `unit`, `context`, `lowerIsBetter`, and a `data` map. One SVG
  bar chart `charts/<key>.svg` is produced automatically.
- **Scale curve** (y vs tenants): append to `scaleCurves[]` with `key`, `label`,
  `unit`, `context`, an `x` array (tenant counts) and a `series` map of
  `{ y: [...], source, artifact|note }`. One SVG line chart is produced.

Keep `key` stable — it is the SVG file name and the `report.md` anchor. To add a
canonical-key colour, edit `CONTENDER_COLOR` in `compare-report.mjs`.

## Robustness

- Missing/unparseable `--data` → a clear error on stderr, exit `2`.
- An `na` or all-null series → skipped + footnoted, never a crash.
- A metric/curve with **no** plottable contenders → an empty chart with a
  "no data" message (still valid SVG), exit `0`.
- Output files are written as the invoking user (`make` passes `--user`), so they
  are removable without `sudo`.

## Self-check

Build a tiny fixture with all four source types and confirm it renders:

```bash
cat > /tmp/sample.json <<'EOF'
{ "meta": { "title": "self-check", "contenders": ["grobase-nano","pocketbase","firebase"] },
  "metrics": [ { "key": "idle_footprint_mib", "label": "Idle footprint", "unit": "MiB",
    "lowerIsBetter": true, "context": "resources",
    "data": { "grobase-nano": { "value": 2.0, "source": "measured", "artifact": "artifacts/nano-vs-pocketbase.json" },
              "pocketbase": { "value": 13.1, "source": "published", "note": "pb docs" },
              "firebase": { "value": null, "source": "na", "note": "managed" } } } ],
  "scaleCurves": [ { "key": "rss_vs_tenants", "label": "RSS vs tenants", "unit": "MiB",
    "x": [200,1000,10000], "series": {
      "grobase-nano": { "y": [2.1,2.3,2.6], "source": "modeled", "note": "extrapolation" } } } ] }
EOF
docker run --rm -v "$PWD/scripts/bench":/b -v /tmp:/tmp -w /b \
  public.ecr.aws/docker/library/node:22-bookworm \
  node compare-report.mjs --data /tmp/sample.json --out /tmp/cmpout
# expect: exit 0, /tmp/cmpout/{index.html,report.md,charts/*.svg}
```

## Committing the charts (the wiki report renders them)

`make bench-compare` writes to `artifacts/bench/compare/` which is **git-ignored** (the whole
`artifacts/` tree is, by METHOD.md — it can carry scratch keys). The committed report
`wiki/competitive-benchmark-report.md` therefore embeds a **tracked snapshot** of the SVGs under
`wiki/assets/competitive-benchmark/`. After regenerating, refresh that snapshot so the committed
report stays in sync:

```bash
make bench-compare
cp artifacts/bench/compare/charts/*.svg ../../wiki/assets/competitive-benchmark/
```

The `compare-data.json` dataset and `compare-report.mjs` generator ARE tracked (they are the source of
truth); the rendered SVGs are a convenience snapshot for GitHub rendering.
