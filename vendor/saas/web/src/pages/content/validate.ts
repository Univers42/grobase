// validate.ts — light, dependency-free form helpers for the settings form: an
// email-format check and a dirty comparison against the loaded baseline.

import type { SiteSettings } from './settings';

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

/** emailError returns a message when a non-empty email is malformed, else null. */
export function emailError(email: string): string | null {
  if (email.trim() === '') return null;
  return EMAIL_RE.test(email) ? null : 'Enter a valid email address';
}

/** isDirty reports whether the draft differs from the saved baseline. */
export function isDirty(draft: SiteSettings, baseline: SiteSettings): boolean {
  return (
    draft.siteName !== baseline.siteName ||
    draft.tagline !== baseline.tagline ||
    draft.supportEmail !== baseline.supportEmail ||
    draft.theme !== baseline.theme
  );
}
