import { NestFactory } from '@nestjs/core';
import { Logger } from '@nestjs/common';
import { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import helmet from 'helmet';
import compression from 'compression';
import {
  json,
  urlencoded,
  type Request,
  type Response,
  type NextFunction,
} from 'express';
import { join } from 'node:path';
import { existsSync } from 'node:fs';
import { ServerResponse } from 'node:http';
import { AppModule } from './app.module';
import {
  AUTH_COOKIE_NAME,
  AUTH_CSRF_COOKIE_NAME,
} from './auth/auth-cookie.constants';

const DEFAULT_PUBLIC_SITE_ORIGIN = 'https://vite-gourmand.fr';
const LOCAL_DEVELOPMENT_ORIGINS = [
  'http://localhost:5173',
  'http://localhost:5174',
];

const CSRF_SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS']);
const CSRF_EXEMPT_PATHS = new Set([
  '/api/auth/register',
  '/api/auth/login',
  '/api/auth/logout',
  '/api/auth/google/token',
  '/api/auth/forgot-password',
  '/api/auth/verify-reset-token',
  '/api/auth/reset-password',
]);

function isProductionEnvironment(): boolean {
  return process.env.NODE_ENV === 'production';
}

function parseOriginList(rawOrigins?: string): string[] {
  if (!rawOrigins) return [];
  return rawOrigins
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);
}

function isLocalHttpOrigin(origin: URL): boolean {
  return (
    origin.protocol === 'http:' &&
    ['localhost', '127.0.0.1', '::1'].includes(origin.hostname)
  );
}

function assertHttpsOrigin(name: string, rawOrigin: string): void {
  const origin = new URL(rawOrigin);
  if (origin.protocol === 'https:') return;
  if (!isProductionEnvironment() && isLocalHttpOrigin(origin)) return;

  throw new Error(
    `${name} must use https:// in production. Received: ${rawOrigin}`,
  );
}

function getPublicOrigins(): string[] {
  if (!isProductionEnvironment()) {
    const configuredOrigins = parseOriginList(process.env.FRONTEND_URL);
    return configuredOrigins.length > 0
      ? configuredOrigins
      : LOCAL_DEVELOPMENT_ORIGINS;
  }

  const productionOrigins = parseOriginList(
    process.env.FRONTEND_URL || process.env.PUBLIC_SITE_URL,
  );
  return productionOrigins.length > 0
    ? productionOrigins
    : [DEFAULT_PUBLIC_SITE_ORIGIN];
}

function getPrimaryPublicOrigin(): string {
  return getPublicOrigins()[0] ?? DEFAULT_PUBLIC_SITE_ORIGIN;
}

function validateTransportSecurityConfig(): void {
  if (!isProductionEnvironment()) return;

  getPublicOrigins().forEach((origin) =>
    assertHttpsOrigin('FRONTEND_URL', origin),
  );

  for (const envName of [
    'PUBLIC_SITE_URL',
    'VITE_PUBLIC_SITE_URL',
    'VITE_API_URL',
  ]) {
    const value = process.env[envName];
    if (value) {
      parseOriginList(value).forEach((origin) =>
        assertHttpsOrigin(envName, origin),
      );
    }
  }
}

function parseCookies(cookieHeader?: string): Record<string, string> {
  if (!cookieHeader) return {};

  return cookieHeader
    .split(';')
    .reduce<Record<string, string>>((cookies, cookie) => {
      const [rawName, ...rawValueParts] = cookie.trim().split('=');
      if (!rawName) return cookies;

      const rawValue = rawValueParts.join('=');
      try {
        cookies[rawName] = decodeURIComponent(rawValue);
      } catch {
        cookies[rawName] = rawValue;
      }
      return cookies;
    }, {});
}

function readSingleHeader(
  header: string | string[] | undefined,
): string | null {
  if (!header || Array.isArray(header)) return null;
  return header;
}

