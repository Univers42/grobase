import { afterEach, beforeEach, describe, expect, it } from '@jest/globals';
import { ConfigModule, ConfigService } from '@nestjs/config';
import { Test } from '@nestjs/testing';
import { IDENTITY_SECRETS, validateEnv } from './env.validation';
import type { ServiceEnvSpec, ServiceSecret } from './env.validation';

const SENTINEL = 'sentinel-value-that-must-never-be-printed';

const QUERY_ROUTER: ServiceEnvSpec = {
  service: 'query-router',
  secrets: [...IDENTITY_SECRETS, 'ADAPTER_REGISTRY_SERVICE_TOKEN', 'DATABASE_URL'],
};
const EMAIL_SERVICE: ServiceEnvSpec = { service: 'email-service', secrets: IDENTITY_SECRETS };
const LOG_SERVICE: ServiceEnvSpec = { service: 'log-service', secrets: [] };

/** setSecrets builds a config in which every named secret holds the sentinel. */
function setSecrets(...keys: readonly ServiceSecret[]): Record<string, string> {
  return Object.fromEntries(keys.map((key) => [key, SENTINEL]));
}

/** messageOf runs the validator and returns the message it threw, failing if it did not throw. */
function messageOf(spec: ServiceEnvSpec, config: Record<string, unknown>): string {
  try {
    validateEnv(spec)(config);
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
  throw new Error('expected validateEnv to throw');
}

/** problemLines returns the bullet lines of a failure message, one per reported problem. */
function problemLines(message: string): string[] {
  return message.split('\n').filter((line) => line.startsWith('  - '));
}

describe('validateEnv — lenient environments', () => {
  it.each(['local', 'dev'])('does not require a secret in %s', (env) => {
    expect(() => validateEnv(QUERY_ROUTER)({ GROBASE_ENV: env })).not.toThrow();
  });

  it('treats an absent GROBASE_ENV as local and returns the rest of the config unchanged', () => {
    const result = validateEnv(QUERY_ROUTER)({ SOME_KEY: 'kept' });
    expect(result['GROBASE_ENV']).toBe('local');
    expect(result['SOME_KEY']).toBe('kept');
  });
});

describe('validateEnv — strict environments', () => {
  const full = setSecrets(
    'JWT_SECRET',
    'INTERNAL_IDENTITY_HMAC_KEYS',
    'ADAPTER_REGISTRY_SERVICE_TOKEN',
    'DATABASE_URL',
  );

  it.each(['staging', 'prod'])('passes in %s when every listed secret is set', (env) => {
    expect(() => validateEnv(QUERY_ROUTER)({ ...full, GROBASE_ENV: env })).not.toThrow();
  });

  it.each(['staging', 'prod'])('names every missing secret in a single %s error', (env) => {
    const message = messageOf(QUERY_ROUTER, { GROBASE_ENV: env, JWT_SECRET: SENTINEL });
    expect(problemLines(message)).toHaveLength(3);
    expect(message).toContain('INTERNAL_IDENTITY_HMAC_KEYS');
    expect(message).toContain('ADAPTER_REGISTRY_SERVICE_TOKEN');
    expect(message).toContain('DATABASE_URL');
    expect(message).not.toContain('JWT_SECRET');
  });

  it('treats a blank or whitespace-only secret as missing', () => {
    const config = { ...full, GROBASE_ENV: 'prod', DATABASE_URL: '   ', JWT_SECRET: '' };
    const message = messageOf(QUERY_ROUTER, config);
    expect(problemLines(message)).toHaveLength(2);
    expect(message).toContain('DATABASE_URL');
    expect(message).toContain('JWT_SECRET');
  });

  it('requires only what the service lists', () => {
    const identityOnly = { ...setSecrets(...IDENTITY_SECRETS), GROBASE_ENV: 'prod' };
    expect(() => validateEnv(EMAIL_SERVICE)(identityOnly)).not.toThrow();
    expect(messageOf(QUERY_ROUTER, identityOnly)).toContain('DATABASE_URL');
  });

  it('requires nothing of a service that lists no secret', () => {
    expect(() => validateEnv(LOG_SERVICE)({ GROBASE_ENV: 'prod' })).not.toThrow();
  });
});

describe('validateEnv — GROBASE_ENV', () => {
  it.each(['production', 'PROD', '', '  '])(
    'rejects the value %j and lists the allowed ones',
    (value) => {
      const message = messageOf(LOG_SERVICE, { GROBASE_ENV: value });
      expect(message).toContain('GROBASE_ENV');
      expect(message).toContain('local, dev, staging, prod');
    },
  );

  it('treats an unrecognised value as strict, so missing secrets are reported with it', () => {
    const message = messageOf(EMAIL_SERVICE, { GROBASE_ENV: 'production' });
    expect(message).toContain('GROBASE_ENV=unrecognised');
    expect(message).toContain('JWT_SECRET');
    expect(message).toContain('INTERNAL_IDENTITY_HMAC_KEYS');
  });
});

describe('validateEnv — shared shape and aggregation', () => {
  it.each(['0', '70000', 'abc', '1.5'])('rejects PORT=%s', (port) => {
    expect(messageOf(LOG_SERVICE, { PORT: port })).toContain('PORT');
  });

  it('accepts a valid PORT and LOG_LEVEL, and leaves them as strings in the returned config', () => {
    const result = validateEnv(LOG_SERVICE)({ PORT: '4001', LOG_LEVEL: 'debug' });
    expect(result['PORT']).toBe('4001');
    expect(result['LOG_LEVEL']).toBe('debug');
  });

  it('reports a bad shape and every missing secret together', () => {
    const message = messageOf(EMAIL_SERVICE, { GROBASE_ENV: 'prod', LOG_LEVEL: 'loud', PORT: '0' });
    expect(problemLines(message)).toHaveLength(4);
    expect(message).toContain('LOG_LEVEL');
    expect(message).toContain('PORT');
    expect(message).toContain('JWT_SECRET');
    expect(message).toContain('INTERNAL_IDENTITY_HMAC_KEYS');
  });
});

describe('validateEnv — never prints a value', () => {
  it('keeps every value out of the message, set or invalid', () => {
    const message = messageOf(QUERY_ROUTER, {
      GROBASE_ENV: SENTINEL,
      PORT: SENTINEL,
      LOG_LEVEL: SENTINEL,
      JWT_SECRET: SENTINEL,
    });
    expect(message).not.toContain(SENTINEL);
    expect(message).toContain('GROBASE_ENV=unrecognised');
  });
});

describe('validateEnv — as ConfigModule.forRoot validate', () => {
  const touched = ['GROBASE_ENV', 'JWT_SECRET', 'INTERNAL_IDENTITY_HMAC_KEYS'] as const;
  let saved: Record<string, string | undefined>;

  beforeEach(() => {
    saved = Object.fromEntries(touched.map((key) => [key, process.env[key]]));
    touched.forEach((key) => delete process.env[key]);
  });

  afterEach(() => {
    touched.forEach((key) => {
      const value = saved[key];
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    });
  });

  /** boot compiles a testing module whose only import is the validated ConfigModule. */
  function boot() {
    const config = ConfigModule.forRoot({
      isGlobal: true,
      ignoreEnvFile: true,
      validate: validateEnv(EMAIL_SERVICE),
    });
    return Test.createTestingModule({ imports: [config] }).compile();
  }

  it('refuses to start in prod with a secret missing, naming the key and the service', async () => {
    process.env['GROBASE_ENV'] = 'prod';
    process.env['JWT_SECRET'] = SENTINEL;
    const failure = await boot().catch((error: unknown) => error);
    const message = failure instanceof Error ? failure.message : '';
    expect(message).toContain('email-service: invalid environment (GROBASE_ENV=prod)');
    expect(message).toContain('INTERNAL_IDENTITY_HMAC_KEYS');
    expect(message).not.toContain(SENTINEL);
  });

  it('starts with no secret at all when GROBASE_ENV is absent, and exposes the local default', async () => {
    const app = await boot();
    expect(app.get(ConfigService).get('GROBASE_ENV')).toBe('local');
    expect(process.env['GROBASE_ENV']).toBe('local');
  });

  it('starts in staging once every listed secret is set', async () => {
    process.env['GROBASE_ENV'] = 'staging';
    process.env['JWT_SECRET'] = SENTINEL;
    process.env['INTERNAL_IDENTITY_HMAC_KEYS'] = SENTINEL;
    const app = await boot();
    expect(app.get(ConfigService).get('GROBASE_ENV')).toBe('staging');
  });
});
