#!/bin/sh
# **************************************************************************** #
#                                                                              #
#  preflight-production.sh — refuse a production env file that still carries   #
#  dev credentials or dev security settings                                    #
#                                                                              #
#  WHY                                                                         #
#    Base compose keeps well-known dev fallbacks (POSTGRES_PASSWORD:-postgres, #
#    MINIO_ROOT_PASSWORD:-minioadmin, VAULT_ENC_KEY:-0123..., ...) so a fresh  #
#    clone renders and boots without a generated .env (byte-parity). Nothing   #
#    checked an env file before a production bring-up. An absent or empty key  #
#    is not safe either: compose's `:-` then falls back to the dev default.    #
#                                                                              #
#  WHAT IT CHECKS (names only; no value is printed, not even under sh -x:      #
#  values live inside awk and never enter a shell variable)                    #
#    credentials  set, resolvable, not a known dev default or placeholder;     #
#                 DSN passwords URL-decoded first; JWT_SECRET >= 32 chars,     #
#                 VAULT_ENC_KEY >= 16. Engines you do not run still need a     #
#                 value: this script cannot know which planes you start.       #
#    optional     PG_BACKUP_DATABASE_URL, DATA_PLANE_OUTBOX_DSN and            #
#    DSNs         OUTBOX_MONGO_URL: checked like a credential when set. Unset, #
#                 compose builds them from DATABASE_URL, POSTGRES_PASSWORD or  #
#                 MONGO_INITDB_ROOT_PASSWORD, which the check above requires.  #
#    settings     GOTRUE_MAILER_AUTOCONFIRM=false, SMTP_HOST not mailpit,      #
#                 API_EXTERNAL_URL / GOTRUE_SITE_URL not localhost,            #
#                 ENGINE_BIND_ADDR not a wildcard, SERVICE_TOKEN_MODE=hmac.    #
#                 REALTIME_NAMESPACE_FALLBACK other than deny only WARNS: deny #
#                 closes realtime to GoTrue-session clients until a namespace  #
#                 minting path exists.                                         #
#    advisories   WARN only: SECURITY_MODE not max, API_KEY_ABAC_ENABLED off,  #
#                 DATA_PLANE_RATELIMIT_BACKEND not redis. Each is an owner     #
#                 decision with a cost this file cannot check.                 #
#    containers   CONTAINER_NO_NEW_PRIVILEGES other than true is refused       #
#                 unless CONTAINER_NO_NEW_PRIVILEGES_ACK=1 (then it warns).    #
#  The file is PARSED, never sourced, with compose .env rules: `export `       #
#  prefix, quotes, unquoted ` #` comments, last assignment wins. A value       #
#  holding `${`, `$(` or an unquoted `$NAME` cannot be resolved here, and      #
#  UNKNOWN = FAIL.                                                             #
#                                                                              #
#  SCOPE: this FILE only. Host-shell env vars override .env during compose     #
#  interpolation, so a PASS covers the file, not the running environment.      #
#  Wired: make prod-up (refuses); make cloud-up, deploy/fly/boot.sh (warn;     #
#  PREFLIGHT_ENFORCE=1 refuses). Not go-live.sh: the Helm chart takes no       #
#  compose .env. Gate: m194-preflight-production.sh.                           #
#                                                                              #
#  Usage: sh scripts/ops/preflight-production.sh [ENV_FILE]    (default .env)  #
#  Exit:  0 PASS · 1 offenders named · 2 unreadable file or internal error     #
# **************************************************************************** #
set -eu

