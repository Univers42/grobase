// useSettings.ts — loads the `site.settings` content doc from the Mongo mount and
// exposes a save that upserts it back, keeping {settings,loading,error,exists}.

import { useCallback, useEffect, useState } from 'react';
import { useBaas } from '../../providers/useBaas';
import type { SiteSettings } from './settings';
import { SETTINGS_KEY, EMPTY_SETTINGS, parseSettings, toContentDoc } from './settings';

/** SettingsState is the reactive settings snapshot plus the save action. */
export type SettingsState = {
  settings: SiteSettings;
  exists: boolean;
  loading: boolean;
  error: string | null;
  save: (value: SiteSettings) => Promise<void>;
};

/** message extracts a human string from an unknown thrown value. */
function message(e: unknown, fallback: string): string {
  return e instanceof Error ? e.message : fallback;
}

/** useSettings loads the settings doc once and returns a persisting `save`. */
export function useSettings(): SettingsState {
  const { db } = useBaas();
  const [settings, setSettings] = useState<SiteSettings>(EMPTY_SETTINGS);
  const [exists, setExists] = useState(false);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    setError(null);
    db.mongo
      .list('content', { filter: { key: { $eq: SETTINGS_KEY } } })
      .then((r) => {
        if (cancelled) return;
        const first = r.rows[0];
        setExists(Boolean(first));
        setSettings(first ? parseSettings(first.value) : EMPTY_SETTINGS);
      })
      .catch((e: unknown) => !cancelled && setError(message(e, 'failed to load settings')))
      .finally(() => !cancelled && setLoading(false));
    return () => {
      cancelled = true;
    };
  }, [db]);

  const save = useCallback(
    async (value: SiteSettings) => {
      await db.mongo.upsert('content', toContentDoc(value));
      setSettings(value);
      setExists(true);
    },
    [db],
  );

  return { settings, exists, loading, error, save };
}
