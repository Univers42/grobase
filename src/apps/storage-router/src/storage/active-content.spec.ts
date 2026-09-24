/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   active-content.spec.ts                             :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import { afterEach, describe, expect, it, jest } from '@jest/globals';
import type { UserContext } from '@mini-baas/common';
import type { Request, Response } from 'express';
import { activeContentHeaders } from './active-content';
import { StorageController } from './storage.controller';
import type { StorageService } from './storage.service';

const FLAG = 'STORAGE_ACTIVE_CONTENT_GUARD_ENABLED';
const ON = { [FLAG]: '1' } as NodeJS.ProcessEnv;
const NOSNIFF = { 'X-Content-Type-Options': 'nosniff' };
const GUARDED = {
  'X-Content-Type-Options': 'nosniff',
  'Content-Security-Policy': 'sandbox',
  'Content-Disposition': 'attachment',
};

/** Drives StorageController.download for an object of `contentType` and returns the res mock. */
async function download(contentType: string, path = '/storage/v1/object/b/pic.svg') {
  const service = {
    getObject: async () => ({ body: Buffer.from('<svg/>'), contentType, size: 6 }),
  } as unknown as StorageService;
  const res = {
    setHeader: jest.fn(),
    end: jest.fn((_body: unknown, done: () => void) => done()),
  };
  await new StorageController(service).download(
    { id: 'u1', role: 'authenticated' } as unknown as UserContext,
    'b',
    { path, url: path, query: {} } as unknown as Request,
    res as unknown as Response,
  );
  return res;
}

afterEach(() => {
  delete process.env[FLAG];
});

describe('activeContentHeaders', () => {
  it('OFF (unset, 0, garbage): returns no header for any type', () => {
    for (const env of [{}, { [FLAG]: '0' }, { [FLAG]: 'nope' }] as NodeJS.ProcessEnv[]) {
      for (const type of ['image/svg+xml', 'text/html', 'image/png', '']) {
        expect(activeContentHeaders(type, env)).toEqual({});
      }
    }
  });

  it('ON: active or unknown types get nosniff + sandbox + attachment', () => {
    for (const type of [
      'image/svg+xml',
      'Image/SVG+XML; charset=utf-8',
      '  text/html  ',
      'TEXT/HTML',
      'application/xhtml+xml',
      'application/xml',
      'text/xml',
      'application/javascript',
      'text/html2',
      'text/html,text/plain',
      'image/png,text/html',
      'image/png; x=1, text/html',
      'image/svg',
      'image/png text/html',
      'image/',
      'textplain',
      'imagex',
      'videoo',
      'audiox',
      'image',
      '/png',
      '',
    ]) {
      expect(activeContentHeaders(type, ON)).toEqual(GUARDED);
    }
  });

  it('ON: the passive allowlist gets nosniff only', () => {
    for (const type of [
      'image/png',
      'IMAGE/JPEG',
      ' image/webp ',
      'image/vnd.microsoft.icon',
      'image/avif; q=1',
      'video/mp4',
      'audio/mpeg',
      'text/plain',
      'text/plain; charset=utf-8',
      'application/octet-stream',
      'application/pdf',
      'application/json',
    ]) {
      expect(activeContentHeaders(type, ON)).toEqual(NOSNIFF);
    }
  });

  it('accepts the storage plane flag spellings', () => {
    for (const value of ['1', 'true', 'YES', ' on ']) {
      expect(activeContentHeaders('text/html', { [FLAG]: value })).toEqual(GUARDED);
    }
  });
});

describe('StorageController.download guard wiring', () => {
  it('OFF: sets exactly Content-Type and Content-Length, as before', async () => {
    const res = await download('image/svg+xml');
    expect(res.setHeader.mock.calls).toEqual([
      ['Content-Type', 'image/svg+xml'],
      ['Content-Length', '6'],
    ]);
  });

  it('ON: an SVG is served with the constant guard headers, never the object key', async () => {
    process.env[FLAG] = '1';
    const res = await download(
      'image/svg+xml',
      '/storage/v1/object/b/x%0d%0aSet-Cookie:%20a=1.svg',
    );
    expect(res.setHeader.mock.calls).toEqual([
      ['Content-Type', 'image/svg+xml'],
      ['Content-Length', '6'],
      ['X-Content-Type-Options', 'nosniff'],
      ['Content-Security-Policy', 'sandbox'],
      ['Content-Disposition', 'attachment'],
    ]);
  });

  it('ON: a passive image only gains nosniff', async () => {
    process.env[FLAG] = '1';
    const res = await download('image/png');
    expect(res.setHeader.mock.calls).toEqual([
      ['Content-Type', 'image/png'],
      ['Content-Length', '6'],
      ['X-Content-Type-Options', 'nosniff'],
    ]);
  });
});