readonly PREFLIGHT_AWK='
# BEGIN loads the checked credentials, the optional DSNs, the DSN keys, the
# minimum lengths and the exact dev defaults (base compose fallbacks,
# config.env, common stock). An optional DSN left unset is safe: compose then
# builds it from DATABASE_URL, POSTGRES_PASSWORD or MONGO_INITDB_ROOT_PASSWORD.
BEGIN {
	ncred = split("POSTGRES_PASSWORD AUTHENTICATOR_PASSWORD DATABASE_URL PGRST_DB_URI ADAPTER_REGISTRY_DATABASE_URL JWT_SECRET ADAPTER_REGISTRY_SERVICE_TOKEN ANON_KEY SERVICE_ROLE_KEY KONG_PUBLIC_API_KEY KONG_SERVICE_API_KEY MINIO_ROOT_USER MINIO_ROOT_PASSWORD VAULT_ENC_KEY MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD LOG_STREAM_TOKEN INTERNAL_IDENTITY_HMAC_KEYS PG_META_DB_PASSWORD SECRET_KEY_BASE MYSQL_ROOT_PASSWORD MYSQL_PASSWORD MARIADB_ROOT_PASSWORD MARIADB_PASSWORD MSSQL_SA_PASSWORD", CRED, " ")
	nopt = split("PG_BACKUP_DATABASE_URL DATA_PLANE_OUTBOX_DSN OUTBOX_MONGO_URL", OPT, " ")
	DSN["DATABASE_URL"] = DSN["PGRST_DB_URI"] = DSN["ADAPTER_REGISTRY_DATABASE_URL"] = 1
	for (i = 1; i <= nopt; i++) DSN[OPT[i]] = 1
	MINLEN["JWT_SECRET"] = 32
	MINLEN["VAULT_ENC_KEY"] = 16
	n = split("postgres mongo minioadmin authenticator mysqlroot mariaroot mini_baas_pw mssql_strong!pass1 0123456789abcdef0123456789abcdef dev-service-token-change-me dev-vault-enc-key super-secret-key-base changeme change-me secret password admin root", t, " ")
	for (i = 1; i <= n; i++) DEV[t[i]] = 1
	NONE = "\001"
}

{ record($0) }

# record stores one KEY=VALUE line the way compose reads .env; last one wins.
function record(line,   eq, key, raw) {
	sub(/\r$/, "", line)
	sub(/^[ \t]+/, "", line)
	sub(/^export[ \t]+/, "", line)
	eq = index(line, "=")
	if (eq == 0 || substr(line, 1, 1) == "#") return
	key = substr(line, 1, eq - 1)
	sub(/[ \t]+$/, "", key)
	if (key !~ /^[A-Za-z_][A-Za-z0-9_.]*$/) return
	raw = substr(line, eq + 1)
	sub(/^[ \t]+/, "", raw)
	VAL[key] = unquote(raw)
	UNRES[key] = interpolates(raw)
}

# unquote returns what compose sees: quoted text up to its closing quote, or
# unquoted text minus a trailing ` #` comment and blanks.
function unquote(raw,   q) {
	q = substr(raw, 1, 1)
	if (q == "\047") return upto(substr(raw, 2), "\047", 0)
	if (q == "\"") return upto(substr(raw, 2), "\"", 1)
	if (q == "#") return ""
	sub(/[ \t]+#.*$/, "", raw)
	sub(/[ \t]+$/, "", raw)
	return raw
}

# upto returns s up to the first quote q; esc makes a backslash escape a char.
function upto(s, q, esc,   i, c, out) {
	out = ""
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (esc && c == "\\" && i < length(s)) { i++; out = out substr(s, i, 1); continue }
		if (c == q) break
		out = out c
	}
	return out
}

