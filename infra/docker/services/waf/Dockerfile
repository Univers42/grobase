# File: docker/services/waf/Dockerfile
# Nginx + ModSecurity v3 + OWASP Core Rule Set
# Public entry-point — reverse-proxies to Kong internal gateway

FROM owasp/modsecurity-crs:4-nginx-202604040104 AS waf_runtime

# ── Layer 1: base config ──────────────────────────────────────────
# CRS runs as nginx (UID 101). Remove default template to prevent entrypoint
# from overwriting our custom config, and COPY with correct ownership.
USER root
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && apt-get purge -y --auto-remove \
   '*-dev' \
   curl \
   fontconfig-config \
   fonts-dejavu-core \
   fonts-dejavu-mono \
   krb5-multidev \
   libfontconfig1 \
   libgd3 \
   libgeoip1t64 \
   libgdbm-compat4t64 \
   libgdbm6t64 \
   libheif-plugin-dav1d \
   libheif-plugin-libde265 \
   libheif1 \
   libimagequant0 \
   libio-pty-perl \
   libipc-run-perl \
   libperl5.40 \
   libtime-duration-perl \
   libtimedate-perl \
   libxslt1.1 \
   linux-libc-dev \
   nginx-module-geoip \
   nginx-module-image-filter \
   nginx-module-njs \
   nginx-module-xslt \
   perl \
   perl-modules-5.40 \
 && apt-get install -y --no-install-recommends libcurl3t64-gnutls libmaxminddb0 \
 && apt-get purge -y --auto-remove >/dev/null \
 && (dpkg --purge --force-all perl-base >/dev/null 2>&1 || true) \
 && (dpkg --purge --force-all bash libtinfo6 ncurses-base ncurses-bin >/dev/null 2>&1 || true) \
 && rm -rf /usr/share/java /usr/share/maven-repo \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /etc/nginx/templates/conf.d/default.conf.template \
 && mkdir -p /etc/nginx/modsecurity.d
COPY --chown=nginx:root --chmod=0444 conf/nginx.conf        /etc/nginx/conf.d/default.conf
COPY --chown=nginx:root --chmod=0644 conf/modsecurity.conf  /etc/modsecurity.d/modsecurity-override.conf
COPY --chown=nginx:root --chmod=0644 conf/crs-setup.conf    /etc/modsecurity.d/owasp-crs/crs-setup-override.conf
RUN chown -R nginx:root /etc/nginx /etc/modsecurity.d /var/cache/nginx /var/log/nginx /var/run \
 && chmod -R g=u /etc/nginx /etc/modsecurity.d /var/cache/nginx /var/log/nginx /var/run
USER nginx

EXPOSE 80 443

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD sh -c 'grep -qi ":0050 .* 0A" /proc/net/tcp || exit 1'

FROM scratch

COPY --from=waf_runtime / /

