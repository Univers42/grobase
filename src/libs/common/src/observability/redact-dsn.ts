/* ************************************************************************** */
/*                                                                            */
/*                                                        :::      ::::::::   */
/*   redact-dsn.ts                                      :+:      :+:    :+:   */
/*                                                    +:+ +:+         +:+     */
/*   By: dlesieur <dlesieur@student.42.fr>          +#+  +:+       +#+        */
/*                                                +#+#+#+#+#+   +#+           */
/*   Created: 2026/10/30 00:00:00 by dlesieur          #+#    #+#             */
/*   Updated: 2026/10/30 00:00:00 by dlesieur         ###   ########.fr       */
/*                                                                            */
/* ************************************************************************** */

// The same two patterns as the control plane's httpx.RedactDSN, so a driver error
// reads the same once redacted whichever plane logged it (m230).
const URL_PATTERN = /[a-zA-Z][a-zA-Z0-9+.-]*:\/\/[^\s"'\\]+/g;
// libpq keyword form (`host=db password=secret`) carries no scheme.
const KEYWORD_PATTERN = /\b(password|passwd|pwd)\s*=\s*('[^']*'|[^\s"'\\;]+)/gi;

/**
 * Replace every `scheme://…` token and every `password=` value in `text`.
 *
 * Caveat: over-redacts — any URL in a message (a redirect target, a docs link)
 * becomes `[redacted-dsn]`. Under-redacts a password that holds a quote or a
 * space in the URL form, and one spelled other than password/passwd/pwd
 * (`secret=`, `token=`) in the keyword form.
 */
export function redactDsn(text: string): string {
  return text.replace(URL_PATTERN, '[redacted-dsn]').replace(KEYWORD_PATTERN, '$1=[redacted]');
}
