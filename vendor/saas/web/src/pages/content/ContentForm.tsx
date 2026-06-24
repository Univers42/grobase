// ContentForm.tsx — the controlled settings form: labelled Field inputs for each
// site-settings key, light email validation, and a Save button disabled while
// saving or when nothing changed. Owns draft state; saving is delegated upward.

import { useState } from 'react';
import { Field } from '../../ds/Field';
import { Input } from '../../ds/Input';
import { Button } from '../../ds/Button';
import type { SiteSettings } from './settings';
import { FIELD_LABELS } from './settings';
import { emailError, isDirty } from './validate';

/** ContentFormProps feeds the loaded baseline and the persisting save action. */
export type ContentFormProps = {
  initial: SiteSettings;
  saving: boolean;
  onSave: (value: SiteSettings) => void;
};

/** ContentForm renders the editable settings fields with validation + dirty save. */
export function ContentForm({ initial, saving, onSave }: ContentFormProps) {
  const [draft, setDraft] = useState<SiteSettings>(initial);
  const emailMsg = emailError(draft.supportEmail);
  const dirty = isDirty(draft, initial);

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    if (!emailMsg && dirty) onSave(draft);
  };

  return (
    <form onSubmit={onSubmit} className="space-y-5" noValidate>
      <div className="grid gap-5 sm:grid-cols-2">
        {FIELD_LABELS.map(([key, label]) => (
          <Field key={key} label={label} error={key === 'supportEmail' ? emailMsg ?? undefined : undefined}>
            {({ id, describedBy, invalid }) => (
              <Input
                id={id}
                type={key === 'supportEmail' ? 'email' : 'text'}
                value={draft[key]}
                invalid={invalid}
                aria-describedby={describedBy}
                onChange={(e) => setDraft((d) => ({ ...d, [key]: e.target.value }))}
                placeholder={label}
              />
            )}
          </Field>
        ))}
      </div>
      <div className="flex items-center justify-end gap-3 pt-1">
        {!dirty && !saving && <span className="text-xs text-muted">All changes saved</span>}
        <Button type="submit" loading={saving} disabled={!dirty || Boolean(emailMsg)}>
          Save changes
        </Button>
      </div>
    </form>
  );
}
