/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   active-content.ts                                  :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/09/23 00:00:00 by dlesieur          #+#    #+#             */
/*                                                +#+#+#+#+#+   +#+           */
/* ************************************************************************** */

import { isTruthy } from './feature-flag';

/**
 * @brief Serve-time guard headers for a downloaded object (L-9, stored XSS via upload).
 *
 * STORAGE_ACTIVE_CONTENT_GUARD_ENABLED OFF (default) → `{}`: the download is
 * byte-identical. ON → always `X-Content-Type-Options: nosniff`; any type NOT on
 * the passive allowlist (`isPassiveType`) also gets `Content-Security-Policy:
 * sandbox` + `Content-Disposition: attachment`, so SVG/HTML/XML — or a type
 * nobody listed — is downloaded, not rendered on the app's origin, and could not
 * script it if it were. For that response the sandbox policy replaces the
 * app-wide helmet CSP; with no allow-* token it is stricter on scripts, forms,
 * plugins and origin access. Values are constants: the object key never reaches
 * a header. Stored bytes are never touched.
 *
 * @param contentType the Content-Type being served (the uploader's, or a transform's)
 */
export function activeContentHeaders(
  contentType: string,
  env: NodeJS.ProcessEnv = process.env,
): Record<string, string> {
  if (!isTruthy(env['STORAGE_ACTIVE_CONTENT_GUARD_ENABLED'])) return {};
  if (isPassiveType(contentType)) return { 'X-Content-Type-Options': 'nosniff' };
  return {
    'X-Content-Type-Options': 'nosniff',
    'Content-Security-Policy': 'sandbox',
    'Content-Disposition': 'attachment',
  };
}

/**
 * True only for types a browser never runs as a document. Fails closed: a comma
 * (browsers take the LAST type of a list), an empty or slash-less value, or any
 * type not listed here counts as active.
 */
function isPassiveType(contentType: string): boolean {
  if (contentType.includes(',')) return false;
  const mime = contentType.split(';')[0].trim().toLowerCase();
  switch (mime) {
    case 'text/plain':
    case 'application/octet-stream':
    case 'application/pdf':
    case 'application/json':
      return true;
    default:
      return isPassiveMedia(mime);
  }
}

/**
 * `image/*`, `video/*` or `audio/*` with a plain subtype that is not SVG or XML.
 * A slash-less value (`imagex`) is active: `indexOf` returns -1, which must not
 * reach `slice` as an end index.
 */
function isPassiveMedia(mime: string): boolean {
  const slash = mime.indexOf('/');
  if (slash < 0) return false;
  const subtype = mime.slice(slash + 1);
  switch (mime.slice(0, slash)) {
    case 'image':
    case 'video':
    case 'audio':
      return isPlainSubtype(subtype) && !subtype.includes('svg') && !subtype.includes('xml');
    default:
      return false;
  }
}

/** Non-empty and only `a-z 0-9 . + -` (so `png text/html` or `png"` is not plain). */
function isPlainSubtype(subtype: string): boolean {
  if (subtype.length === 0) return false;
  for (const ch of subtype) {
    const plain = (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || '.+-'.includes(ch);
    if (!plain) return false;
  }
  return true;
}
