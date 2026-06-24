# Frontend Breach 010: Untrusted Variable Echoed in CI Workflow

Date: 2026-05-27
Severity: Low (defense-in-depth)
Status: Fixed

## Affected Files

- `.github/workflows/ci-cd.yml` (job step `Check production HTTPS transport policy`, line 390)

## Evidence

SonarQube raised a security hotspot (`bash:S6588` family) on:

```bash
echo "$insecure_urls"
```

`$insecure_urls` is populated a few lines above by:

```bash
insecure_urls="$(grep -RInE "$clear_text_pattern" .github Back View \
  docker-compose*.yml infrastructure .env*.example 2>/dev/null \
  | grep -vE "localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]" || true)"
```

i.e. the variable holds **arbitrary content extracted from any tracked file** matched by `grep`.

## Exploit Scenario

Because Bash's `echo` interprets backslash escape sequences on some
implementations (depending on `xpg_echo`, `/bin/sh` symlink target, `set -o posix`,
or use of `-e`), a malicious or accidentally-tampered file containing:

- ANSI terminal control sequences (`\033[2J`, cursor-move, color codes) → could
  obscure CI log output, hide other matches, or make the failure appear to
  pass on visual inspection;
- Backslash-tab-newline tricks → could split a single line into multiple,
  making automated log parsing surface only the safe-looking head;
- Carriage-return overwrites → could mask the offending URL in the rendered
  GitHub Actions log.

None of these are remote-code-execution, but they can defeat the intent of
the security gate (alerting humans/CI to insecure URLs) by **suppressing or
misrepresenting the evidence**.

## Root Cause

`echo "$var"` is not a safe primitive for arbitrary content. POSIX leaves
backslash handling implementation-defined; Bash with `xpg_echo` on (or `sh`
linked to `dash`) interprets escapes silently.

## Repair

Replaced with the POSIX-safe `printf '%s\n'` form:

```bash
if [ -n "$insecure_urls" ]; then
  echo "Production public origins must use https://"
  # printf '%s\n' is safer than echo: it does not interpret backslash
  # escapes in $insecure_urls (which comes from arbitrary file content
  # surfaced by grep). Satisfies SonarQube hotspot bash:S6588.
  printf '%s\n' "$insecure_urls"
  exit 1
fi
```

`printf '%s\n'` writes the byte string verbatim, regardless of shell flavor
or environment options. Terminal escape sequences would now appear as their
literal characters (e.g., `^[[2J`) in the CI log, preserving evidence.

## Verification

1. `grep -nE 'echo[[:space:]]+"\$' .github/workflows/ci-cd.yml` should return
   only the trusted `echo "$!" > postman-api.pid` line (PID is shell-internal,
   never user-controlled).
2. SonarQube re-scan should clear the `bash:S6588` hotspot for this line.
3. The job behavior is unchanged for normal inputs — both `echo` and
   `printf '%s\n'` produce the same output for plain ASCII without escapes.

## Residual Risk

Other `echo` usages in shell scripts under `scripts/` and `infrastructure/`
have not been audited in this pass. They should be reviewed in a sweep if
Sonar flags additional hotspots; the standard remediation is the same
(`echo "$var"` → `printf '%s\n' "$var"` when `$var` is arbitrary content).

## Related

- Rule reference: SonarQube `bash:S6588` — *"Replace `echo` with `printf` when
  echoing variables that may contain backslash escape sequences."*
- Similar concerns: ShellCheck `SC2059` (printf format injection — orthogonal,
  ensure the format string is constant, which it is here: `'%s\n'`).
- See also: `security-breach-frontend-006-ci-security-gates.md` for the
  broader CI security-gate hardening this complements.