# MODSEC_TAG is referenced below as an ESCAPED literal (\${MODSEC_TAG}) — Docker does
# NOT expand it at build time; envsubst expands it at runtime. So this is not a real
# same-ENV self-reference, and DL3044 is a false positive here.
# hadolint ignore=DL3044
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LD_LIBRARY_PATH=/lib:/usr/lib:/usr/local/lib \
  NGINX_HOME=/etc/nginx \
  BACKEND=http://localhost:80 \
  CORS_HEADER_403_ALLOW_ORIGIN=* \
  CORS_HEADER_403_ALLOW_METHODS="GET, POST, PUT, DELETE, OPTIONS" \
  CORS_HEADER_403_CONTENT_TYPE=text/html \
  CORS_HEADER_403_MAX_AGE=3600 \
  CORS_HEADER_ACCESS_CONTROL_ALLOW_HEADERS=* \
  NGINX_ENVSUBST_OUTPUT_DIR=/etc/nginx \
  NGINX_X_FORWARDED_PORT='\$server_port' \
  NGINX_X_FORWARDED_PROTO='\$scheme' \
  PORT=8080 \
  PROXY_SSL=off \
  PROXY_SSL_CERT_FILE=/etc/nginx/conf/proxy.crt \
  PROXY_SSL_CIPHERS=ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384 \
  PROXY_SSL_PROTOCOLS="TLSv1.2 TLSv1.3" \
  PROXY_SSL_VERIFY=off \
  PROXY_SSL_VERIFY_DEPTH=1 \
  PROXY_TIMEOUT=60s \
  REAL_IP_HEADER=X-REAL-IP \
  REAL_IP_PROXY_HEADER=X-REAL-IP \
  REAL_IP_RECURSIVE=on \
  SSL_PORT=8443 \
  SET_REAL_IP_FROM=127.0.0.1 \
  SERVER_NAME=localhost \
  WORKER_CONNECTIONS=1024 \
  ACCESSLOG=/var/log/nginx/access.log \
  ERRORLOG=/var/log/nginx/error.log \
  HTTP2=on \
  KEEPALIVE_TIMEOUT=60s \
  LOGLEVEL=warn \
  METRICS_ALLOW_FROM=127.0.0.0/24 \
  METRICS_DENY_FROM=all \
  METRICSLOG=/dev/null \
  MODSEC_ARGUMENT_SEPARATOR='&' \
  MODSEC_ARGUMENTS_LIMIT=1000 \
  MODSEC_AUDIT_ENGINE=RelevantOnly \
  MODSEC_AUDIT_LOG=/dev/stdout \
  MODSEC_AUDIT_LOG_FORMAT=JSON \
  MODSEC_AUDIT_LOG_PARTS=ABIJDEFHZ \
  MODSEC_AUDIT_LOG_RELEVANT_STATUS='^(?:5|4(?!04))' \
  MODSEC_AUDIT_LOG_TYPE=Serial \
  MODSEC_AUDIT_STORAGE_DIR=/var/log/modsecurity/audit/ \
  MODSEC_COOKIE_FORMAT=0 \
  MODSEC_DATA_DIR=/tmp/modsecurity/data \
  MODSEC_DEBUG_LOG=/dev/null \
  MODSEC_DEBUG_LOGLEVEL=0 \
  MODSEC_DEFAULT_PHASE1_ACTION="phase:1,pass,log,tag:'\${MODSEC_TAG}'" \
  MODSEC_DEFAULT_PHASE2_ACTION="phase:2,pass,log,tag:'\${MODSEC_TAG}'" \
  MODSEC_DISABLE_BACKEND_COMPRESSION=Off \
  MODSEC_PCRE_MATCH_LIMIT=100000 \
  MODSEC_PCRE_MATCH_LIMIT_RECURSION=100000 \
  MODSEC_REQ_BODY_ACCESS=on \
  MODSEC_REQ_BODY_JSON_DEPTH_LIMIT=512 \
  MODSEC_REQ_BODY_LIMIT=13107200 \
  MODSEC_REQ_BODY_LIMIT_ACTION=Reject \
  MODSEC_REQ_BODY_NOFILES_LIMIT=131072 \
  MODSEC_RESP_BODY_ACCESS=on \
  MODSEC_RESP_BODY_LIMIT=1048576 \
  MODSEC_RESP_BODY_LIMIT_ACTION=ProcessPartial \
  MODSEC_RESP_BODY_MIMETYPE="text/plain text/html text/xml" \
  MODSEC_STATUS_ENGINE=Off \
  MODSEC_TAG=modsecurity \
  MODSEC_TMP_DIR=/tmp/modsecurity/tmp \
  MODSEC_TMP_SAVE_UPLOADED_FILES=on \
  MODSEC_UNICODE_MAPPING=20127 \
  MODSEC_RULE_ENGINE=on \
  MODSEC_UPLOAD_DIR=/tmp/modsecurity/upload \
  MODSEC_UPLOAD_FILE_MODE=0600 \
  MODSEC_UPLOAD_KEEP_FILES=Off \
  NGINX_ALWAYS_TLS_REDIRECT=off \
  RESOLVERS= \
  RESOLVER_CONFIG=valid=5s \
  SSL_CERT_FILE=/etc/nginx/conf/server.crt \
  SSL_CIPHERS=ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384 \
  SSL_DH_BITS=2048 \
  SSL_OCSP_STAPLING=on \
  SSL_PREFER_CIPHERS=off \
  SSL_PROTOCOLS="TLSv1.2 TLSv1.3" \
  SSL_VERIFY=off \
  SSL_VERIFY_DEPTH=1 \
  ANOMALY_INBOUND=5 \
  ANOMALY_OUTBOUND=4 \
  BLOCKING_PARANOIA=1 \
  SERVER_TOKENS=off

USER nginx
EXPOSE 80 443

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["nginx", "-g", "daemon off;"]

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD sh -c 'grep -qi ":0050 .* 0A" /proc/net/tcp || exit 1'
