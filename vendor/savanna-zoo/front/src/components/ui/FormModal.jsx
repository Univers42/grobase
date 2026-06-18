import { useState, useEffect } from 'react';
import Modal from './Modal';

/**
 * Generic form modal driven by a field-definition array.
 *
 * Each field: { name, label, type, options?, required?, placeholder?, step?, default?, colSpan? }
 *   type: text | email | number | textarea | select | checkbox | date | datetime-local
 *   options (for select): [{ value, label }]
 *   colSpan: 2 to span full width in 2-col layout
 */
export default function FormModal({
  open,
  onClose,
  title,
  fields,
  initialValues = {},
  onSubmit,
  saving = false,
  columns = 1,
}) {
  const [values, setValues] = useState({});
  const [error, setError]   = useState('');

  // Reset form when modal opens or initialValues change
  useEffect(() => {
    if (open) {
      const defaults = {};
      fields.forEach((f) => {
        if (f.type === 'checkbox') {
          defaults[f.name] = initialValues[f.name] ?? f.default ?? false;
        } else if (f.type === 'datetime-local' && initialValues[f.name]) {
          // Convert ISO to datetime-local format
          defaults[f.name] = initialValues[f.name].slice(0, 16);
        } else {
          defaults[f.name] = initialValues[f.name] ?? f.default ?? '';
        }
      });
      setValues(defaults);
      setError('');
    }
  }, [open, initialValues]); // eslint-disable-line react-hooks/exhaustive-deps

  const set = (name, value) => setValues((prev) => ({ ...prev, [name]: value }));

  const handleSubmit = (e) => {
    e.preventDefault();
    setError('');
    // Convert types
    const data = {};
    fields.forEach((f) => {
      let v = values[f.name];
      if (f.type === 'number' && v !== '' && v != null) v = Number(v);
      if (f.type === 'checkbox') v = Boolean(v);
      // Skip empty optional fields
      if (!f.required && (v === '' || v == null)) return;
      data[f.name] = v;
    });
    onSubmit(data);
  };

  const inputClass =
    'w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20 transition';

  const gridClass = columns === 2 ? 'grid grid-cols-2 gap-4' : 'space-y-4';

  return (
    <Modal open={open} onClose={onClose} title={title} wide={columns === 2}>
      <form onSubmit={handleSubmit} className={gridClass}>
        {fields.map((f) => {
          const spanClass = columns === 2 && f.colSpan === 2 ? 'col-span-2' : '';

          if (f.type === 'checkbox') {
            return (
              <label
                key={f.name}
                className={`flex items-center gap-3 ${spanClass} ${columns === 2 ? '' : ''}`}
              >
                <input
                  type="checkbox"
                  checked={!!values[f.name]}
                  onChange={(e) => set(f.name, e.target.checked)}
                  className="h-4 w-4 rounded border-sand text-forest focus:ring-forest/30"
                />
                <span className="text-sm text-charcoal/70">{f.label}</span>
              </label>
            );
          }

          if (f.type === 'select') {
            return (
              <div key={f.name} className={spanClass}>
                <label className="mb-1 block text-sm font-medium text-charcoal/60">
                  {f.label}
                  {f.required && <span className="text-red-400"> *</span>}
                </label>
                <select
                  value={values[f.name] || ''}
                  onChange={(e) => set(f.name, e.target.value)}
                  required={f.required}
                  className={inputClass}
                >
                  <option value="">— Select —</option>
                  {f.options?.map((o) => (
                    <option key={o.value} value={o.value}>
                      {o.label}
                    </option>
                  ))}
                </select>
              </div>
            );
          }

          if (f.type === 'textarea') {
            return (
              <div key={f.name} className={spanClass}>
                <label className="mb-1 block text-sm font-medium text-charcoal/60">
                  {f.label}
                  {f.required && <span className="text-red-400"> *</span>}
                </label>
                <textarea
                  value={values[f.name] || ''}
                  onChange={(e) => set(f.name, e.target.value)}
                  required={f.required}
                  placeholder={f.placeholder}
                  rows={3}
                  className={inputClass + ' resize-none'}
                />
              </div>
            );
          }

          // text, email, number, date, datetime-local
          return (
            <div key={f.name} className={spanClass}>
              <label className="mb-1 block text-sm font-medium text-charcoal/60">
                {f.label}
                {f.required && <span className="text-red-400"> *</span>}
              </label>
              <input
                type={f.type || 'text'}
                value={values[f.name] ?? ''}
                onChange={(e) => set(f.name, e.target.value)}
                required={f.required}
                placeholder={f.placeholder}
                step={f.step}
                min={f.min}
                max={f.max}
                className={inputClass}
              />
            </div>
          );
        })}

        {/* Error */}
        {error && (
          <div className={`rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700 ${columns === 2 ? 'col-span-2' : ''}`}>
            {error}
          </div>
        )}

        {/* Buttons */}
        <div className={`flex justify-end gap-3 pt-2 ${columns === 2 ? 'col-span-2' : ''}`}>
          <button type="button" onClick={onClose} className="btn-secondary text-sm">
            Cancel
          </button>
          <button type="submit" disabled={saving} className="btn-primary text-sm disabled:opacity-50">
            {saving ? 'Saving…' : 'Save'}
          </button>
        </div>
      </form>
    </Modal>
  );
}