function readForwardedValue(
  value: string | string[] | undefined,
): string | null {
  const header = readSingleHeader(value);
  if (!header) return null;
  return header.split(',')[0]?.trim() || null;
}

function isHttpsRequest(req: Request): boolean {
  return (
    req.secure ||
    readForwardedValue(req.headers['x-forwarded-proto']) === 'https'
  );
}

function shouldBypassInternalHttp(req: Request): boolean {
  return (
    !readForwardedValue(req.headers['x-forwarded-proto']) && req.path === '/api'
  );
}

function enforceHttps(req: Request, res: Response, next: NextFunction): void {
  if (
    !isProductionEnvironment() ||
    isHttpsRequest(req) ||
    shouldBypassInternalHttp(req)
  ) {
    next();
    return;
  }

  const host =
    readForwardedValue(req.headers['x-forwarded-host']) ?? req.headers.host;
  if (!host || Array.isArray(host)) {
    res.status(400).send('Missing Host header');
    return;
  }

  res.redirect(308, `https://${host}${req.originalUrl}`);
}

function csrfProtection(req: Request, res: Response, next: NextFunction): void {
  if (CSRF_SAFE_METHODS.has(req.method.toUpperCase())) {
    next();
    return;
  }

  if (!req.path.startsWith('/api') || CSRF_EXEMPT_PATHS.has(req.path)) {
    next();
    return;
  }

  const cookies = parseCookies(req.headers.cookie);
  if (!cookies[AUTH_COOKIE_NAME]) {
    next();
    return;
  }

  const csrfCookie = cookies[AUTH_CSRF_COOKIE_NAME];
  const csrfHeader = readSingleHeader(req.headers['x-csrf-token']);

  if (!csrfCookie || !csrfHeader || csrfCookie !== csrfHeader) {
    res.status(403).json({
      statusCode: 403,
      message: 'Invalid CSRF token',
      error: 'Forbidden',
    });
    return;
  }

  next();
}

