---
globs: ["**/*.go"]
description: Go refactoring rules
---

# Go Refactoring

## Idioms

- Max 40 lines per function — and ≤25 lines per function body, ≤5 funcs per file (repo norm)
- Accept interfaces, return structs
- Errors are values — handle them, don't panic
- No init() unless absolutely forced by a dependency
- **No globals — inject dependencies.** No package-level `var`. See [`no-globals.md`](no-globals.md): sentinel errors → const error types, regexes → struct fields / `sync.OnceValue`, lookup tables → switch funcs, mutable state → DI. The *only* permitted package var is a `//go:embed` target.
- Receiver name: one or two letters, consistent across methods
- Context is always the first parameter
- ≤4 parameters per function (`refactor-common.md`), **excluding** a leading `ctx context.Context` — ctx is mandated plumbing, not a data input, so it does not count. The method receiver does not count either. Beyond 4 data params, group cohesive args into a struct (reuse an existing domain type if its fields match; otherwise a small param struct). A `type … struct` declaration is not a `func`, so adding a param struct never affects the ≤5-funcs-per-file count.

## Package design

- **Package by domain, not by type.** No `utils`/`common`/`helpers`/`shared`/`misc` catch-alls. See [`go-package-design.md`](go-package-design.md): one package = one capability; ~80% unexported / 20% exported; one source of truth per concept.

## Hexagonal architecture (project convention)

- Ports (interfaces) in the domain package
- Adapters implement ports, never imported by domain
- No infrastructure types in domain signatures

## After refactoring

- `go vet ./...` — zero issues
- `golangci-lint run` — zero issues
- `go test -race ./...` — zero failures
- Check goroutine leaks with goleak in tests

## Go-specific ladder extensions

- Rung 2: `strings`, `strconv`, `slices`, `maps` before any import.
- Rung 3: `net/http` before gin/chi/echo; `database/sql` before an ORM.
- Rung 4: a stdlib interface fits (`io.Reader`, `fmt.Stringer`)? Use it — don't define your own.
- No constructor function if the zero value is usable.
- No getter/setter if the field can be public.

## Go performance guardrails

- Ladder says "stdlib" but:
  - `fmt.Sprintf` for string building in a loop? `strings.Builder`.
  - `json.Marshal` per request? A pre-compiled codec (easyjson, sonic).
  - `regexp.MatchString` per request? Compile once at init.
  - `http.Get` convenience? Reuse an `http.Client` with connection pooling.
- Ladder says "one-liner" but:
  - `append()` in a hot loop without a pre-sized slice? `make([]T, 0, n)`.
  - map access in a hot loop? A slice if keys are dense integers.
  - `interface{}` on a hot path? A concrete type avoids boxing allocation.
- `sync.Pool` for high-churn allocations (byte buffers, request objects).
- Avoid `reflect` on hot paths — it allocates on every call.
- Channel vs mutex: mutex to protect-and-release, channel for hand-off.
