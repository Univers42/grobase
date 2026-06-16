# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    apply-project-sql.sh                               :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#              #
#    Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env sh
set -eu

host=${POSTGRES_HOST:-postgres}
port=${POSTGRES_PORT:-5432}
user=${POSTGRES_USER:-postgres}
db=${POSTGRES_DB:-postgres}
marker=${PROJECT_INIT_MARKER:-track_binocle_20260504}
export PGPASSWORD=${PGPASSWORD:-${POSTGRES_PASSWORD:-postgres}}
if [ -z "${PGOPTIONS:-}" ]; then
  export PGOPTIONS="-c search_path=public"
fi

until pg_isready -h "$host" -p "$port" -U "$user" -d "$db" >/dev/null 2>&1; do
  sleep 1
done

psql_base="psql -h $host -p $port -U $user -d $db -v ON_ERROR_STOP=1"

$psql_base <<SQL
CREATE TABLE IF NOT EXISTS track_binocle_runtime_migrations (
  marker TEXT PRIMARY KEY,
  applied_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);
SQL

schema_applied=$($psql_base -Atc "SELECT 1 FROM track_binocle_runtime_migrations WHERE marker = '${marker}_schema' LIMIT 1")
if [ "$schema_applied" != "1" ]; then
  $psql_base -f /project-init/01-user.sql
  $psql_base -f /project-init/02-gdpr.sql
  $psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_schema') ON CONFLICT DO NOTHING"
fi

$psql_base -f /project-init/03-auth-security.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_auth_security') ON CONFLICT DO NOTHING"

$psql_base -f /project-init/04-osionos-bridge.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_osionos_bridge') ON CONFLICT DO NOTHING"

$psql_base -f /project-init/05-calendar.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_calendar') ON CONFLICT DO NOTHING"

$psql_base <<'SQL'
REVOKE ALL ON public.users FROM anon, authenticated;
GRANT SELECT (id, username, email, avatar_url, bio, theme, notifications_enabled, is_email_verified, created_at, updated_at) ON public.users TO anon;
GRANT SELECT (id, username, email, avatar_url, bio, theme, notifications_enabled, is_email_verified, created_at, updated_at, deletion_requested_at, deleted_at) ON public.users TO authenticated;
GRANT UPDATE (username, avatar_url, bio, theme, notifications_enabled, deletion_requested_at, updated_at) ON public.users TO authenticated;
REVOKE ALL ON public.user_consents, public.user_activities, public.sessions, public.user_tokens FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE ON public.user_consents TO authenticated;
GRANT SELECT ON public.user_activities, public.sessions, public.user_tokens TO authenticated;
GRANT ALL ON public.users TO service_role;
NOTIFY pgrst, 'reload schema';
SQL

# RLS hardening (idempotent + existence-guarded) — runs after the inline grants
# so its tightened anon column grant on public.users is the final word.
$psql_base -f /project-init/07-rls-hardening.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_rls_hardening') ON CONFLICT DO NOTHING"

# Chat / DMs / profiles / feed interactions (idempotent, additive).
$psql_base -f /project-init/08-osionos-chat.sql
$psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_osionos_chat') ON CONFLICT DO NOTHING"

seeds_applied=$($psql_base -Atc "SELECT 1 FROM track_binocle_runtime_migrations WHERE marker = '${marker}_seeds' LIMIT 1")
if [ "$seeds_applied" != "1" ]; then
  seeded_user_count=$($psql_base -Atc "SELECT COUNT(*) FROM users WHERE email IN ('john.doe@example.com', 'jane.doe@example.com')")
  if [ "$seeded_user_count" = "0" ]; then
    $psql_base -f /project-init/06-seeds.sql
  fi
  $psql_base -c "INSERT INTO track_binocle_runtime_migrations (marker) VALUES ('${marker}_seeds') ON CONFLICT DO NOTHING"
fi
