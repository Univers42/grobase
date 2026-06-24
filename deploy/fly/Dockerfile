# Single-Machine grobase backend on fly.io: Docker-in-Docker host that pulls the
# published GHCR images and runs the curated query-edition stack via compose.
# (A fly Machine is a real Firecracker VM, so an inner dockerd works — proven.)
FROM docker:27-dind

RUN apk add --no-cache bash openssl git curl jq docker-cli-compose postgresql-client

COPY boot.sh /usr/local/bin/boot.sh
COPY compose.override.yml /opt/compose.override.yml
RUN chmod +x /usr/local/bin/boot.sh

ENTRYPOINT ["/usr/local/bin/boot.sh"]
