/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   cli.test.mjs                                       :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/13 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/13 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */
//
// Unit tests for the `baas` CLI argument parsing + pure helpers. Run against
// the BUILT output (`npm run build && npm test`). No network, no real client.

import test from 'node:test';
import assert from 'node:assert/strict';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { mkdtempSync, rmSync } from 'node:fs';

import { parseCli, csv, parseData, saveConfig, loadConfig, configPath } from '../dist/bin/baas.js';

test('parseCli splits command path + options', () => {
  const { positionals, values } = parseCli(['functions', 'deploy', 'hello.ts', '--name', 'hello']);
  assert.deepEqual(positionals, ['functions', 'deploy', 'hello.ts']);
  assert.equal(values.name, 'hello');
});

test('parseCli captures triggers create flags', () => {
  const { positionals, values } = parseCli([
    'triggers', 'create', 'on-order',
    '--function', 'notify', '--aggregates', 'orders,users', '--events', 'created',
  ]);
  assert.deepEqual(positionals, ['triggers', 'create', 'on-order']);
  assert.equal(values.function, 'notify');
  assert.equal(values.aggregates, 'orders,users');
  assert.equal(values.events, 'created');
});

test('parseCli treats --help as a boolean', () => {
  const { values } = parseCli(['--help']);
  assert.equal(values.help, true);
});

test('csv trims, drops empties, and returns undefined for nullish', () => {
  assert.deepEqual(csv('orders, users ,, payments'), ['orders', 'users', 'payments']);
  assert.equal(csv(undefined), undefined);
  assert.equal(csv('   ,  '), undefined);
});

test('parseData parses JSON, falls back to raw string', () => {
  assert.deepEqual(parseData('{"a":1}'), { a: 1 });
  assert.deepEqual(parseData('[1,2]'), [1, 2]);
  assert.equal(parseData('plain text'), 'plain text');
  assert.equal(parseData(undefined), undefined);
});

test('saveConfig/loadConfig round-trip via $GROBASE_CONFIG', () => {
  const dir = mkdtempSync(join(tmpdir(), 'grobase-cli-'));
  const prev = process.env.GROBASE_CONFIG;
  process.env.GROBASE_CONFIG = join(dir, 'config.json');
  try {
    assert.equal(configPath(), join(dir, 'config.json'));
    assert.deepEqual(loadConfig(), {}, 'absent config => {}');
    saveConfig({ url: 'https://baas.test', anonKey: 'a', serviceRoleKey: 's' });
    const loaded = loadConfig();
    assert.equal(loaded.url, 'https://baas.test');
    assert.equal(loaded.serviceRoleKey, 's');
  } finally {
    if (prev === undefined) delete process.env.GROBASE_CONFIG;
    else process.env.GROBASE_CONFIG = prev;
    rmSync(dir, { recursive: true, force: true });
  }
});
