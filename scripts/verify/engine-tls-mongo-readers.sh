#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    engine-tls-mongo-readers.sh                        :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/10/30 21:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/10/30 21:00:00 by dlesieur         ###   ########.fr       #
#                                                                              #
# **************************************************************************** #
#
# Sourced by engine-tls-mongo-clients.sh (needs its pass/fail). The ts-base anchor hands
# MONGO_URI, plaintext, to services the mongo overlay does not restate (ADR 0025, devil
# re-rule N1–N8). That is safe only while none of them reads it, so this proves it from the
# source tree: the only MONGO_URI reader is libs/database/src/mongo (MongoService), wired by
# MongoModule. For each pass-through app's src/:
#   N1 no MongoModule / MongoService identifier (the @mini-baas/database barrel is fine:
#      six of them import its Postgres* half);
#   N2 no MONGO_URI token at all (config.get, process.env, a string);
#   N3 no mongodb driver import or new MongoClient, except schema-service's tenant engine
#      (its DSN comes from the request, M10), which must not name MONGO_URI either;
# and N4 no src/libs module outside libs/database/src/mongo names MongoModule/MongoService.
# mr_self_test (N6) runs the census on stub trees: a clean one passes, each mutant fails.
#
# Caveat: a grep census, not a module graph. A dynamic require/import, a string-built name
# (process.env['MONGO' + '_URI'], moduleRef.get('Mongo' + 'Service')) or a reader in a file
# type other than .ts/.mts/.cts/.js/.mjs/.cjs is missed: it under-reports. A spec file or a
# comment naming MongoService is counted: it over-reports, which only turns the gate red.

MR_INCLUDES=(--include='*.ts' --include='*.mts' --include='*.cts' --include='*.js' --include='*.mjs' --include='*.cjs'
  --exclude-dir=node_modules --exclude-dir=dist)
MR_ENGINE="schema-service/src/engines/mongo-schema.engine.ts"
MR_NAMES='\bMongo(Module|Service)\b'
MR_DRIVER="from[[:space:]]*['\"]mongodb(/[^'\"]*)?['\"]|(require|import)[[:space:]]*\([[:space:]]*['\"]mongodb(/[^'\"]*)?['\"]|\bnew[[:space:]]+MongoClient\b|\bMongoClient\.connect\b"

# file:line of each hit of ERE $1 under the dirs that follow, never the line itself.
mr_hits() {
  local re="$1"
  shift
  { grep -rnE "${MR_INCLUDES[@]}" -e "${re}" -- "$@" || true; } | cut -d: -f1,2
}

# $1 rule, $2 newline-separated hits under root $3: fail naming the files, relative to $3.
mr_rule() {
  local hits="${2//"$3/"/}"
  [[ -z "${hits}" ]] || fail "$1: ${hits//$'\n'/ }"
}

# $1 a source root holding apps/ and libs/, rest the apps (build.args.APP) to census.
mongo_readers_census() {
  local root="$1" app dir n=0
  shift
  for app in "$@"; do
    dir="${root}/apps/${app}/src"
    [[ -n "${app}" && -d "${dir}" ]] || fail "N5: no apps/${app:-<unset APP>}/src for a pass-through service"
    mr_rule "N1: ${app} names MongoModule/MongoService" "$(mr_hits "${MR_NAMES}" "${dir}")" "${root}"
    mr_rule "N2: ${app} reads MONGO_URI" "$(mr_hits '\bMONGO_URI\b' "${dir}")" "${root}"
    mr_rule "N3: ${app} opens its own mongodb client" \
      "$(mr_hits "${MR_DRIVER}" "${dir}" | grep -v "^${root}/apps/${MR_ENGINE}:" || true)" "${root}"
    n=$((n + 1))
  done
  [[ ! -f "${root}/apps/${MR_ENGINE}" ]] ||
    mr_rule "N3: the tenant engine names MONGO_URI" "$(mr_hits '\bMONGO_URI\b' "${root}/apps/${MR_ENGINE}")" "${root}"
  [[ -d "${root}/libs" ]] || fail "N4: no libs/ under the census root"
  mr_rule "N4: a lib outside libs/database/src/mongo names MongoModule/MongoService" \
    "$(mr_hits "${MR_NAMES}" "${root}/libs" | grep -v "^${root}/libs/database/src/mongo/" || true)" "${root}"
  MR_COUNT="${n}"
}

# A stub source tree under $1: app "svc", a clean tenant engine, a lib and the mongo lib.
mr_stub() {
  mkdir -p "$1/apps/svc/src" "$1/apps/schema-service/src/engines" "$1/libs/health/src" "$1/libs/database/src/mongo"
  printf "import { PostgresService } from '@mini-baas/database';\n" >"$1/apps/svc/src/app.module.ts"
  printf "import { MongoClient } from 'mongodb';\nconst c = new MongoClient(tenantDsn);\n" >"$1/apps/${MR_ENGINE}"
  printf "export const ok = 1;\n" >"$1/libs/health/src/index.ts"
  printf "export class MongoService { uri = cfg.get('MONGO_URI'); }\n" >"$1/libs/database/src/mongo/mongo.service.ts"
}

# N6: $1 a scratch dir. Each mutant must fail for its own rule; the clean stub must pass.
mr_self_test() {
  local base="$1/clean" out case want apps file line app_list
  mr_stub "${base}"
  (mongo_readers_census "${base}" svc schema-service) >/dev/null 2>&1 || fail "N6: the clean stub tree is red"
  while IFS='|' read -r case want apps file line; do
    rm -rf "$1/m"
    cp -r "${base}" "$1/m"
    printf '%s\n' "${line}" >>"$1/m/${file}"
    read -ra app_list <<<"${apps}"
    out="$( (mongo_readers_census "$1/m" "${app_list[@]}") 2>&1 >/dev/null)" && fail "N6: mutant ${case} stayed green"
    [[ "${out}" == *"${want}"* ]] || fail "N6: mutant ${case} failed for another reason"
  done <<'EOF'
MongoModule import|N1: svc names|svc schema-service|apps/svc/src/app.module.ts|import { MongoModule } from '@mini-baas/database';
config.get MONGO_URI|N2: svc reads|svc schema-service|apps/svc/src/app.module.ts|const u = config.get('MONGO_URI');
process.env MONGO_URI|N2: svc reads|svc|apps/svc/src/app.module.ts|const u = process.env.MONGO_URI;
own driver|N3: svc opens|svc|apps/svc/src/app.module.ts|import { MongoClient } from 'mongodb';
require driver|N3: svc opens|svc|apps/svc/src/app.module.ts|const { MongoClient } = require('mongodb');
driver beside the engine|N3: schema-service opens|svc schema-service|apps/schema-service/src/app.module.ts|const c = new MongoClient(x);
engine reads MONGO_URI|N3: the tenant engine|svc|apps/schema-service/src/engines/mongo-schema.engine.ts|const d = process.env.MONGO_URI;
lib wires MongoModule|N4:|svc|libs/health/src/index.ts|import { MongoModule } from '@mini-baas/database';
EOF
  (mongo_readers_census "${base}" svc missing-app) >/dev/null 2>&1 && fail "N6: an unmappable app stayed green"
  pass "N6: the census is red on 8 stub mutants (N1–N4) and an unmappable app (N5), green on the clean stub"
}
