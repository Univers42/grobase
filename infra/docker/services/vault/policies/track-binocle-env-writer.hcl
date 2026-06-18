# Read/write access to Track Binocle managed environment secrets.

path "secret/data/track-binocle/env/*" {
  capabilities = ["create", "read", "update"]
}

path "secret/metadata/track-binocle/env/*" {
  capabilities = ["read", "list"]
}