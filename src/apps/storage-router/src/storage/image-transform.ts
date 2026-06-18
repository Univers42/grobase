/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   image-transform.ts                                 :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/06/14 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/06/14 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// A1 (Track-A → 100%) — on-the-fly image TRANSFORMS for the storage plane:
// resize (width/height) + reformat (webp/jpeg/png/avif), Supabase-shaped, served
// from the EXISTING owner-scoped GET path. sharp is the idiomatic Node image lib;
// it is imported LAZILY (only when the flag is ON), so the default (flag-OFF)
// runtime never even loads the native binding — the download path is byte-parity.
//
// ## Parity (flag OFF — the default)
//
// `parseTransform` returns `undefined` whenever STORAGE_TRANSFORMS_ENABLED is OFF
// (regardless of query params), and `undefined` when the flag is ON but the request
// carries NO transform params. In both cases the controller serves the original
// object bytes verbatim — byte-identical to the pre-transform storage-router.
//
// ## Why a query on GET (not a separate route)
//
// `GET …/object/<bucket>/<key>?width=&height=&format=` keeps ONE owner-scoped read
// path (the policy + owner-prefix logic is shared, not duplicated). A bare GET (no
// params) is the unchanged original-bytes path; params opt INTO a derived variant.

import { BadRequestException, Logger } from '@nestjs/common';

const log = new Logger('ImageTransform');

/** Output formats sharp will encode to (the safe, ubiquitous web set). */
export const TRANSFORM_FORMATS = ['webp', 'jpeg', 'jpg', 'png', 'avif'] as const;
export type TransformFormat = (typeof TRANSFORM_FORMATS)[number];

/** A validated, bounded transform request (never trusts raw query ints). */
export interface TransformSpec {
  width?: number;
  height?: number;
  format?: TransformFormat;
  quality?: number;
}

const MAX_DIM = 5000; // hard cap — a transform must not become a memory-DoS lever
const MIN_DIM = 1;

/**
 * Parse + validate the transform query IFF the flag is ON. Returns:
 *   • `undefined` when the flag is OFF (parity — params are ignored entirely), OR
 *   • `undefined` when the flag is ON but no transform param is present (original
 *     bytes path), OR
 *   • a bounded `TransformSpec` when at least one valid param is present.
 * Throws BadRequest on an out-of-range/garbage param (fail-closed on bad input).
 */
export function parseTransform(
  query: Record<string, unknown>,
  env: NodeJS.ProcessEnv = process.env,
): TransformSpec | undefined {
  if (!isTruthy(env['STORAGE_TRANSFORMS_ENABLED'])) return undefined;

  const width = intParam(query['width'], 'width');
  const height = intParam(query['height'], 'height');
  const format = formatParam(query['format']);
  const quality = qualityParam(query['quality']);

  if (width === undefined && height === undefined && format === undefined) {
    return undefined; // flag ON but no transform asked → original bytes (parity)
  }
  return { width, height, format, quality };
}

/** True when this object can be transformed (image content types only). */
export function isTransformableType(contentType: string): boolean {
  return /^image\//i.test(contentType) && !/svg/i.test(contentType);
}

/**
 * Apply the transform with sharp (lazy-imported so OFF builds never load it).
 * Returns the encoded bytes + the resulting MIME type. Resize uses `inside` fit
 * (preserve aspect, never enlarge) so a 64×64 ask on a smaller source returns the
 * source dims, and a larger source is shrunk to fit the box.
 */
export async function applyTransform(
  input: Buffer,
  spec: TransformSpec,
  sourceContentType: string,
): Promise<{ body: Buffer; contentType: string }> {
  const sharp = (await import('sharp')).default;
  let pipeline = sharp(input, { failOn: 'none' });

  if (spec.width !== undefined || spec.height !== undefined) {
    pipeline = pipeline.resize({
      width: spec.width,
      height: spec.height,
      fit: 'inside',
      withoutEnlargement: true,
    });
  }

  const fmt = spec.format ?? formatFromContentType(sourceContentType);
  const quality = spec.quality;
  switch (fmt) {
    case 'webp':
      pipeline = pipeline.webp(quality ? { quality } : {});
      break;
    case 'jpeg':
    case 'jpg':
      pipeline = pipeline.jpeg(quality ? { quality } : {});
      break;
    case 'png':
      pipeline = pipeline.png();
      break;
    case 'avif':
      pipeline = pipeline.avif(quality ? { quality } : {});
      break;
    default:
      // Unknown source type with no explicit format → re-encode as webp (safe).
      pipeline = pipeline.webp(quality ? { quality } : {});
      return { body: await pipeline.toBuffer(), contentType: 'image/webp' };
  }
  const body = await pipeline.toBuffer();
  log.debug(`transform → ${fmt} ${spec.width ?? '-'}x${spec.height ?? '-'} (${body.byteLength}B)`);
  return { body, contentType: mimeForFormat(fmt) };
}

// ── helpers ────────────────────────────────────────────────────────────────

function intParam(value: unknown, name: string): number | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  const n = Number(Array.isArray(value) ? value[0] : value);
  if (!Number.isInteger(n) || n < MIN_DIM || n > MAX_DIM) {
    throw new BadRequestException(`${name} must be an integer in [${MIN_DIM}, ${MAX_DIM}]`);
  }
  return n;
}

function qualityParam(value: unknown): number | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  const n = Number(Array.isArray(value) ? value[0] : value);
  if (!Number.isInteger(n) || n < 1 || n > 100) {
    throw new BadRequestException('quality must be an integer in [1, 100]');
  }
  return n;
}

function formatParam(value: unknown): TransformFormat | undefined {
  if (value === undefined || value === null || value === '') return undefined;
  const v = String(Array.isArray(value) ? value[0] : value).toLowerCase();
  if (!(TRANSFORM_FORMATS as readonly string[]).includes(v)) {
    throw new BadRequestException(`format must be one of ${TRANSFORM_FORMATS.join('|')}`);
  }
  return v as TransformFormat;
}

function formatFromContentType(ct: string): TransformFormat | undefined {
  const m = /^image\/(webp|jpeg|jpg|png|avif)/i.exec(ct);
  return m ? (m[1].toLowerCase() as TransformFormat) : undefined;
}

function mimeForFormat(fmt: TransformFormat): string {
  return fmt === 'jpg' ? 'image/jpeg' : `image/${fmt}`;
}

function isTruthy(value: string | undefined): boolean {
  if (!value) return false;
  return ['1', 'true', 'yes', 'on'].includes(value.trim().toLowerCase());
}
