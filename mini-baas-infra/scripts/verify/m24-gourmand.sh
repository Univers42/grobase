#!/usr/bin/env bash
# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    m24-gourmand.sh                                    :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/06/10 00:00:00 by dlesieur          #+#    #+#              #
#    Updated: 2026/06/10 00:00:00 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #
#
# M24 umbrella — the Vite & Gourmand client onboarding, end to end:
#   1. platform capabilities (tenant_owned + TLS)        m24-tenant-owned.sh
#   2. the live client mount (schema/reads/writes/gating) m24-gourmand-mount.sh
#   3. the org workspace (staff mirrored, pages, wiki, chat)
# The Playwright staff e2e is a separate make target (gourmand-sim pattern):
#   docker compose --profile testing run --rm playground-simulation \
#     node scripts/gourmand-staff-verification.mjs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
REPO_ROOT="$(cd "${INFRA_ROOT}/../../.." && pwd)"

cyan()  { printf '\033[0;36m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
fail()  { red "[M24] FAIL: $*"; exit 1; }
step()  { cyan "[M24] ${*}"; }
pass()  { green "[M24] PASS: ${*}"; }

step "1/3 platform capabilities (tenant_owned + TLS)"
bash "${SCRIPT_DIR}/m24-tenant-owned.sh" || fail "tenant-owned gate failed"

step "2/3 live client mount"
bash "${SCRIPT_DIR}/m24-gourmand-mount.sh" || fail "mount gate failed"

step "3/3 org workspace (people, pages, wiki, chat)"
PEOPLE_ENV="${REPO_ROOT}/tools/seeds/.gourmand-people.env"
[[ -f "${PEOPLE_ENV}" ]] || fail "no .gourmand-people.env — run make gourmand-people"
# Source ONLY the scalar header vars: the GOURMAND_CRED_* lines carry
# pipe-delimited values (a@b|uuid|Name|role|pw) that bash would run as pipes.
eval "$(grep -E '^GOURMAND_(ORG_WORKSPACE_ID|OWNER_UUID|OWNER_EMAIL|STAFF_COUNT)=' "${PEOPLE_ENV}")"
WS="${GOURMAND_ORG_WORKSPACE_ID:?}"
PSQL() { docker exec -i track-binocle-postgres-1 psql -U postgres -d postgres -tAc "$1"; }
members=$(PSQL "SELECT count(*) FROM public.osionos_workspace_members WHERE workspace_id='${WS}'")
[[ "${members}" -ge "${GOURMAND_STAFF_COUNT:-1}" ]] \
  || fail "expected ≥${GOURMAND_STAFF_COUNT} workspace members, found ${members}"
pages=$(PSQL "SELECT count(*) FROM public.osionos_pages WHERE workspace_id='${WS}' AND content::text LIKE '%baas:%'")
[[ "${pages}" -ge 9 ]] || fail "expected ≥9 live database pages, found ${pages}"
wikis=$(PSQL "SELECT count(*) FROM public.osionos_pages WHERE workspace_id='${WS}' AND surface='wiki'")
[[ "${wikis}" -ge 2 ]] || fail "expected ≥2 wiki pages, found ${wikis}"
channels=$(PSQL "SELECT count(*) FROM public.osionos_channels WHERE workspace_id='${WS}'")
[[ "${channels}" -ge 5 ]] || fail "expected ≥5 chat channels, found ${channels}"
pii=$(PSQL "SELECT visibility FROM public.osionos_pages WHERE workspace_id='${WS}' AND title='Delivery Map'")
[[ "${pii}" == "private" ]] || fail "Delivery Map (PII) must be private, is '${pii}'"
pass "workspace: ${members} members, ${pages} live pages, ${wikis} wikis, ${channels} channels, PII page private"

green "[M24] OK — Vite & Gourmand onboarding verified (platform + mount + workspace)"
