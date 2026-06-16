#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   baas.ts                                            :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// `baas` — the Grobase app-developer CLI (A2 Functions DX). Zero runtime deps:
// only the SDK + Node built-ins (util.parseArgs, fs, os, path). A thin wrapper
// over `@mini-baas/js`.
//
//   baas login [--url <u>] [--key <k>] [--service-key <k>]
//   baas functions deploy <file> [--name <n>]
//   baas functions invoke <name> [--data <json>]
//   baas functions list
//   baas secrets set <KEY> <value> [--function <fn>]
//   baas secrets list
//   baas secrets rm <KEY> [--function <fn>]
//   baas triggers create <name> --function <fn> [--aggregates a,b] [--events x,y]
//   baas triggers list
//   baas triggers rm <id>
//
// Config persists to ~/.config/grobase/config.json (overridable via
// $GROBASE_CONFIG). The pure helpers (parseArgs wrappers, csv, config path)
// are exported for unit tests in tests/cli.test.mjs.

import { parseArgs } from 'node:util';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, join, resolve, relative, isAbsolute } from 'node:path';
import { createClient } from '../index.js';

export interface CliConfig {
  url?: string;
  anonKey?: string;
  serviceRoleKey?: string;
}

/** Resolve the config file path ($GROBASE_CONFIG overrides the default). */
export function configPath(): string {
  return process.env.GROBASE_CONFIG ?? join(homedir(), '.config', 'grobase', 'config.json');
}

/** Load persisted config (returns {} when absent or unreadable). */
export function loadConfig(): CliConfig {
  const p = configPath();
  if (!existsSync(p)) return {};
  try {
    return JSON.parse(readFileSync(p, 'utf8')) as CliConfig;
  } catch {
    return {};
  }
}

/** Persist config, creating the parent directory if needed. */
export function saveConfig(cfg: CliConfig): void {
  const p = configPath();
  mkdirSync(dirname(p), { recursive: true });
  writeFileSync(p, JSON.stringify(cfg, null, 2) + '\n', { mode: 0o600 });
}

/** Split a comma-separated option into a trimmed, non-empty array. */
export function csv(value: string | undefined): string[] | undefined {
  if (value == null) return undefined;
  const out = value.split(',').map((s) => s.trim()).filter(Boolean);
  return out.length > 0 ? out : undefined;
}

/** Parse `--data` as JSON if it looks like JSON, else keep the raw string. */
export function parseData(value: string | undefined): unknown {
  if (value == null) return undefined;
  try {
    return JSON.parse(value);
  } catch {
    return value;
  }
}

const USAGE = `baas — Grobase app-developer CLI

Usage:
  baas login [--url <u>] [--key <anon>] [--service-key <k>]
  baas functions deploy <file> [--name <n>]
  baas functions invoke <name> [--data <json>]
  baas functions list
  baas secrets set <KEY> <value> [--function <fn>]
  baas secrets list
  baas secrets rm <KEY> [--function <fn>]
  baas triggers create <name> --function <fn> [--aggregates a,b] [--events x,y]
  baas triggers list
  baas triggers rm <id>
`;

const OPTIONS = {
  url: { type: 'string' },
  key: { type: 'string' },
  'service-key': { type: 'string' },
  name: { type: 'string' },
  data: { type: 'string' },
  function: { type: 'string' },
  aggregates: { type: 'string' },
  events: { type: 'string' },
  help: { type: 'boolean', short: 'h' },
} as const;

/** Parse argv into { command path, positionals, options }. Exported for tests. */
export function parseCli(argv: string[]): {
  positionals: string[];
  values: Record<string, string | boolean | undefined>;
} {
  const { positionals, values } = parseArgs({
    args: argv,
    options: OPTIONS,
    allowPositionals: true,
    strict: false,
  });
  return { positionals, values: values as Record<string, string | boolean | undefined> };
}

function client(cfg: CliConfig, values: Record<string, string | boolean | undefined>) {
  const url = (values.url as string) ?? cfg.url;
  const anonKey = (values.key as string) ?? cfg.anonKey ?? 'anon';
  const serviceRoleKey = (values['service-key'] as string) ?? cfg.serviceRoleKey;
  if (!url) {
    throw new Error('No base URL configured — run `baas login --url <u> --key <anon>` first.');
  }
  return createClient({ url, anonKey, serviceRoleKey, persistSession: false });
}

