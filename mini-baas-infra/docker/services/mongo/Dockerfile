# syntax=docker/dockerfile:1
# File: docker/services/mongo/Dockerfile

FROM public.ecr.aws/docker/library/mongo:7
EXPOSE 27017
USER mongodb

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD mongosh --quiet --eval "try { rs.status().myState === 1 ? quit(0) : quit(1) } catch(e) { db.runCommand({ ping: 1 }).ok ? quit(0) : quit(1) }" || exit 1
