#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#  m265-make-all-rootless.sh — `make all` deploys on a 42 seat                 #
#                                                                              #
#  A fresh clone could not start there. Rootless Docker refused every CPU      #
#  limit, promtail mounted a /var/lib/docker that does not exist, and the      #
#  WAF restarted for ever because its key was granted to the wrong gid.        #
#  Hermetic: docker and make are stubbed, nothing is started.                  #
#                                                                              #
# **************************************************************************** #
set -uo pipefail
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$ROOT" || exit 1
rc=0
ok() { printf '  ✓ %s\n' "$1"; }
fail() {
  printf '[M265] FAIL — %s\n' "$1"
  rc=1
}
check() { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1: got '$2', expected '$3'"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# ── CPU limits ───────────────────────────────────────────────────────────────
sh scripts/ops/no-cpu-limits.sh "$T/o.yml"
limited=$(grep -hE '^    cpus:' orchestrators/compose/base/*.yml | wc -l)
lifted=$(grep -c '^    cpus: 0$' "$T/o.yml")
check "every service with a cpus: limit is lifted" "$lifted" "$limited"
check "and nothing but cpus is touched" "$(grep -cE 'mem_limit|memswap' "$T/o.yml")" 0
python3 -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); sys.exit(0 if d["services"] else 1)' "$T/o.yml" 2>/dev/null &&
  ok "the override is valid YAML" || printf '  - skip: no pyyaml to parse the override\n'
cat >"$T/bin/docker" <<STUB
#!/bin/sh
case "\$*" in
"info --format {{.CPUCfsQuota}} {{.DockerRootDir}}") printf 'false /goinfre/u/docker\n' ;;
esac
STUB
chmod +x "$T/bin/docker"
plan=$(env PATH="$T/bin:$PATH" DOCKER_HOST=unix:///run/user/9/docker.sock make --no-print-directory -p up 2>/dev/null)
check "a Docker with no CPU quota gets the override" "$(printf '%s\n' "$plan" | grep -m1 -c '^DC .*no-cpu-limits')" 1
paths=$(env PATH="$T/bin:$PATH" DOCKER_HOST=unix:///run/user/9/docker.sock make --no-print-directory -s --eval 'show:;@echo $(DOCKER_CONTAINERS_DIR) $(DOCKER_SOCKET)' show 2>/dev/null)
check "promtail mounts where this Docker keeps things" "$paths" "/goinfre/u/docker/containers /run/user/9/docker.sock"
paths=$(env PATH="$T/bin:$PATH" DOCKER_HOST= make --no-print-directory -s --eval 'show:;@echo $(DOCKER_SOCKET)' show 2>/dev/null)
check "a rootful host keeps the default socket" "$paths" "/var/run/docker.sock"

# ── the WAF's key ────────────────────────────────────────────────────────────
cat >"$T/bin/docker" <<STUB
#!/bin/sh
case "\$*" in
"info --format {{.SecurityOptions}}") printf '[name=seccomp name=rootless]\n' ;;
*chgrp*) echo docker-rung >>"$T/rungs" ;;
esac
STUB
cat >"$T/bin/setfacl" <<STUB
#!/bin/sh
echo setfacl-rung >>"$T/rungs"
STUB
chmod +x "$T/bin/setfacl"
eval "$(awk '/^grant_waf_read_in_docker\(\) \{/{p=1} p{print} /^grant_waf_read\(\) \{/{q=1} q && /^\}/{exit}' scripts/certs/generate-localhost-cert.sh)"
WAF_TLS_GID=101 CERT_DIR=$T PATH="$T/bin:$PATH" grant_waf_read "$T/key"
check "rootless: the grant happens inside the user namespace" "$(cat "$T/rungs")" docker-rung

# ── make all ─────────────────────────────────────────────────────────────────
check "make all is the whole product by default" \
  "$(make --no-print-directory -n all 2>/dev/null | grep -c 'PACKAGE=max ADDONS="observability engines"')" 1
check "PACKAGE= on the command line narrows it" \
  "$(make --no-print-directory -n all PACKAGE=pro 2>/dev/null | grep -c 'PACKAGE="pro"')" 1

mkdir -p "$T/repo/scripts/ops"
cp scripts/ops/deploy-all.sh "$T/repo/scripts/ops/"
printf '#!/bin/sh\nexit 0\n' >"$T/repo/scripts/ops/set-seeds.sh"
cat >"$T/bin/make" <<STUB
#!/bin/sh
echo "\$2" >>"$T/steps"
[ "\$2" != "\${STUB_FAIL:-}" ]
STUB
cat >"$T/bin/docker" <<'STUB'
#!/bin/sh
exit 0
STUB
chmod +x "$T/bin/make" "$T/bin/docker"
deploy() { env PATH="$T/bin:$PATH" "$@" bash "$T/repo/scripts/ops/deploy-all.sh" >/dev/null 2>&1; }
deploy
check "a fresh clone makes its .env and certificate before anything needs them" \
  "$(tr '\n' ' ' <"$T/steps")" "env certs pull up health "
touch "$T/repo/.env"
mkdir -p "$T/repo/certs"
touch "$T/repo/certs/localhost.pem"
: >"$T/steps"
deploy
check "a clean run succeeds" "$?" 0
check "in order: images, stack, verdict" "$(tr '\n' ' ' <"$T/steps")" "pull up health "
: >"$T/steps"
deploy STUB_FAIL=health
check "an unhealthy stack fails make all" "$?" 1
: >"$T/steps"
deploy STUB_FAIL=pull
check "no registry: it builds instead" "$(tr '\n' ' ' <"$T/steps")" "pull build up health "
: >"$T/steps"
deploy BUILD=1
check "BUILD=1 builds on purpose" "$(tr '\n' ' ' <"$T/steps")" "build up health "

# ── the seeds ────────────────────────────────────────────────────────────────
eval "$(grep '^ENGINE_CREDENTIALS=' scripts/ops/set-seeds.sh)"
eval "$(awk '/^merge_secrets\(\) \{/{p=1} p{print} p && /^\}/{exit}' scripts/ops/set-seeds.sh)"
printf 'JWT_SECRET=here\nPOSTGRES_PASSWORD=here\nMSSQL_SA_PASSWORD=here\n' >"$T/g"
printf 'JWT_SECRET=vault\nPOSTGRES_PASSWORD=vault\nPGRST_DB_URI=vault\nVAULT_ENC_KEY=vault\n' >"$T/v"
merge_secrets "$T/g" "$T/v" "$T/m"
check "the keys the rows were written under come from the vault" "$(grep -c '^JWT_SECRET=vault$\|^VAULT_ENC_KEY=vault$' "$T/m")" 2
check "an engine keeps the password its volume took" "$(grep -c '^POSTGRES_PASSWORD=here$' "$T/m")" 1
check "a URL embedding the vault's password stays out" "$(grep -c '^PGRST_DB_URI=' "$T/m")" 0
check "a key only this stack has stays" "$(grep -c '^MSSQL_SA_PASSWORD=here$' "$T/m")" 1
check "no credentials: make all still deploys" \
  "$(
    env FT_CREDENTIALS="$T/none" bash scripts/ops/set-seeds.sh --auto >/dev/null 2>&1
    echo $?
  )" 0
check "... and a direct call says so" \
  "$(
    env FT_CREDENTIALS="$T/none" bash scripts/ops/set-seeds.sh >/dev/null 2>&1
    echo $?
  )" 1
check "no bare docker cp into a container: it carries a group rootless Docker does not map" \
  "$(grep -cE '^[^#]*docker cp "' scripts/ops/vault-restore.sh)" 0
check "vault-restore runs under this script's cycle" "$(grep -c '^if ! SKIP_STACK_CYCLE=1' scripts/ops/set-seeds.sh)" 1

[ "$rc" = 0 ] && printf '[M265] PASS\n' || printf '[M265] FAIL\n'
exit "$rc"