function out(value: unknown): void {
  process.stdout.write(JSON.stringify(value, null, 2) + '\n');
}

async function run(argv: string[]): Promise<number> {
  const { positionals, values } = parseCli(argv);
  if (values.help || positionals.length === 0) {
    process.stdout.write(USAGE);
    return 0;
  }
  const [group, action, ...rest] = positionals;
  const cfg = loadConfig();

  if (group === 'login') {
    const next: CliConfig = {
      url: (values.url as string) ?? cfg.url,
      anonKey: (values.key as string) ?? cfg.anonKey,
      serviceRoleKey: (values['service-key'] as string) ?? cfg.serviceRoleKey,
    };
    saveConfig(next);
    out({ saved: configPath(), url: next.url, hasServiceKey: Boolean(next.serviceRoleKey) });
    return 0;
  }

  const c = client(cfg, values);

  if (group === 'functions') {
    if (action === 'deploy') {
      const file = rest[0];
      if (!file) throw new Error('usage: baas functions deploy <file> [--name <n>]');
      // Confine reads to the working-directory tree so a stray `..` (or a
      // tricked invocation on a shared box) can't upload ~/.ssh/id_rsa etc.
      const resolved = resolve(file);
      const rel = relative(process.cwd(), resolved);
      if (rel.startsWith('..') || isAbsolute(rel)) {
        throw new Error(`refusing to read outside the working directory: ${file}`);
      }
      const code = readFileSync(resolved, 'utf8');
      const name = (values.name as string) ?? file.split('/').pop()!.replace(/\.[^.]+$/, '');
      out(await c.functions.deploy({ name, code }));
      return 0;
    }
    if (action === 'invoke') {
      const name = rest[0];
      if (!name) throw new Error('usage: baas functions invoke <name> [--data <json>]');
      out(await c.functions.invoke(name, parseData(values.data as string)));
      return 0;
    }
    if (action === 'list') {
      out(await c.functions.list());
      return 0;
    }
  }

  if (group === 'secrets') {
    if (action === 'set') {
      const [key, value] = rest;
      if (!key || value == null) throw new Error('usage: baas secrets set <KEY> <value> [--function <fn>]');
      out(await c.functions.setSecret({ key, value, function_name: values.function as string }));
      return 0;
    }
    if (action === 'list') {
      out(await c.functions.listSecrets());
      return 0;
    }
    if (action === 'rm') {
      const key = rest[0];
      if (!key) throw new Error('usage: baas secrets rm <KEY> [--function <fn>]');
      out(await c.functions.deleteSecret(key, values.function as string));
      return 0;
    }
  }

  if (group === 'triggers') {
    if (action === 'create') {
      const name = rest[0];
      const fn = values.function as string;
      if (!name || !fn) throw new Error('usage: baas triggers create <name> --function <fn> [--aggregates a,b] [--events x,y]');
      out(await c.functions.createTrigger({
        name,
        function_name: fn,
        aggregates: csv(values.aggregates as string),
        event_types: csv(values.events as string),
      }));
      return 0;
    }
    if (action === 'list') {
      out(await c.functions.listTriggers());
      return 0;
    }
    if (action === 'rm') {
      const id = rest[0];
      if (!id) throw new Error('usage: baas triggers rm <id>');
      out(await c.functions.deleteTrigger(id));
      return 0;
    }
  }

  process.stderr.write(`unknown command: ${[group, action].filter(Boolean).join(' ')}\n\n${USAGE}`);
  return 1;
}

// Only auto-run when invoked as a script (not when imported by tests).
const isMain = process.argv[1] && /baas(\.js|\.ts)?$/.test(process.argv[1]);
if (isMain) {
  run(process.argv.slice(2))
    .then((code) => process.exit(code))
    .catch((err) => {
      process.stderr.write(`error: ${err?.message ?? String(err)}\n`);
      process.exit(1);
    });
}
