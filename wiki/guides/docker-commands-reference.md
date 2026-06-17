# Docker Commands Reference

A concise reference for every Docker and Compose command used in day-to-day development of the mini-baas stack. Commands are grouped by purpose. Prefer the Make targets in all automated and scripted workflows; use raw `docker compose` only during interactive debugging.

---

## Table of Contents

- [Stack Lifecycle](#stack-lifecycle)
- [Image Lifecycle](#image-lifecycle)
- [Registry Workflows](#registry-workflows)
- [Health and Testing](#health-and-testing)
- [Direct Compose Commands](#direct-compose-commands)
- [Kong Config Validation](#kong-config-validation)
- [Diagnostics](#diagnostics)
- [Cleanup](#cleanup)

---

## Stack Lifecycle

These targets manage the full Compose stack from a single command:

```bash
make baas                  # Start the entire BaaS stack (core profile)
make compose-up            # Start with default profile
make compose-ps            # Show running containers and their health
make compose-logs          # Follow logs for all services
make compose-logs SERVICE=kong   # Follow logs for a single service
make compose-restart       # Restart all containers
make compose-down          # Stop and remove containers (keep volumes)
make compose-down-volumes  # Stop, remove containers, and delete volumes
make turn-off              # Graceful shutdown of all processes
```

---

## Image Lifecycle

Build, inspect, and manage local images:

```bash
make docker-build          # Build all custom images (mini-baas/<service>:<tag>)
make docker-build-kong     # Build the Kong image specifically
make docker-images         # List mini-baas images
make docker-clean          # Remove dangling and unused images
```

---

## Registry Workflows

Tag and push images to a container registry:

```bash
make docker-tag   REGISTRY=localhost:5000 IMAGE_TAG=latest
make docker-push  REGISTRY=localhost:5000 IMAGE_TAG=latest
make build-and-push REGISTRY=localhost:5000 IMAGE_TAG=latest
```

---

## Health and Testing

```bash
make compose-health       # Hit health endpoints for core services
make tests                # Run the full integration suite (phases 1–13)
make test-phase1          # Run a single phase
make test-phase13         # Run another single phase
```

---

## Direct Compose Commands

Use these only when debugging outside Make targets:

```bash
# Start and stop
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml down
docker compose -f docker-compose.yml down -v

# Logs and status
docker compose -f docker-compose.yml ps
docker compose -f docker-compose.yml logs -f --tail=100
docker compose -f docker-compose.yml logs -f --tail=100 kong

# Pull upstream images
docker compose -f docker-compose.yml pull
```

---

## Kong Config Validation

Always validate after editing `docker/services/kong/conf/kong.yml`:

```bash
docker run --rm -e KONG_DATABASE=off \
  -e KONG_DECLARATIVE_CONFIG=/tmp/kong.yml \
  -v "$PWD/docker/services/kong/conf/kong.yml:/tmp/kong.yml:ro" \
  kong:3.8 kong config parse /tmp/kong.yml
```

A successful parse prints:

```
parse successful
```

---

## Diagnostics

```bash
# Resource usage
docker system df
docker image ls
docker volume ls
docker container ls -a
```

---

## Cleanup

For destructive cleanup, always prefer the Make targets. They ensure the stack shuts down and resources are freed in a safe order:

```bash
make fclean                # Full clean — stops stack, removes volumes, prunes images
make docker-clean          # Remove dangling images only
```
