# syntax=docker/dockerfile:1
# File: docker/services/trino/Dockerfile

FROM trinodb/trino:467
COPY --link conf/config.properties /etc/trino/config.properties
EXPOSE 8080
USER trino