async function bootstrap() {
  validateTransportSecurityConfig();

  const app = await NestFactory.create<NestExpressApplication>(AppModule, {
    bodyParser: false, // configured manually below with explicit size limits
  });
  const logger = new Logger('Bootstrap');

  if (isProductionEnvironment()) {
    app.set('trust proxy', 1);
  }

  app.use(enforceHttps);

  // Body parsers with explicit size limits (must come before other middleware)
  app.use(json({ limit: '10mb' }));
  app.use(urlencoded({ extended: true, limit: '10mb' }));

  // Security headers with Helmet
  // Configured to allow Google Identity Services (popup-based OAuth)
  app.use(
    helmet({
      contentSecurityPolicy: {
        useDefaults: true,
        directives: {
          'default-src': ["'self'"],
          'base-uri': ["'self'"],
          'object-src': ["'none'"],
          'form-action': ["'self'"],
          'frame-ancestors': ["'none'"],
          'script-src': [
            "'self'",
            "'unsafe-inline'",
            'https://accounts.google.com',
          ],
          'style-src': [
            "'self'",
            "'unsafe-inline'",
            'https://accounts.google.com',
          ],
          'style-src-elem': [
            "'self'",
            "'unsafe-inline'",
            'https://accounts.google.com',
          ],
          'connect-src': [
            "'self'",
            ...getPublicOrigins(),
            'https://accounts.google.com',
          ],
          'font-src': ["'self'", 'data:'],
          'img-src': [
            "'self'",
            'data:',
            'blob:',
            'https://images.unsplash.com',
          ],
          'frame-src': ["'self'", 'https://accounts.google.com'],
          ...(process.env.NODE_ENV === 'production'
            ? { 'upgrade-insecure-requests': [] }
            : {}),
        },
      },
      strictTransportSecurity: isProductionEnvironment()
        ? {
            maxAge: 31536000,
            includeSubDomains: true,
            preload: true,
          }
        : false,
      crossOriginOpenerPolicy: { policy: 'same-origin-allow-popups' }, // Allow Google OAuth popup
      crossOriginEmbedderPolicy: false, // Disable for Google scripts
      referrerPolicy: { policy: 'strict-origin-when-cross-origin' },
    }),
  );

  app.use((_req: Request, res: Response, next: NextFunction) => {
    res.setHeader(
      'Permissions-Policy',
      'camera=(), microphone=(), geolocation=()',
    );
    next();
  });

  // Response compression for better performance
  app.use(compression());

  // Serve static frontend files in production
  // In production: __dirname = /app/dist/src, so we go up 2 levels to /app
  if (process.env.NODE_ENV === 'production') {
    const publicPath = join(__dirname, '..', '..', 'public');
    logger.log(`📁 Static assets path: ${publicPath}`);
    app.useStaticAssets(publicPath, {
      setHeaders: (res: ServerResponse, filePath: string) => {
        const normalizedPath = filePath.replaceAll('\\', '/');
        if (normalizedPath.includes('/assets/')) {
          res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
          return;
        }
        if (normalizedPath.endsWith('/index.html')) {
          res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
          return;
        }
        res.setHeader('Cache-Control', 'public, max-age=3600');
      },
    });
  }

  // Enable CORS for frontend
  app.enableCors({
    origin: getPublicOrigins(),
    credentials: true,
    allowedHeaders: ['Content-Type', 'Authorization', 'X-CSRF-Token'],
  });

  app.use(csrfProtection);

  // Global prefix for API routes
  app.setGlobalPrefix('api');

  // Swagger API Documentation
  const config = new DocumentBuilder()
    .setTitle('Vite Gourmand API')
    .setDescription(
      'API documentation for the Vite Gourmand restaurant ordering platform',
    )
    .setVersion('1.0')
    .addBearerAuth()
    .addTag('auth', 'Authentication endpoints')
    .addTag('users', 'User management endpoints')
    .addTag('menus', 'Menu management endpoints')
    .addTag('orders', 'Order management endpoints')
    .build();
  const document = SwaggerModule.createDocument(app, config);
  SwaggerModule.setup('api/docs', app, document);

  // SPA fallback: serve index.html for non-API routes in production
  if (process.env.NODE_ENV === 'production') {
    const spaPublicPath = join(__dirname, '..', '..', 'public');
    const indexPath = join(spaPublicPath, 'index.html');

    if (existsSync(indexPath)) {
      logger.log(`📄 SPA index.html found at: ${indexPath}`);
      app.use((req: Request, res: Response, next: NextFunction) => {
        // Skip API routes and static files
        if (req.path.startsWith('/api') || req.path.includes('.')) {
          return next();
        }
        // Serve index.html for SPA client-side routing
        res.setHeader('Cache-Control', 'no-cache, no-store, must-revalidate');
        res.sendFile(indexPath);
      });
    } else {
      logger.warn(`⚠️ SPA index.html not found at: ${indexPath}`);
    }
  }

  const port = process.env.PORT ?? 3000;
  // Listen on 0.0.0.0 to accept connections from outside the container
  await app.listen(port, '0.0.0.0');

  logger.log(`🚀 Application is running on: http://0.0.0.0:${port}`);
  logger.log(`📚 API endpoints: http://0.0.0.0:${port}/api`);
  logger.log(`📚 Swagger docs: http://0.0.0.0:${port}/api/docs`);
  logger.log(`🔐 Public HTTPS origin: ${getPrimaryPublicOrigin()}`);
  logger.log(`📊 Environment: ${process.env.NODE_ENV || 'development'}`);
  logger.log(`🔒 Security: Helmet enabled`);
  logger.log(`📦 Compression: enabled`);
  if (process.env.NODE_ENV === 'production') {
    logger.log(`🌐 Frontend: Serving static files from /public`);
  }
}
void bootstrap();
