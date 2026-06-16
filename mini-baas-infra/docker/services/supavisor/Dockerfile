# syntax=docker/dockerfile:1
# File: docker/services/supavisor/Dockerfile

FROM supabase/supavisor:2.7.4
EXPOSE 6543
USER 1001:1001

# Supavisor pools PG on port 6543. The Elixir release binary exposes a pid command
# that returns 0 if the BEAM VM is running and the supavisor app is started.
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD /app/bin/supavisor pid >/dev/null 2>&1 || exit 1