# interpolates is 1 when compose would expand part of the value, which this
# parser cannot resolve; single quotes keep a bare $NAME literal.
function interpolates(raw,   v) {
	v = unquote(raw)
	if (v ~ /\$[{(]/) return 1
	return substr(raw, 1, 1) != "\047" && v ~ /\$[A-Za-z_]/
}

# is_dev_default is 1 for a shipped default or placeholder, any letter case.
function is_dev_default(v,   l) {
	l = tolower(v)
	if (l ~ /change-?me|change_me|your-super-secret|super-secret|placeholder/) return 1
	return (l in DEV)
}

# dsn_password returns the URL-decoded password of scheme://user:pass@host,
# cut at the LAST @ since a raw @ may sit in the password; NONE if absent.
function dsn_password(v,   c, rest, at, ui) {
	c = index(v, "://")
	if (c == 0) return NONE
	rest = substr(v, c + 3)
	sub(/\?.*$/, "", rest)
	at = last_at(rest)
	if (at == 0) return NONE
	ui = substr(rest, 1, at - 1)
	c = index(ui, ":")
	return c ? url_decode(substr(ui, c + 1)) : NONE
}

# last_at returns the position of the last @ in s, 0 when there is none.
function last_at(s,   p, n) {
	n = 0
	while ((p = index(substr(s, n + 1), "@")) > 0) n += p
	return n
}

# url_decode turns %XX escapes back into bytes; a malformed escape stays.
function url_decode(s,   out, i, h) {
	out = ""
	for (i = 1; i <= length(s); i++) {
		h = (substr(s, i, 1) == "%") ? hex2(substr(s, i + 1, 2)) : -1
		if (h >= 0) { out = out sprintf("%c", h); i += 2 } else out = out substr(s, i, 1)
	}
	return out
}

# hex2 returns the value of a two-digit hex string, -1 if it is not one.
function hex2(xx,   a, b) {
	if (length(xx) < 2) return -1
	a = index("0123456789abcdef", tolower(substr(xx, 1, 1))) - 1
	b = index("0123456789abcdef", tolower(substr(xx, 2, 1))) - 1
	return (a < 0 || b < 0) ? -1 : a * 16 + b
}

# flag names an offender once; its value never reaches the output.
function flag(k, why) {
	if (k in FLAGGED) return
	FLAGGED[k] = 1
	bad++
	printf "  ✗ %s — %s\n", k, why
}

# warn prints an advisory line that leaves the exit code alone.
function warn(k, why) {
	printf "  ! %s — %s\n", k, why
}

# check_cred fails a credential that is unset (compose would use its dev
# default or run without it), unresolvable, a known default, or too short.
function check_cred(k,   v) {
	if (!(k in VAL) || VAL[k] == "") return flag(k, "missing or empty (compose falls back to a dev default or runs without it)")
	if (UNRES[k]) return flag(k, "unresolvable interpolation, cannot verify (UNKNOWN = FAIL)")
	v = (k in DSN) ? dsn_password(VAL[k]) : VAL[k]
	if (v == NONE || v == "") return flag(k, "DSN carries no password")
	if (is_dev_default(v)) return flag(k, ((k in DSN) ? "DSN password is a " : "") "known dev default or placeholder")
	if ((k in MINLEN) && length(v) < MINLEN[k]) flag(k, "shorter than " MINLEN[k] " characters")
}

# check_opt runs check_cred on an optional DSN only when it is set and
# non-empty; otherwise compose falls back to a required key checked above.
function check_opt(k) {
	if ((k in VAL) && VAL[k] != "") check_cred(k)
}

# setting returns the effective lowercased value of k (compose default dflt
# when unset or empty), or NONE after flagging an unresolvable one.
function setting(k, dflt) {
	if (UNRES[k]) { flag(k, "unresolvable interpolation, cannot verify (UNKNOWN = FAIL)"); return NONE }
	return tolower(((k in VAL) && VAL[k] != "") ? VAL[k] : dflt)
}

# is_local is 1 when a URL or host points at the loopback.
function is_local(v) {
	return v ~ /localhost|127\.0\.0\.1|\[::1\]/
}

# check_settings enforces the production values of the non-secret settings.
function check_settings(   v) {
	v = setting("GOTRUE_MAILER_AUTOCONFIRM", "false")
	if (v != NONE && v != "false") flag("GOTRUE_MAILER_AUTOCONFIRM", "must be false (signups confirm by mail)")
	v = setting("SMTP_HOST", "mailpit")
	if (v != NONE && (v == "mailpit" || is_local(v))) flag("SMTP_HOST", "must name a real mail relay (mailpit swallows confirmation mail)")
	v = setting("API_EXTERNAL_URL", "http://localhost:8000/auth/v1")
	if (v != NONE && is_local(v)) flag("API_EXTERNAL_URL", "points at localhost (GoTrue issuer and OAuth callbacks)")
	v = setting("GOTRUE_SITE_URL", "http://localhost:5173")
	if (v != NONE && is_local(v)) flag("GOTRUE_SITE_URL", "points at localhost (confirmation and reset links)")
	v = setting("ENGINE_BIND_ADDR", "127.0.0.1")
	if (v == "0.0.0.0" || v == "::" || v == "[::]") flag("ENGINE_BIND_ADDR", "publishes every engine port on all interfaces")
	v = setting("SERVICE_TOKEN_MODE", "hmac")
	gsub(/[ \t]/, "", v)
	if (v != NONE && v != "hmac") flag("SERVICE_TOKEN_MODE", "must be hmac (per-request signed service auth)")
	v = setting("REALTIME_NAMESPACE_FALLBACK", "permissive")
	if (v != NONE && v != "deny") warn("REALTIME_NAMESPACE_FALLBACK", "not deny, so namespace-less tokens get all-access (advisory until GoTrue sessions carry namespaces)")
	check_advisories()
}

# check_advisories warns on the hardening an owner opts into: each needs
# something this file cannot see (Vault-backed credentials and engine TLS for
# max, ABAC roles for api keys, redis for more than one data-plane replica).
function check_advisories(   v) {
	v = setting("SECURITY_MODE", "baseline")
	if (v != NONE && v != "max") warn("SECURITY_MODE", "not max: engine TLS and Vault-backed credentials are not required")
	v = setting("API_KEY_ABAC_ENABLED", "0")
	if (v != NONE && v !~ /^(1|true|yes|on)$/) warn("API_KEY_ABAC_ENABLED", "off: an api key with admin scope bypasses ABAC masks and conditions")
	v = setting("DATA_PLANE_RATELIMIT_BACKEND", "memory")
	if (v != NONE && v != "redis") warn("DATA_PLANE_RATELIMIT_BACKEND", "not redis: each data-plane replica enforces its own copy of a tenant limit")
}

# check_no_new_privileges refuses CONTAINER_NO_NEW_PRIVILEGES set to anything
# docker reads as other than true (it turns the setting off on every service,
# m208) unless CONTAINER_NO_NEW_PRIVILEGES_ACK=1 records that it is deliberate.
function check_no_new_privileges(   v) {
	v = setting("CONTAINER_NO_NEW_PRIVILEGES", "true")
	if (v == NONE || v ~ /^(true|1|t)$/) return
	if (setting("CONTAINER_NO_NEW_PRIVILEGES_ACK", "0") == "1") return warn("CONTAINER_NO_NEW_PRIVILEGES", "off (acknowledged): setuid binaries and file capabilities work again in every container")
	flag("CONTAINER_NO_NEW_PRIVILEGES", "not true: every container may gain privileges through setuid or file caps (CONTAINER_NO_NEW_PRIVILEGES_ACK=1 to accept)")
}

# END runs every check and prints the verdict; the exit code is the result.
END {
	for (i = 1; i <= ncred; i++) check_cred(CRED[i])
	for (i = 1; i <= nopt; i++) check_opt(OPT[i])
	check_settings()
	check_no_new_privileges()
	if (bad) {
		printf "FAIL — %d offender(s); values are never printed.\n", bad
		print "Engine root credentials apply at first boot only: rotate live volumes with scripts/ops/reconcile-credentials.sh."
		exit 1
	}
	print "PASS"
}
'

# usage prints the command line and the exit codes.
usage() {
  printf 'usage: sh scripts/ops/preflight-production.sh [ENV_FILE]   (default .env)\n'
  printf 'exit:  0 PASS, 1 offenders named, 2 unreadable file or internal error\n'
}

# main feeds ENV_FILE to awk on stdin (never sourced, never an awk operand, so
# a name holding `=` or a leading `-` cannot be misread) and returns its verdict.
main() {
  case "${1:-}" in -h | --help) usage && return 0 ;; esac
  env_file="${1:-.env}"
  if [ ! -f "$env_file" ] || [ ! -r "$env_file" ]; then
    printf 'preflight-production: %s is missing or unreadable\n' "$env_file" >&2
    return 2
  fi
  printf 'preflight-production: %s\n' "$env_file"
  printf '  scope: this FILE only; host-shell env vars override it during compose interpolation.\n'
  rc=0
  awk "$PREFLIGHT_AWK" <"$env_file" || rc=$?
  [ "$rc" -le 1 ] && return "$rc"
  printf 'preflight-production: internal error (awk exit %s)\n' "$rc" >&2
  return 2
}

main "$@"
