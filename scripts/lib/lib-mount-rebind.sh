#!/bin/sh
# lib-mount-rebind.sh — the jq program and the runner for cmd/mount-rebind, shared by
# grobase-import-rebind.sh and vault-restore.sh. POSIX sh: the second one is not bash.
# Needs GROBASE_ROOT. Secrets travel in pipes: never argv, never a file, never printed.

GO_IMAGE="${GO_IMAGE:-golang:1.26-bookworm}"

# rebind_redis_program — the jq defs that find the target redis' login for the config.
# Caveat: the login is read from a `--requirepass` argument, else from the one
# redis://USER:PASSWORD@redis userinfo the running containers' *REDIS*_URL values carry
# (the REDIS_ACL overlay, docs/adr/0028-g5-redis-acl-stage1.md). A password set in a mounted
# redis.conf is missed, the DSN is rebound without one, and the mount fails AUTH: the
# data-plane probe after apply is what catches it. The userinfo is taken as written, not
# percent-decoded (generate-env.sh mints hex). Under stage 1 a DSN with no user is kept as
# it is and still opens, as the passwordless default user.
rebind_redis_program() {
  cat <<'JQ'
def redis_logins: [.[].Config.Env // [] | .[]
  | capture("^[A-Z_]*REDIS[A-Z_]*_URL=rediss?://(?<user>[^:@/]+):(?<password>[^@/]+)@(redis|mini-baas-redis):")]
  | unique;
def redis_login($ra): ($ra | index(["--requirepass"])) as $i | redis_logins as $l
  | if $i then {user: "", password: $ra[$i + 1]}
    elif ($l | length) > 1 then error("target: \($l | length) distinct redis logins in running containers' *REDIS*_URL; need at most 1")
    elif ($l | length) == 1 then $l[0]
    elif ($ra | index(["/usr/local/bin/redis-acl.sh"])) then error("target: redis runs the ACL overlay but no running container's *REDIS*_URL carries its login")
    else {user: "", password: ""} end;
JQ
}

# rebind_config_program — jq over `docker inspect` of every running target container → the
# mount-rebind config line. Refuses unless exactly one VAULT_ENC_KEY is in use there. With
# $envkey true, no container carrying one means the source env file's key is the target's
# too: vault-restore runs with the engines alone, and that file is the target's own .env.
# jq arguments: --rawfile srcenv FILE, --argjson envkey true|false.
rebind_config_program() {
  rebind_redis_program
  cat <<'JQ'
def env($c): (map(select(.Name == "/" + $c)) | .[0].Config.Env // [])
  | map(capture("^(?<key>[^=]+)=(?<value>.*)$")) | from_entries;
def running($c): any(.[]; .Name == "/" + $c);
def target($e; $s; $h; $p; $u; $pw): {engine: $e, schemes: $s, hosts: $h, port: $p, user: $u, password: $pw};
def srckey: $srcenv | split("\n") | map(select(startswith("VAULT_ENC_KEY="))) | (.[0] // "")
  | sub("^VAULT_ENC_KEY="; "") | sub("^[\"']|[\"']$"; ""; "g");
([.[].Config.Env // [] | .[] | select(startswith("VAULT_ENC_KEY="))] | unique) as $keys
| if ($keys | length) > 1 or (($keys | length) == 0 and ($envkey | not)) then error("target: \($keys | length) distinct VAULT_ENC_KEY values in running containers; need exactly 1") else . end
| if srckey == "" then error("source env file has no VAULT_ENC_KEY") else . end
| . as $all
| (map(select(.Name == "/mini-baas-redis")) | .[0].Args // []) as $ra
| {source_key: srckey, target_key: (if ($keys | length) == 1 then ($keys[0] | sub("^VAULT_ENC_KEY="; "")) else srckey end),
   targets: [
    (env("mini-baas-postgres") | select(.POSTGRES_PASSWORD) | target("postgresql"; ["postgres", "postgresql"]; ["postgres", "mini-baas-postgres"]; 5432; .POSTGRES_USER // "postgres"; .POSTGRES_PASSWORD)),
    (env("mini-baas-mysql") | select(.MYSQL_PASSWORD) | target("mysql"; ["mysql", "mariadb"]; ["mysql", "mini-baas-mysql"]; 3306; .MYSQL_USER; .MYSQL_PASSWORD)),
    (env("mini-baas-mongo") | select(.MONGO_INITDB_ROOT_PASSWORD) | target("mongodb"; ["mongodb"]; ["mongo", "mini-baas-mongo"]; 27017; .MONGO_INITDB_ROOT_USERNAME; .MONGO_INITDB_ROOT_PASSWORD)),
    (env("mini-baas-mssql") | select(.MSSQL_SA_PASSWORD // .SA_PASSWORD) | target("mssql"; ["mssql", "sqlserver"]; ["mssql", "mini-baas-mssql"]; 1433; "sa"; .MSSQL_SA_PASSWORD // .SA_PASSWORD)),
    ($all | select(running("mini-baas-redis")) | redis_login($ra)
      | target("redis"; ["redis"]; ["redis", "mini-baas-redis"]; 6379; .user; .password))
  ]}
JQ
}

# rebind_run — build and run cmd/mount-rebind in the Go toolchain image; stdin and
# stdout pass straight through, and `exec` keeps its exit status.
rebind_run() {
  docker run -i --rm -v "${GROBASE_ROOT}/src/control-plane:/src:ro" -w /src \
    -v mini-baas-gomod:/go/pkg/mod -v mini-baas-gobuild:/root/.cache/go-build -e CGO_ENABLED=0 \
    "$GO_IMAGE" sh -c 'go build -o /tmp/mount-rebind ./cmd/mount-rebind >&2 && exec /tmp/mount-rebind'
}
