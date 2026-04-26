#!/usr/bin/env sh
set -eu

required_vars="KONG_PUBLIC_API_KEY KONG_SERVICE_API_KEY JWT_SECRET"
for var in $required_vars; do
  eval "value=\${$var:-}"
  if [ -z "$value" ]; then
    echo "Missing required environment variable: $var" >&2
    exit 1
  fi
done

: "${KONG_CORS_ORIGIN_APP:=https://app.example.com}"
: "${KONG_CORS_ORIGIN_PLAYGROUND:=https://playground.example.com}"
: "${KONG_CORS_ORIGIN_STUDIO:=https://studio.example.com}"
: "${KONG_CORS_ORIGIN_FRONTEND:=https://frontend.example.com}"
: "${API_EXTERNAL_URL:=https://api.example.com/auth/v1}"
: "${KONG_ANON_UUID:=cd4f782c-ac87-5081-b322-b54834d15651}"
: "${AUTH_UPSTREAM_URL:=http://mini-baas-auth.internal:9999}"
: "${POSTGREST_UPSTREAM_URL:=http://mini-baas-postgrest.internal:3000}"
: "${REALTIME_WS_UPSTREAM_URL:=http://mini-baas-realtime.internal:4000/ws}"
: "${MINIO_UPSTREAM_URL:=http://mini-baas-minio.internal:9000}"
: "${PG_META_UPSTREAM_URL:=http://mini-baas-pg-meta.internal:8080}"
: "${MONGO_API_UPSTREAM_URL:=http://mini-baas-mongo-api.internal:3010}"
: "${ADAPTER_REGISTRY_UPSTREAM_URL:=http://mini-baas-adapter-registry.internal:3020}"
: "${QUERY_ROUTER_UPSTREAM_URL:=http://mini-baas-query-router.internal:4001}"
: "${TRINO_UPSTREAM_URL:=http://mini-baas-trino.internal:8080}"
: "${STUDIO_UPSTREAM_URL:=http://mini-baas-studio.internal:3000}"
: "${EMAIL_SERVICE_UPSTREAM_URL:=http://mini-baas-email-service.internal:3030}"
: "${STORAGE_ROUTER_UPSTREAM_URL:=http://mini-baas-storage-router.internal:3040}"
: "${PERMISSION_ENGINE_UPSTREAM_URL:=http://mini-baas-permission-engine.internal:3050}"
: "${SCHEMA_SERVICE_UPSTREAM_URL:=http://mini-baas-schema-service.internal:3060}"
: "${ANALYTICS_SERVICE_UPSTREAM_URL:=http://mini-baas-analytics-service.internal:3070}"
: "${GDPR_SERVICE_UPSTREAM_URL:=http://mini-baas-gdpr-service.internal:3080}"
: "${NEWSLETTER_SERVICE_UPSTREAM_URL:=http://mini-baas-newsletter-service.internal:3090}"
: "${AI_SERVICE_UPSTREAM_URL:=http://mini-baas-ai-service.internal:3100}"
: "${LOG_SERVICE_UPSTREAM_URL:=http://mini-baas-log-service.internal:3110}"
: "${SESSION_SERVICE_UPSTREAM_URL:=http://mini-baas-session-service.internal:3120}"

sed \
  -e "s|__KONG_PUBLIC_API_KEY__|${KONG_PUBLIC_API_KEY}|g" \
  -e "s|__KONG_SERVICE_API_KEY__|${KONG_SERVICE_API_KEY}|g" \
  -e "s|__KONG_CORS_ORIGIN_APP__|${KONG_CORS_ORIGIN_APP}|g" \
  -e "s|__KONG_CORS_ORIGIN_PLAYGROUND__|${KONG_CORS_ORIGIN_PLAYGROUND}|g" \
  -e "s|__KONG_CORS_ORIGIN_STUDIO__|${KONG_CORS_ORIGIN_STUDIO}|g" \
  -e "s|__KONG_CORS_ORIGIN_FRONTEND__|${KONG_CORS_ORIGIN_FRONTEND}|g" \
  -e "s|__JWT_SECRET__|${JWT_SECRET}|g" \
  -e "s|__GOTRUE_JWT_ISS__|${GOTRUE_JWT_ISS:-${API_EXTERNAL_URL}}|g" \
  -e "s|__KONG_ANON_UUID__|${KONG_ANON_UUID}|g" \
  -e "s|http://gotrue:9999|${AUTH_UPSTREAM_URL}|g" \
  -e "s|http://postgrest:3000|${POSTGREST_UPSTREAM_URL}|g" \
  -e "s|http://realtime:4000/ws|${REALTIME_WS_UPSTREAM_URL}|g" \
  -e "s|http://minio:9000|${MINIO_UPSTREAM_URL}|g" \
  -e "s|http://pg-meta:8080|${PG_META_UPSTREAM_URL}|g" \
  -e "s|http://mongo-api:3010|${MONGO_API_UPSTREAM_URL}|g" \
  -e "s|http://adapter-registry:3020|${ADAPTER_REGISTRY_UPSTREAM_URL}|g" \
  -e "s|http://query-router:4001|${QUERY_ROUTER_UPSTREAM_URL}|g" \
  -e "s|http://trino:8080|${TRINO_UPSTREAM_URL}|g" \
  -e "s|http://studio:3000|${STUDIO_UPSTREAM_URL}|g" \
  -e "s|http://email-service:3030|${EMAIL_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://storage-router:3040/sign|${STORAGE_ROUTER_UPSTREAM_URL}/sign|g" \
  -e "s|http://storage-router:3040|${STORAGE_ROUTER_UPSTREAM_URL}|g" \
  -e "s|http://permission-engine:3050|${PERMISSION_ENGINE_UPSTREAM_URL}|g" \
  -e "s|http://schema-service:3060|${SCHEMA_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://analytics-service:3070|${ANALYTICS_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://gdpr-service:3080|${GDPR_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://newsletter-service:3090|${NEWSLETTER_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://ai-service:3100|${AI_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://log-service:3110|${LOG_SERVICE_UPSTREAM_URL}|g" \
  -e "s|http://session-service:3120|${SESSION_SERVICE_UPSTREAM_URL}|g" \
  /etc/kong/kong.yml.tmpl > /tmp/kong.yml

exec /docker-entrypoint.sh "$@"
