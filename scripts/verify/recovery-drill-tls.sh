#!/usr/bin/env bash
# Per-run secrets and CA-signed peer certificates; never used against deployed services.
create_drill_tls() {
  local directory="$1" peer
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=recovery-drill-ca \
    -keyout "$directory/ca.key" -out "$directory/ca.crt" >/dev/null 2>&1
  for peer in pg store; do
    mkdir -p "$directory/$peer"
    chmod 755 "$directory/$peer"
    openssl req -new -newkey rsa:2048 -nodes -subj "/CN=$peer" \
      -keyout "$directory/$peer/private.key" -out "$directory/$peer/request.csr" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nextendedKeyUsage=serverAuth\n' "$peer" >"$directory/$peer/extensions"
    openssl x509 -req -days 1 -in "$directory/$peer/request.csr" \
      -CA "$directory/ca.crt" -CAkey "$directory/ca.key" -CAcreateserial \
      -extfile "$directory/$peer/extensions" -out "$directory/$peer/public.crt" >/dev/null 2>&1
    chmod 644 "$directory/$peer/private.key" "$directory/$peer/public.crt"
    rm "$directory/$peer/request.csr" "$directory/$peer/extensions"
  done
  mkdir -p "$directory/client/CAs"
  cp "$directory/ca.crt" "$directory/client/CAs/drill.crt"
  printf 'POSTGRES_PASSWORD=%s\n' "$(openssl rand -hex 32)" >"$directory/pg.env"
  printf 'MINIO_ROOT_USER=%s\nMINIO_ROOT_PASSWORD=%s\n' \
    "$(openssl rand -hex 12)" "$(openssl rand -hex 32)" >"$directory/store.env"
  printf '%s\n' 'sed -i "s/^host[[:space:]]/hostssl /" "$PGDATA/pg_hba.conf"' >"$directory/require-tls.sh"
  chmod 644 "$directory/require-tls.sh" "$directory/ca.crt"
}
