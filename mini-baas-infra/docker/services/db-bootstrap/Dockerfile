# syntax=docker/dockerfile:1
# File: docker/services/db-bootstrap/Dockerfile
#
# Self-built bootstrap client. db-bootstrap is an INIT container: it waits for the
# postgres service, runs db-bootstrap.psql, and exits. It only needs a psql client +
# pg_isready + a shell — NOT a full Postgres engine. So we drop the 438 MB
# pgvector/pgvector:pg16 image for Alpine + postgresql-client (~20 MB). The `vector`
# extension itself lives in the postgres SERVER image, not here.
FROM alpine:3.21
RUN apk add --no-cache postgresql16-client
# psql is backward-compatible with the postgres 16 server; sh comes from busybox.
