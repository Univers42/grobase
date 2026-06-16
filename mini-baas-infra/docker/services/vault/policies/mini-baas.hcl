# File: docker/services/vault/policies/mini-baas.hcl
# Read-only access to the mini-BaaS secret tree.
# Bound to service AppRoles.

path "secret/data/mini-baas/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/mini-baas/*" {
  capabilities = ["list"]
}

path "secret/data/track-binocle/*" {
  capabilities = ["read", "list"]
}

path "secret/metadata/track-binocle/*" {
  capabilities = ["list"]
}
