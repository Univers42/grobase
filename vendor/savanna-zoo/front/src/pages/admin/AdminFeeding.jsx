import { useState, useCallback } from 'react';
import { motion } from 'framer-motion';
import { Utensils, Plus } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import useBaasRealtime from '@/hooks/useBaasRealtime';
import baas from '@/baas/client';
import FormModal from '@/components/ui/FormModal';

const FEEDING_FIELDS = [
  { name: 'animal_id', label: 'Animal ID (UUID)', type: 'text', required: true, placeholder: 'a0000000-0000-0000-0000-000000000001' },
  { name: 'keeper_id', label: 'Keeper ID (UUID)', type: 'text', required: true, placeholder: 'b1000000-0000-0000-0000-000000000002' },
  { name: 'food_type', label: 'Food Type', type: 'text', required: true, placeholder: 'Raw beef' },
  { name: 'quantity_kg', label: 'Quantity (kg)', type: 'number', step: '0.1', required: true, placeholder: '5.0' },
  { name: 'notes', label: 'Notes', type: 'textarea', colSpan: 2, placeholder: 'Any observations…' },
];

export default function AdminFeeding() {
  const { data: logs, loading, refetch } = useBaasCollection('feeding_logs', {
    order: 'fed_at.desc',
    limit: 50,
  });

  const [flash, setFlash]       = useState(false);
  const [showForm, setShowForm] = useState(false);
  const [saving, setSaving]     = useState(false);

  // Real-time: highlight new feeding logs as they arrive
  useBaasRealtime('feeding_logs', 'insert', useCallback(() => {
    refetch();
    setFlash(true);
    setTimeout(() => setFlash(false), 2000);
  }, [refetch]));

  const handleSave = async (data) => {
    setSaving(true);
    try {
      await baas.collection('feeding_logs').insert({
        ...data,
        fed_at: new Date(),
        created_at: new Date(),
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
          <h2 className="font-display text-2xl font-bold text-forest">Feeding Logs</h2>
          <p className="text-sm text-charcoal/50">
            Real-time feeding activity across all zones · {logs?.length ?? 0} entries
            {flash && (
              <span className="ml-2 animate-pulse rounded-full bg-green-100 px-2 py-0.5 text-xs font-bold text-green-700">
                New entry!
              </span>
            )}
          </p>
        </div>
        <button onClick={() => setShowForm(true)} className="btn-primary text-sm">
          <Plus className="h-4 w-4" /> Log Feeding
        </button>
      </div>

      {/* Hint about trigger */}
      <div className="rounded-xl border border-sand bg-sand-light/40 px-4 py-3 text-xs text-charcoal/50">
        💡 <strong>BaaS trigger demo:</strong> Creating a feeding log automatically updates the animal&apos;s{' '}
        <code className="rounded bg-white px-1 py-0.5 font-mono text-forest">last_fed</code> timestamp and increments{' '}
        <code className="rounded bg-white px-1 py-0.5 font-mono text-forest">total_feedings</code> via the{' '}
        <code className="rounded bg-white px-1 py-0.5 font-mono">feeding_log_update_animal</code> trigger.
      </div>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-sand bg-sand-light/50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Animal</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Keeper</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Food</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Qty (kg)</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Fed At</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-sand">
              {loading && (
                <tr><td colSpan={5} className="px-4 py-8 text-center text-charcoal/40">Loading…</td></tr>
              )}
              {logs?.map((log, i) => (
                <motion.tr
                  key={log.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: Math.min(i * 0.02, 0.3) }}
                  className="hover:bg-sand-light/30 transition-colors"
                >
                  <td className="px-4 py-3 font-mono text-xs text-charcoal/60">
                    {log.animal_id?.toString().slice(0, 12)}…
                  </td>
                  <td className="px-4 py-3 text-charcoal/70">{log.keeper_id?.slice(0, 8)}…</td>
                  <td className="px-4 py-3 font-medium text-forest">{log.food_type}</td>
                  <td className="px-4 py-3 text-right text-charcoal/60">{log.quantity_kg}</td>
                  <td className="px-4 py-3 text-right text-xs text-charcoal/40">
                    {new Date(log.fed_at).toLocaleString('en-GB', {
                      day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit',
                    })}
                  </td>
                </motion.tr>
              ))}
              {!loading && (!logs || logs.length === 0) && (
                <tr><td colSpan={5} className="px-4 py-8 text-center text-charcoal/40">No feeding logs recorded.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <FormModal
        open={showForm}
        onClose={() => setShowForm(false)}
        title="Log Feeding"
        fields={FEEDING_FIELDS}
        onSubmit={handleSave}
        saving={saving}
        columns={2}
      />
    </div>
  );
}
