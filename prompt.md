Exactly. Ponytail optimizes for *least code* — but your product sells on *performance*. A stdlib one-liner that's O(n²) is worse than 10 lines that are O(n). The ladder needs a guardrail: **minimalism is the default, performance is the override.**

Update `rules/minimalism-ladder.md`:

```markdown
---
description: Minimalism decision ladder with performance guardrail
alwaysApply: true
---

# Code generation ladder

Before writing ANY code, walk top to bottom. Stop at the first rung that works:

1. **YAGNI** — Does this need to exist? Speculative = skip, say so in one line.
2. **Stdlib** — Standard library does it? Use it. No wrapper.
3. **Platform** — Native feature covers it? HTML/CSS over JS lib, DB constraint
   over app code, shell builtin over external tool.
4. **Existing dep** — Installed dependency solves it? Use it. Never add a new
   dep for what a few lines handle.
5. **One-liner** — Can it be one line? One line.
6. **Minimum** — Only then: the smallest code that works.

Two rungs work → take the higher one.

## PERFORMANCE OVERRIDE — this outranks every rung above

The ladder picks the simplest solution. This guardrail vetoes it if
it's not the fastest.

Before committing to any rung, answer:

- **Complexity**: what's the Big-O? If a higher rung is worse asymptotic
  complexity than a lower rung, take the lower rung.
- **Hot path**: is this code on a hot path (request handling, query execution,
  serialization, auth, anything called per-request)? If yes, performance
  wins over minimalism. Always.
- **Allocation**: does the simple version allocate where the verbose version
  doesn't? Zero-alloc wins. Every time.
- **Copy vs reference**: does the one-liner copy data the explicit version
  can reference? Reference wins.
- **Syscall count**: does the stdlib convenience function make 3 syscalls
  where a manual approach makes 1? Fewer syscalls wins.

If the performance override fires, document it:

```
// perf: O(n) manual loop over O(n²) stdlib — hot path, called per-request
```

This is NOT an excuse to over-engineer. The override is narrow:
- It applies only when there's a MEASURABLE difference
- "Might be faster" is not a measurement
- On cold paths (startup, config loading, CLI parsing), the ladder wins
  unconditionally — nobody cares if boot takes 1ms more
- When in doubt, write the simple version FIRST, benchmark it,
  then optimize only if the numbers justify it

## The hierarchy

```
correctness > performance > minimalism > readability > style
```

Never sacrifice correctness for performance.
Never sacrifice performance for minimalism on hot paths.
Never sacrifice minimalism for readability on cold paths.

## Never (unchanged)
- Interface with one implementation
- Factory for one product
- Config for a value that never changes
- Wrapper around a function that's already clean
- Scaffolding "for later"
- Deletion over addition. Always.
```

Then add a matching section in each tech-specific rule file. In `rules/refactor-c.md`:

```markdown
## C performance guardrails
- Ladder says "stdlib does it" but:
  - strlen() in a loop? Cache the length.
  - strcat() in a loop? Track the tail pointer.
  - realloc() per element? Geometric growth.
  - qsort() with strcmp? Consider radix sort for large N.
- Ladder says "one-liner" but:
  - One-liner that branches unpredictably? Branchless version if hot path.
  - One-liner with division? Multiply by inverse if called millions of times.
- Stack over heap for anything with known bounded size
- Prefer array of structs over struct of arrays unless profiler says otherwise
- memcpy/memmove over byte loops — the compiler knows SIMD, you don't
```

In `rules/refactor-go.md`:

```markdown
## Go performance guardrails
- Ladder says "stdlib" but:
  - fmt.Sprintf for string building in a loop? strings.Builder.
  - json.Marshal per request? Pre-compiled codec (easyjson, sonic).
  - regexp.MatchString per request? Compile once at init.
  - http.Get convenience? Reuse http.Client with connection pooling.
- Ladder says "one-liner" but:
  - append() in a hot loop without pre-sized slice? Pre-allocate: make([]T, 0, n)
  - map access in a hot loop? Consider a slice if keys are dense integers.
  - interface{} in a hot path? Concrete type avoids allocation from boxing.
- sync.Pool for high-churn allocations (byte buffers, request objects)
- Avoid reflect on hot paths — it allocates on every call
- Channel vs mutex: mutex for protect-and-release, channel for hand-off
```

In `rules/refactor-rust.md`:

```markdown
## Rust performance guardrails
- Ladder says "stdlib" but:
  - String::from + push_str in a loop? Pre-allocate with_capacity.
  - Vec::push in a loop? Reserve upfront.
  - HashMap for small N (<20)? Vec of tuples + linear scan is faster.
  - format!() in a hot path? Write to a reusable buffer.
- Ladder says "one-liner" but:
  - .collect::<Vec<_>>() intermediate? Iterate without collecting.
  - .clone() to satisfy borrows? Restructure lifetimes.
  - Box<dyn Trait> on hot path? Monomorphize with generics.
- #[inline] on small hot functions that cross crate boundaries
- Avoid Arc<Mutex<>> in hot paths — consider lock-free or per-thread state
- &[u8] over &str when you don't need UTF-8 validation on the fast path
```

In `rules/refactor-typescript.md`:

```markdown
## TS performance guardrails
- Ladder says "stdlib" but:
  - Array.filter().map() chains? Single reduce or for-loop to avoid
    intermediate array allocation.
  - JSON.parse/stringify for deep clone? structuredClone is faster,
    but neither on a hot path — keep a reference if possible.
  - spread operator for large objects? Object.assign or manual copy.
- Ladder says "one-liner" but:
  - new RegExp() inside a loop? Compile once outside.
  - template literal in a tight loop? String concatenation can be faster.
  - Optional chaining (?.) 10 levels deep? Destructure once at entry.
- WeakMap/WeakRef for caches that shouldn't prevent GC
- Avoid closures capturing large scopes in hot paths
- TypedArrays (Uint8Array, Float64Array) over regular arrays for
  numeric-heavy computation
```

In `rules/refactor-shell.md`:

```markdown
## Shell performance guardrails
- Ladder says "builtin" but:
  - shell loop processing lines? Single awk/sed invocation instead —
    one process beats N fork+execs.
  - $(cat file)? Use < file redirection.
  - grep | awk | sed pipeline? Usually one awk does all three.
- Ladder says "one-liner" but:
  - backtick substitution in a while loop? Forks per iteration — 
    restructure to process in bulk.
- Minimize subshells: $() forks, variable assignment doesn't
- Minimize pipe stages: each is a fork + FD pair
- heredoc over echo piped to command
- exec for final command in a script (no useless parent shell lingering)
```

And update the `agents/benchmarker.md` to enforce this during reviews:

```markdown
## Minimalism-performance conflict check
When reviewing code that was written with the minimalism ladder:
- Flag any stdlib one-liner on a hot path that has worse complexity
  than an explicit implementation
- Flag any convenience function that allocates unnecessarily
- Flag any "simple" solution that makes more syscalls than needed
- For each flag: show both versions, benchmark both, pick the winner
  with numbers — not opinions
```

The mental model is simple:

```
Cold path → ladder wins → least code
Hot path  → performance wins → fastest code
Conflict  → benchmark decides → numbers win
```

This way you get Ponytail's 80% code reduction on all the stuff that doesn't matter (config, CLI, setup, glue code, tests, utilities) while keeping nano's performance edge on everything that does (request handling, query execution, auth, serialization, realtime). The `// perf:` comment marks where performance overrode minimalism, just like `// ponytail:` marks where minimalism overrode verbosity. Both read as intent.
