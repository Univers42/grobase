import { useState } from 'react';
import { motion } from 'framer-motion';
import { HeartPulse, Plus, FileText } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import baas from '@/baas/client';
import FormModal from '@/components/ui/FormModal';

const TYPE_COLORS = {
  checkup:     'bg-blue-100 text-blue-700',
  vaccination: 'bg-green-100 text-green-700',
  surgery:     'bg-red-100 text-red-700',
  dental:      'bg-purple-100 text-purple-700',
  blood_work:  'bg-orange-100 text-orange-700',
  injury:      'bg-red-200 text-red-800',
  observation: 'bg-gray-100 text-gray-700',
};

const HEALTH_FIELDS = [
  { name: 'animal_id', label: 'Animal ID (ObjectId)', type: 'text', required: true, placeholder: '65a000000000000000000001' },
  { name: 'record_type', label: 'Type', type: 'select', required: true, options: [
    { value: 'checkup', label: 'Checkup' },
    { value: 'vaccination', label: 'Vaccination' },
    { value: 'surgery', label: 'Surgery' },
    { value: 'dental', label: 'Dental' },
    { value: 'blood_work', label: 'Blood Work' },
    { value: 'injury', label: 'Injury' },
    { value: 'observation', label: 'Observation' },
  ]},
  { name: 'vet_id', label: 'Vet ID (UUID)', type: 'text', placeholder: 'b1000000-0000-0000-0000-000000000004' },
  { name: 'diagnosis', label: 'Diagnosis', type: 'text', placeholder: 'Healthy, normal checkup' },
  { name: 'treatment', label: 'Treatment', type: 'textarea', colSpan: 2, placeholder: 'Treatment details…' },
  { name: 'weight_kg', label: 'Weight (kg)', type: 'number', step: '0.1' },
  { name: 'temperature_c', label: 'Temperature (°C)', type: 'number', step: '0.1' },
  { name: 'next_checkup', label: 'Next Checkup', type: 'date' },
  { name: 'notes', label: 'Notes', type: 'textarea', colSpan: 2 },
];

export default function AdminHealth() {
  const { data: records, loading, refetch } = useBaasCollection('health_records', {
    order: 'recorded_at.desc',
    limit: 50,
  });

  const [showForm, setShowForm] = useState(false);
  const [saving, setSaving]     = useState(false);

  const handleSave = async (data) => {
    setSaving(true);
    try {
      await baas.collection('health_records').insert({
        ...data,
        recorded_at: new Date().toISOString(),
      });
      setShowForm(false);
      refetch();
    } catch (err) {
      alert(`Error: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="font-display text-2xl font-bold text-forest">Health Records</h2>
          <p className="text-sm text-charcoal/50">Veterinary logs and medical history · {records?.length ?? 0} records</p>
        </div>
        <button onClick={() => setShowForm(true)} className="btn-primary text-sm">
          <Plus className="h-4 w-4" /> New Record
        </button>
      </div>

      {/* Cross-DB hint */}
      <div className="rounded-xl border border-sand bg-sand-light/40 px-4 py-3 text-xs text-charcoal/50">
        💡 <strong>Cross-DB relation demo:</strong> Health records live in PostgreSQL but reference Mongo animal IDs.
        The <code className="rounded bg-white px-1 py-0.5 font-mono text-forest">animal_with_health</code> relation
        joins them across databases.
      </div>

      {loading && <p className="text-charcoal/40">Loading records…</p>}

      <div className="space-y-3">
        {records?.map((r, i) => (
          <motion.div
            key={r.id}
            initial={{ opacity: 0, y: 10 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: Math.min(i * 0.03, 0.3) }}
            className="card flex items-start gap-4 p-5"
          >
            <div className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-xl bg-forest/10">
              <HeartPulse className="h-5 w-5 text-forest" />
            </div>

            <div className="flex-1 min-w-0">
              <div className="flex flex-wrap items-center gap-2">
                <span className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ${TYPE_COLORS[r.record_type] || 'bg-gray-100 text-gray-600'}`}>
                  {r.record_type?.replace('_', ' ')}
                </span>
                <span className="text-xs text-charcoal/40">
                  Animal: <span className="font-mono">{r.animal_id?.slice(0, 12)}…</span>
                </span>
              </div>
              {r.diagnosis && (
                <p className="mt-1 text-sm font-medium text-charcoal/80">{r.diagnosis}</p>
              )}
              {r.treatment && (
                <p className="mt-0.5 text-xs text-charcoal/50">{r.treatment}</p>
              )}
              <div className="mt-2 flex flex-wrap gap-4 text-xs text-charcoal/40">
                {r.weight_kg && <span>Weight: {r.weight_kg} kg</span>}
                {r.temperature_c && <span>Temp: {r.temperature_c}°C</span>}
                {r.next_checkup && <span>Next: {r.next_checkup}</span>}
              </div>
            </div>

            <span className="whitespace-nowrap text-xs text-charcoal/40">
              {new Date(r.recorded_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short', year: 'numeric' })}
            </span>
          </motion.div>
        ))}

        {!loading && (!records || records.length === 0) && (
          <div className="py-12 text-center">
            <FileText className="mx-auto h-10 w-10 text-charcoal/20" />
            <p className="mt-3 text-charcoal/40">No health records yet.</p>
          </div>
        )}
      </div>

      <FormModal
        open={showForm}
        onClose={() => setShowForm(false)}
        title="New Health Record"
        fields={HEALTH_FIELDS}
        onSubmit={handleSave}
        saving={saving}
        columns={2}
      />
    </div>
  );
}
