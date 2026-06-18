# File: docker-bake.hcl
# Parallel BuildKit bake configuration for mini-BaaS
# Builds all 7 NestJS apps from the unified src/Dockerfile + WAF/Vault custom images

group "default" {
  targets = [
    "outbox-relay", "mongo-api", "query-router",
    "email-service", "storage-router",
    "permission-engine", "schema-service",
    "analytics-service", "gdpr-service", "newsletter-service",
    "ai-service", "log-service", "session-service",
    "waf", "vault", "postgres"
  ]
}

group "apps" {
  targets = [
    "outbox-relay", "mongo-api", "query-router",
    "email-service", "storage-router",
    "permission-engine", "schema-service",
    "analytics-service", "gdpr-service", "newsletter-service",
    "ai-service", "log-service", "session-service"
  ]
}

group "infra" {
  targets = ["waf", "vault", "postgres"]
}

# Images ship on Docker Hub (public by default on push — no visibility
# dance); the buildx layer cache stays on GHCR, which CI logs into anyway
# and end users never touch.
variable "REGISTRY" {
  default = "docker.io/dlesieur"
}

variable "CACHE_REGISTRY" {
  default = "ghcr.io/univers42/mini-baas"
}

variable "TAG" {
  default = "latest"
}

# ─── Base target for NestJS apps (shared Dockerfile) ──────────────
target "nestjs-base" {
  context    = "./src"
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
}

# (the TS adapter-registry was retired — its successor adapter-registry-go
# ships inside the Go control-plane image; outbox-relay had been left out)
target "outbox-relay" {
  inherits   = ["nestjs-base"]
  args       = { APP = "outbox-relay" }
  tags       = ["${REGISTRY}/mini-baas-outbox-relay:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:outbox-relay"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:outbox-relay,mode=max"]
}

target "mongo-api" {
  inherits   = ["nestjs-base"]
  args       = { APP = "mongo-api" }
  tags       = ["${REGISTRY}/mini-baas-mongo-api:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:mongo-api"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:mongo-api,mode=max"]
}

target "query-router" {
  inherits   = ["nestjs-base"]
  args       = { APP = "query-router" }
  tags       = ["${REGISTRY}/mini-baas-query-router:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:query-router"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:query-router,mode=max"]
}

target "email-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "email-service" }
  tags       = ["${REGISTRY}/mini-baas-email-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:email-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:email-service,mode=max"]
}

target "storage-router" {
  inherits   = ["nestjs-base"]
  args       = { APP = "storage-router" }
  tags       = ["${REGISTRY}/mini-baas-storage-router:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:storage-router"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:storage-router,mode=max"]
}

target "permission-engine" {
  inherits   = ["nestjs-base"]
  args       = { APP = "permission-engine" }
  tags       = ["${REGISTRY}/mini-baas-permission-engine:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:permission-engine"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:permission-engine,mode=max"]
}

target "schema-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "schema-service" }
  tags       = ["${REGISTRY}/mini-baas-schema-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:schema-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:schema-service,mode=max"]
}

target "analytics-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "analytics-service" }
  tags       = ["${REGISTRY}/mini-baas-analytics-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:analytics-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:analytics-service,mode=max"]
}

target "gdpr-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "gdpr-service" }
  tags       = ["${REGISTRY}/mini-baas-gdpr-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:gdpr-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:gdpr-service,mode=max"]
}

target "newsletter-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "newsletter-service" }
  tags       = ["${REGISTRY}/mini-baas-newsletter-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:newsletter-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:newsletter-service,mode=max"]
}

target "ai-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "ai-service" }
  tags       = ["${REGISTRY}/mini-baas-ai-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:ai-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:ai-service,mode=max"]
}

target "log-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "log-service" }
  tags       = ["${REGISTRY}/mini-baas-log-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:log-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:log-service,mode=max"]
}

target "session-service" {
  inherits   = ["nestjs-base"]
  args       = { APP = "session-service" }
  tags       = ["${REGISTRY}/mini-baas-session-service:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:session-service"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:session-service,mode=max"]
}

# ─── Infrastructure images ───────────────────────────────────────
target "waf" {
  context    = "./docker/services/waf"
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["${REGISTRY}/mini-baas-waf:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:waf"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:waf,mode=max"]
}

target "vault" {
  context    = "./docker/services/vault"
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["${REGISTRY}/mini-baas-vault:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:vault"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:vault,mode=max"]
}

target "postgres" {
  context    = "./docker/services/postgres"
  dockerfile = "Dockerfile"
  platforms  = ["linux/amd64", "linux/arm64"]
  tags       = ["${REGISTRY}/mini-baas-postgres:${TAG}"]
  cache-from = ["type=registry,ref=${CACHE_REGISTRY}/cache:postgres"]
  cache-to   = ["type=registry,ref=${CACHE_REGISTRY}/cache:postgres,mode=max"]
}
