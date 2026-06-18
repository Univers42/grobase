FROM alpine:3.20

ARG FLYCTL_VERSION=0.4.55
ARG FLYCTL_ARCHIVE=flyctl_${FLYCTL_VERSION}_Linux_x86_64.tar.gz

RUN apk add --no-cache \
    bash \
    bind-tools \
    ca-certificates \
    coreutils \
    curl \
    git \
    gzip \
    jq \
    nodejs \
    npm \
    openssl \
    tar \
    && update-ca-certificates \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/superfly/flyctl/releases/download/v${FLYCTL_VERSION}/${FLYCTL_ARCHIVE}" -o "/tmp/${FLYCTL_ARCHIVE}" \
    && curl --proto '=https' --tlsv1.2 -fsSL "https://github.com/superfly/flyctl/releases/download/v${FLYCTL_VERSION}/flyctl_${FLYCTL_VERSION}_checksums.txt" -o /tmp/flyctl_checksums.txt \
    && cd /tmp \
    && grep "${FLYCTL_ARCHIVE}" flyctl_checksums.txt | sha256sum -c - \
    && tar -xzf "/tmp/${FLYCTL_ARCHIVE}" -C /usr/local/bin flyctl \
    && chmod +x /usr/local/bin/flyctl \
    && ln -sf /usr/local/bin/flyctl /usr/local/bin/fly \
    && rm -f "/tmp/${FLYCTL_ARCHIVE}" /tmp/flyctl_checksums.txt

COPY infrastructure/services/fly/scripts/entrypoint.sh /usr/local/bin/fly-entrypoint
RUN chmod +x /usr/local/bin/fly-entrypoint

WORKDIR /workspace

ENTRYPOINT ["fly-entrypoint"]
CMD ["bash"]