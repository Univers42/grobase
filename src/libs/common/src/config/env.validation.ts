/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   env.validation.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/18 21:19:16 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/18 21:19:16 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

import { plainToInstance, Type } from 'class-transformer';
import { IsIn, IsInt, IsOptional, Max, Min, validateSync } from 'class-validator';

/**
 * The deployment identities, the same set as `GROBASE_ENV.allowed` in
 * `infra/config/env/schema.json`. `local` and `dev` are lenient; every other
 * value, `staging` and `prod` included, is strict.
 */
export const GROBASE_ENVS = ['local', 'dev', 'staging', 'prod'] as const;

const LENIENT_ENVS = ['local', 'dev'] as const;
const DEFAULT_ENV = 'local';
const LOG_LEVELS = ['trace', 'debug', 'info', 'warn', 'error', 'fatal', 'silent'] as const;
const GOVERNED_KEYS = ['PORT', 'LOG_LEVEL', 'GROBASE_ENV'] as const;

/**
 * The secrets every service that authenticates a caller reads: `JWT_SECRET`
 * verifies a bearer JWT and `INTERNAL_IDENTITY_HMAC_KEYS` verifies (and, in the
 * api-key middleware, signs) the identity envelope, both in
 * `libs/common/src/identity/request-identity.ts`.
 */
export const IDENTITY_SECRETS = ['JWT_SECRET', 'INTERNAL_IDENTITY_HMAC_KEYS'] as const;

/**
 * The only keys a service may declare as required. Each is a SECRET in
 * `infra/config/env/schema.json`, so a key absent from that file cannot be
 * named here and the compiler refuses a typo.
 */
export type ServiceSecret =
  | (typeof IDENTITY_SECRETS)[number]
  | 'ADAPTER_REGISTRY_SERVICE_TOKEN'
  | 'DATABASE_URL';

/** What one service needs from its environment: its name and the secrets it reads. */
export type ServiceEnvSpec = {
  readonly service: string;
  readonly secrets: readonly ServiceSecret[];
};

/** The shape `ConfigModule.forRoot({ validate })` takes. */
export type EnvValidator = (config: Record<string, unknown>) => Record<string, unknown>;

/**
 * The keys whose shape every service shares, checked by class-validator. All are
 * optional: a service has its own default for `PORT` and `LOG_LEVEL`, and an
 * absent `GROBASE_ENV` means `local`. A key that is present but blank is invalid.
 */
export class EnvironmentVariables {
  @IsOptional()
  @IsInt()
  @Min(1)
  @Max(65535)
  @Type(() => Number)
  PORT?: number;

  @IsOptional()
  @IsIn(LOG_LEVELS)
  LOG_LEVEL?: string;

  @IsOptional()
  @IsIn(GROBASE_ENVS)
  GROBASE_ENV?: string;
}

/** Copies only the governed keys, so no secret ever enters a validated instance. */
function governedSubset(config: Record<string, unknown>): Record<string, unknown> {
  const present = GOVERNED_KEYS.filter((key) => config[key] !== undefined);
  return Object.fromEntries(present.map((key) => [key, config[key]]));
}

/**
 * Validates the governed keys and returns the parsed instance with the messages
 * class-validator produced. Those messages name a property and its constraint,
 * never the offending value, and the error objects (which carry it) are not kept.
 */
function checkShape(config: Record<string, unknown>): {
  parsed: EnvironmentVariables;
  problems: string[];
} {
  const parsed = plainToInstance(EnvironmentVariables, governedSubset(config), {
    enableImplicitConversion: true,
  });
  const errors = validateSync(parsed, { validationError: { target: false, value: false } });
  return { parsed, problems: errors.flatMap((error) => Object.values(error.constraints ?? {})) };
}

/**
 * True for any GROBASE_ENV that is set and is not `local` or `dev`: staging, prod
 * and, deliberately, an unrecognised value (unknown is treated as strict).
 */
function isStrict(env: string | undefined): boolean {
  return env !== undefined && !LENIENT_ENVS.some((lenient) => lenient === env);
}

/** True when a value is absent or only whitespace, which the code treats as unset. */
function isBlank(value: unknown): boolean {
  return String(value ?? '').trim() === '';
}

/** One message per required secret that is unset or blank; names the key only. */
function missingSecrets(config: Record<string, unknown>, secrets: readonly string[]): string[] {
  return secrets
    .filter((key) => isBlank(config[key]))
    .map((key) => `${key} is required when GROBASE_ENV is staging or prod, but is unset or blank`);
}

/** The environment as a label that is safe to print: a known name, else "unrecognised". */
function envLabel(env: string | undefined): string {
  return GROBASE_ENVS.find((known) => known === (env ?? DEFAULT_ENV)) ?? 'unrecognised';
}

/** Joins every problem into the one message a failed boot prints. */
function failureMessage(spec: ServiceEnvSpec, env: string | undefined, problems: string[]): string {
  const header = `${spec.service}: invalid environment (GROBASE_ENV=${envLabel(env)})`;
  return [header, ...problems.map((problem) => `  - ${problem}`)].join('\n');
}

/**
 * Builds the validator for `ConfigModule.forRoot({ isGlobal: true, validate })`.
 *
 * It checks the shape of `PORT`, `LOG_LEVEL` and `GROBASE_ENV` in every
 * environment, and when `GROBASE_ENV` is strict it also requires each secret the
 * spec lists. Every problem is gathered into one thrown error that names keys and
 * never a value, so a failed boot reports everything at once and leaks nothing.
 * It returns the full config with `GROBASE_ENV` defaulted to `local`, because
 * `@nestjs/config` assigns the returned object to `process.env` and reads it first.
 *
 * Ponytail: presence only, so a placeholder such as `changeme` passes (the value
 * checks live in `scripts/ops/preflight-production.sh`), and a required list that
 * drifts from the service's real reads is caught only by review, not at runtime.
 *
 * @param spec The service name and the secrets its code reads.
 * @throws Error listing every missing or invalid key; never contains a value.
 */
export function validateEnv(spec: ServiceEnvSpec): EnvValidator {
  return (config) => {
    const { parsed, problems } = checkShape(config);
    const env = parsed.GROBASE_ENV;
    const missing = isStrict(env) ? missingSecrets(config, spec.secrets) : [];
    const all = [...problems, ...missing];
    if (all.length > 0) throw new Error(failureMessage(spec, env, all));
    return { ...config, GROBASE_ENV: env ?? DEFAULT_ENV };
  };
}
