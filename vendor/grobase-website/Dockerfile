# syntax=docker/dockerfile:1.7
# Grobase marketing site — multi-stage (pattern: apps/mail/Dockerfile + audit stage).
FROM public.ecr.aws/docker/library/node:22-alpine AS deps
WORKDIR /app
COPY package*.json .npmrc ./
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
	npm ci --ignore-scripts --prefer-offline --no-audit --no-fund

FROM deps AS build
WORKDIR /app
COPY . .
ENV GROBASE_IN_DOCKER=1
RUN npm run build

FROM public.ecr.aws/docker/library/node:22-alpine AS dev
WORKDIR /app
ENV npm_config_fund=false npm_config_audit=false npm_config_update_notifier=false npm_config_ignore_scripts=true
COPY package*.json .npmrc ./
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
	npm ci --ignore-scripts --prefer-offline --no-audit --no-fund
COPY . .
EXPOSE 4324
CMD ["npm", "run", "dev"]

# Quality-gate image: headless Chromium for Lighthouse / pa11y / csp-check.
# Chromium comes from apk (puppeteer/lighthouse never download a browser —
# .npmrc ignore-scripts already blocks their postinstall fetch).
FROM deps AS audit
WORKDIR /app
RUN apk add --no-cache chromium nss freetype harfbuzz ca-certificates ttf-freefont \
	&& { [ -x /usr/bin/chromium-browser ] || ln -s /usr/bin/chromium /usr/bin/chromium-browser; }
ENV CHROME_PATH=/usr/bin/chromium-browser \
	PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium-browser \
	GROBASE_IN_DOCKER=1
COPY . .
EXPOSE 4325
CMD ["npm", "run", "audit:all"]

# Production image: nginx serves the static build with real security headers
# (the <meta> CSP cannot carry frame-ancestors — nginx sets the HTTP ones).
FROM public.ecr.aws/docker/library/nginx:1.27-alpine AS prod
COPY docker/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
