# Read-only access to Track Binocle managed environment secrets.

path "secret/data/track-binocle/env/*" {
  capabilities = ["read"]
}

path "secret/metadata/track-binocle/env/*" {
  capabilities = ["read", "list"]
}