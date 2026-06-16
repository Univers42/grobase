#!/usr/bin/env bash
# Shared bench-workload plumbing: provision a bench tenant, drive Kong
# /data/v1, and build the canonical bench_items working set (METHOD.md).
# Requires lib-bench.sh + scripts/verify/lib-live-tenant.sh sourced first and
# live_tenant_provision already called (LIVE_* vars exported).

bw_gw_query() { # $1 operation-json → body+code
	curl -s -w ' HTTP%{http_code}' -X POST "${LIVE_KONG_URL}/data/v1/query" \
		-H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${LIVE_TENANT_API_KEY}" \
		-H 'Content-Type: application/json' \
		-d "{\"db_id\":\"${LIVE_TENANT_DB_ID}\",\"operation\":$1}"
}

bw_ddl() { # $1 ddl-json
	curl -s -w ' HTTP%{http_code}' -X POST "${LIVE_KONG_URL}/data/v1/schema/ddl" \
		-H "apikey: ${LIVE_ANON_APIKEY}" -H "X-Baas-Api-Key: ${LIVE_TENANT_API_KEY}" \
		-H 'Content-Type: application/json' \
		-d "{\"db_id\":\"${LIVE_TENANT_DB_ID}\",\"ddl\":$1}"
}

# Create (idempotently: drop a leftover first) + seed the canonical 500-row
# working set. $1 = table name (default bench_items).
bw_setup_table() {
	local table="${1:-bench_items}" out chunk i n items
	local create='{"op":"create_table","table":"'"${table}"'","columns":[
  {"name":"id","normalized_type":"text","nullable":false},
  {"name":"name","normalized_type":"text","nullable":true},
  {"name":"grp","normalized_type":"text","nullable":true},
  {"name":"val","normalized_type":"integer","nullable":true}],"primary_key":["id"]}'
	out="$(bw_ddl "${create}")"
	if echo "${out}" | grep -q 'HTTP409'; then
		bw_ddl "{\"op\":\"drop_table\",\"table\":\"${table}\"}" >/dev/null
		out="$(bw_ddl "${create}")"
	fi
	echo "${out}" | grep -q 'HTTP20[01]' || { echo "create_table failed: ${out}" >&2; return 1; }

	# /data/v1 batch contract: sub-operations ride in `data` (operation.rs
	# batch_items), each carrying its own `resource`.
	for chunk in $(seq 0 49); do
		items=""
		for i in $(seq 0 9); do
			n=$((chunk * 10 + i))
			items+="{\"op\":\"insert\",\"resource\":\"${table}\",\"data\":{\"id\":\"s${n}\",\"name\":\"seed-${n}\",\"grp\":\"g$((n % 8))\",\"val\":$((n % 1000))}},"
		done
		out="$(bw_gw_query "{\"op\":\"batch\",\"resource\":\"${table}\",\"data\":[${items%,}]}")"
		echo "${out}" | grep -q 'HTTP20[01]' || { echo "seed batch ${chunk} failed: ${out}" >&2; return 1; }
	done
	return 0
}

bw_drop_table() { # $1 table
	bw_ddl "{\"op\":\"drop_table\",\"table\":\"${1:-bench_items}\"}" >/dev/null 2>&1 || true
}
