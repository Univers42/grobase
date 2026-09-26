# Single-Machine grobase backend on fly.io: Docker-in-Docker host that pulls the
# published GHCR images and runs the curated query-edition stack via compose.
# (A fly Machine is a real Firecracker VM, so an inner dockerd works — proven.)
FROM docker:27-dind

RUN apk add --no-cache bash openssl git curl jq docker-cli-compose postgresql-client

COPY boot.sh /usr/local/bin/boot.sh
COPY compose.override.yml /opt/compose.override.yml
RUN chmod +x /usr/local/bin/boot.sh

# Docker-in-Docker: boot.sh starts dockerd inside the fly Firecracker VM, which needs
# root; the stack's own containers keep their own USERs.
# nosemgrep: dockerfile.security.missing-user-entrypoint.missing-user-entrypoint -- dockerd needs root (DinD)
ENTRYPOINT ["/usr/local/bin/boot.sh"]
