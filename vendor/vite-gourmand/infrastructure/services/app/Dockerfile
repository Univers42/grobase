# ============================================
# Vite Gourmand - Production App Image
# ============================================

FROM node:22-alpine AS backend-builder

WORKDIR /build/Back

COPY Back/package*.json ./
RUN npm ci --ignore-scripts

COPY Back/ ./
RUN npm exec --ignore-scripts -- prisma generate --schema=src/Model/prisma/schema.prisma
RUN npm run build

FROM node:22-alpine AS frontend-builder

WORKDIR /build/View

COPY View/package*.json ./
RUN npm ci --ignore-scripts

COPY View/ ./
RUN npm run build

FROM node:22-alpine AS production

WORKDIR /app

RUN apk add --no-cache curl dumb-init \
  && addgroup -g 1001 -S nodejs \
    && adduser -S nestjs -u 1001 -G nodejs

COPY --chown=nestjs:nodejs --chmod=0555 --from=backend-builder /build/Back/dist ./dist
COPY --chown=nestjs:nodejs --chmod=0555 --from=backend-builder /build/Back/node_modules ./node_modules
COPY --chown=nestjs:nodejs --chmod=0555 --from=backend-builder /build/Back/package*.json ./
COPY --chown=nestjs:nodejs --chmod=0555 --from=backend-builder /build/Back/src ./src
COPY --chown=nestjs:nodejs --chmod=0555 --from=backend-builder /build/Back/tsconfig*.json ./
COPY --chown=nestjs:nodejs --chmod=0555 --from=frontend-builder /build/View/dist ./public

USER nestjs

ENV NODE_ENV=production
ENV PORT=8080

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
  CMD curl -fsS http://localhost:8080/api >/dev/null || exit 1

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "dist/src/main.js"]