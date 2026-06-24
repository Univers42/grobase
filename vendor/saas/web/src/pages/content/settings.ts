// settings.ts — the typed shape of the `site.settings` content doc's `value`
// object, plus guard-based parse/serialize so the form never touches `any`.

import type { Row } from '../../lib/db';
import { isRecord, asString } from '../../lib/guards';

/** SETTINGS_KEY is the unique logical id of the settings content doc. */
export const SETTINGS_KEY = 'site.settings';

/** SiteSettings is the editable subset of the settings doc's nested `value`. */
export type SiteSettings = {
  siteName: string;
  tagline: string;
  supportEmail: string;
  theme: string;
};

/** FIELD_LABELS maps each setting key to its form label, in render order. */
export const FIELD_LABELS = [
  ['siteName', 'Site name'],
  ['tagline', 'Tagline'],
  ['supportEmail', 'Support email'],
  ['theme', 'Theme'],
] as const satisfies ReadonlyArray<readonly [keyof SiteSettings, string]>;

/** EMPTY_SETTINGS is the zero value used when initializing a missing doc. */
export const EMPTY_SETTINGS: SiteSettings = { siteName: '', tagline: '', supportEmail: '', theme: 'dark' };

/** parseSettings narrows an untrusted content `value` object to SiteSettings. */
export function parseSettings(value: unknown): SiteSettings {
  if (!isRecord(value)) return { ...EMPTY_SETTINGS };
  return {
    siteName: asString(value.siteName),
    tagline: asString(value.tagline),
    supportEmail: asString(value.supportEmail),
    theme: asString(value.theme, 'dark'),
  };
}

/** toContentDoc builds the upsert Row for the settings doc from edited values. */
export function toContentDoc(value: SiteSettings): Row {
  return { key: SETTINGS_KEY, type: 'settings', value: { ...value }, updated_at: new Date().toISOString() };
}
