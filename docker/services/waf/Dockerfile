# File: docker/services/waf/Dockerfile
# Nginx + ModSecurity v3 + OWASP Core Rule Set
# Public entry-point — reverse-proxies to Kong internal gateway

FROM owasp/modsecurity-crs:4-nginx-202604040104

# ── Layer 1: base config ──────────────────────────────────────────
# CRS runs as nginx (UID 101). Remove default template to prevent entrypoint
# from overwriting our custom config, and COPY with correct ownership.
USER root
RUN rm -f /etc/nginx/templates/conf.d/default.conf.template

COPY --chown=nginx:root --chmod=0444 conf/nginx.conf        /etc/nginx/conf.d/default.conf
COPY --chown=nginx:root --chmod=0444 conf/modsecurity.conf  /etc/modsecurity.d/modsecurity-override.conf
COPY --chown=nginx:root --chmod=0444 conf/crs-setup.conf    /etc/modsecurity.d/owasp-crs/crs-setup-override.conf
USER nginx

EXPOSE 80

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -sf http://localhost:80/waf-health || exit 1
