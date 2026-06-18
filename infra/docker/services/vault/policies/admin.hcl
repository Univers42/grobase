# File: docker/services/vault/policies/admin.hcl
# Full administrative access — used ONLY by vault-init bootstrap.

path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
