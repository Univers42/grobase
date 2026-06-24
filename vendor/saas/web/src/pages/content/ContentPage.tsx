// ContentPage.tsx — the content/settings section. Loads the `site.settings`
// content doc from the Mongo mount, edits it through a glass form, and upserts it
// back. Spinner while loading, an initialize empty-state when no doc exists yet,
// and success/error toasts on save.

import { useState } from 'react';
import { GlassCard } from '../../ds/GlassCard';
import { Spinner } from '../../ds/Spinner';
import { EmptyState } from '../../ds/EmptyState';
import { Button } from '../../ds/Button';
import { useToast } from '../../providers/useToast';
import { ContentForm } from './ContentForm';
import { PagesList } from './PagesList';
import { useSettings } from './useSettings';
import { EMPTY_SETTINGS } from './settings';
import type { SiteSettings } from './settings';

/** ContentHeader renders the section title + lede shared across states. */
function ContentHeader() {
  return (
    <header>
      <h1 className="text-2xl font-semibold tracking-tight text-ink">Content & settings</h1>
      <p className="mt-1 text-sm text-muted">Manage your site identity and content pages.</p>
    </header>
  );
}

/** ContentPage orchestrates loading, editing, and saving the settings doc. */
export function ContentPage() {
  const toast = useToast();
  const { settings, exists, loading, error, save } = useSettings();
  const [saving, setSaving] = useState(false);

  const onSave = (value: SiteSettings) => {
    setSaving(true);
    save(value)
      .then(() => toast.success('Settings saved', 'Your site settings are live.'))
      .catch((e: unknown) => toast.error('Save failed', e instanceof Error ? e.message : 'Please try again.'))
      .finally(() => setSaving(false));
  };

  return (
    <section className="space-y-5">
      <ContentHeader />
      {loading ? (
        <GlassCard className="grid place-items-center py-16">
          <Spinner size={28} label="Loading settings" />
        </GlassCard>
      ) : error ? (
        <GlassCard>
          <EmptyState icon="alert" title="Couldn't load settings" description={error} />
        </GlassCard>
      ) : !exists ? (
        <GlassCard>
          <EmptyState
            icon="settings"
            title="No settings yet"
            description="Initialize your site settings to get started."
            action={
              <Button loading={saving} onClick={() => onSave(EMPTY_SETTINGS)}>
                Initialize settings
              </Button>
            }
          />
        </GlassCard>
      ) : (
        <GlassCard glow>
          <ContentForm initial={settings} saving={saving} onSave={onSave} />
        </GlassCard>
      )}
      <PagesList />
    </section>
  );
}
