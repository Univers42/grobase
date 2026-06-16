#!/usr/bin/env node
/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   codegen.mjs                                        :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/05/31 23:30:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/05/31 23:30:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Generate typed SDK clients (one per NestJS service) from the OpenAPI
// documents collected under apps/baas/mini-baas-infra/openapi/.
//
// Usage:
//   npm run codegen          (assumes specs already collected)
//   npm run codegen:all      (collect + generate)

import { promises as fs } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { generate } from 'openapi-typescript-codegen';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SDK_ROOT = path.resolve(__dirname, '..');
const SPECS_DIR = path.resolve(SDK_ROOT, '../mini-baas-infra/openapi');
const OUT_DIR = path.resolve(SDK_ROOT, 'src/generated');

async function exists(p) {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

async function main() {
  if (!(await exists(SPECS_DIR))) {
    console.error(`[codegen] specs dir missing: ${SPECS_DIR}`);
    console.error('[codegen] run `npm run openapi:collect` first (stack must be up).');
    process.exit(1);
  }

  const entries = (await fs.readdir(SPECS_DIR))
    .filter((f) => f.endsWith('.json') && f !== '.gitkeep');

  if (entries.length === 0) {
    console.error('[codegen] no .json specs found — collect them first.');
    process.exit(1);
  }

  await fs.rm(OUT_DIR, { recursive: true, force: true });
  await fs.mkdir(OUT_DIR, { recursive: true });

  let generated = 0;
  for (const file of entries) {
    const name = path.basename(file, '.json');
    const input = path.join(SPECS_DIR, file);
    const output = path.join(OUT_DIR, name);
    process.stdout.write(`  • ${name} → src/generated/${name}/ `);
    try {
      await generate({
        input,
        output,
        httpClient: 'fetch',
        clientName: `${pascal(name)}Client`,
        useOptions: true,
        useUnionTypes: true,
        exportCore: true,
        exportServices: true,
        exportModels: true,
        exportSchemas: false,
      });
      process.stdout.write('✓\n');
      generated++;
    } catch (err) {
      process.stdout.write(`✗ (${err instanceof Error ? err.message : err})\n`);
    }
  }

  // Aggregate index re-exports every client under a single import path.
  const indexLines = entries
    .map((f) => path.basename(f, '.json'))
    .map((name) => `export * as ${camel(name)} from './${name}/index.js';`);
  await fs.writeFile(path.join(OUT_DIR, 'index.ts'), indexLines.join('\n') + '\n');

  console.log(`\n[codegen] generated ${generated} client(s) into ${path.relative(SDK_ROOT, OUT_DIR)}`);
}

function pascal(s) {
  return s
    .split(/[-_]/)
    .map((p) => p.charAt(0).toUpperCase() + p.slice(1))
    .join('');
}

function camel(s) {
  const p = pascal(s);
  return p.charAt(0).toLowerCase() + p.slice(1);
}

try {
  await main();
} catch (err) {
  console.error('[codegen] fatal:', err);
  process.exit(1);
}
