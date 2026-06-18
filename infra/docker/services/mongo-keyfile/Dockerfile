# syntax=docker/dockerfile:1
# File: docker/services/mongo-keyfile/Dockerfile
#
# Self-built keyfile generator. The mongo-keyfile init container only runs
# `openssl rand -base64 756 > /etc/mongo/rs-keyfile` (+ chmod/chown) once and exits —
# it does NOT need MongoDB. Drop the 874 MB mongo:7 image for Alpine + openssl + bash
# (the compose entrypoint uses `bash -c`). ~12 MB.
FROM alpine:3.21
RUN apk add --no-cache openssl bash
