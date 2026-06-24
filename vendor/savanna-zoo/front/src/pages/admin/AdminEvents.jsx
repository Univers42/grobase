import { useState } from 'react';
import { motion } from 'framer-motion';
import { Calendar, Plus, Pencil, Trash2 } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import baas from '@/baas/client';
import ZoneBadge from '@/components/ui/ZoneBadge';
import FormModal from '@/components/ui/FormModal';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

const TYPE_LABELS = {
  feeding_show:  'Feeding Show',
  guided_tour:   'Guided Tour',
  kids_workshop: "Kids' Workshop",
  night_safari:  'Night Safari',
  vip_experience:'VIP Experience',
};

const ZONE_OPTIONS = [
  { value: 'savannah', label: '🌾 Savannah' },
  { value: 'arctic', label: '❄️ Arctic' },
  { value: 'rainforest', label: '🌿 Rainforest' },
  { value: 'aquarium', label: '🐠 Aquarium' },
  { value: 'reptile', label: '🦎 Reptile House' },
  { value: 'aviary', label: '🦜 Aviary' },
  { value: 'petting', label: '🐰 Petting Zoo' },
];

const EVENT_FIELDS = [
  { name: 'title', label: 'Title', type: 'text', required: true, placeholder: 'Sunset Safari Walk' },
  { name: 'type', label: 'Type', type: 'select', required: true, options: [
    { value: 'feeding_show', label: 'Feeding Show' },
    { value: 'guided_tour', label: 'Guided Tour' },
    { value: 'kids_workshop', label: "Kids' Workshop" },
    { value: 'night_safari', label: 'Night Safari' },
    { value: 'vip_experience', label: 'VIP Experience' },
  ]},
  { name: 'zone', label: 'Zone', type: 'select', options: ZONE_OPTIONS },
  { name: 'host', label: 'Host', type: 'text', placeholder: 'Marcus Osei' },
  { name: 'start_at', label: 'Start', type: 'datetime-local', required: true },
  { name: 'end_at', label: 'End', type: 'datetime-local' },
  { name: 'capacity', label: 'Capacity', type: 'number', required: true, placeholder: '30' },
  { name: 'price_eur', label: 'Price (€)', type: 'number', step: '0.01', placeholder: '0.00' },
  { name: 'description', label: 'Description', type: 'textarea', colSpan: 2, placeholder: 'What visitors will experience…' },
  { name: 'is_free', label: 'Free event', type: 'checkbox' },
  { name: 'is_active', label: 'Active', type: 'checkbox', default: true },
];

export default function AdminEvents() {
  const { data: events, loading, refetch } = useBaasCollection('events', {
    order: 'start_at.asc',
  });

  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing]   = useState(null);
  const [deleting, setDeleting] = useState(null);
  const [saving, setSaving]     = useState(false);

  const openCreate = () => { setEditing(null); setShowForm(true); };
  const openEdit   = (evt) => { setEditing(evt); setShowForm(true); };

  const handleSave = async (data) => {
    setSaving(true);
    try {
      if (editing) {
        await baas.collection('events').eq('id', editing.id).update(data);
      } else {
        await baas.collection('events').insert({
          ...data,
          registrations: 0,
          is_full: false,
          created_at: new Date(),
          updated_at: new Date(),
        });
      }
      setShowForm(false);
      setEditing(null);
      refetch();
    } catch (err) {
      alert(`Error: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  const handleDelete = async () => {
    if (!deleting) return;
    setSaving(true);
    try {
      await baas.collection('events').eq('id', deleting.id).remove();
      setDeleting(null);
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
          <h2 className="font-display text-2xl font-bold text-forest">Events</h2>
          <p className="text-sm text-charcoal/50">Manage zoo events and experiences · {events?.length ?? 0} total</p>
        </div>
        <button onClick={openCreate} className="btn-primary text-sm">
          <Plus className="h-4 w-4" /> Create Event
        </button>
      </div>

      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-sand bg-sand-light/50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Event</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Type</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Zone</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Date</th>
                <th className="px-4 py-3 text-center font-medium text-charcoal/60">Capacity</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Price</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-sand">
              {loading && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">Loading…</td></tr>
              )}
              {events?.map((evt, i) => (
                <motion.tr
                  key={evt.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: Math.min(i * 0.03, 0.3) }}
                  className="hover:bg-sand-light/30 transition-colors"
                >
                  <td className="px-4 py-3">
                    <p className="font-medium text-forest">{evt.title}</p>
                    <p className="text-xs text-charcoal/40">{evt.host}</p>
                  </td>
                  <td className="px-4 py-3 text-charcoal/60">
                    {TYPE_LABELS[evt.type] || evt.type}
                  </td>
                  <td className="px-4 py-3"><ZoneBadge zone={evt.zone} /></td>
                  <td className="px-4 py-3 text-xs text-charcoal/60">
                    {new Date(evt.start_at).toLocaleDateString('en-GB', { day: '2-digit', month: 'short' })}
                  </td>
                  <td className="px-4 py-3 text-center">
                    <div className="text-charcoal/60">
                      {evt.registrations}/{evt.capacity}
                    </div>
                    {evt.is_full && (
                      <span className="text-[10px] font-bold text-red-600">FULL</span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-right font-medium">
                    {evt.is_free ? (
                      <span className="text-green-600">Free</span>
                    ) : (
                      <span>€{evt.price_eur}</span>
                    )}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => openEdit(evt)}
                      className="mr-2 text-charcoal/40 hover:text-forest transition-colors"
                    >
                      <Pencil className="h-4 w-4" />
                    </button>
                    <button
                      onClick={() => setDeleting(evt)}
                      className="text-charcoal/40 hover:text-red-600 transition-colors"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </td>
                </motion.tr>
              ))}
              {!loading && (!events || events.length === 0) && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">No events.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      <FormModal
        open={showForm}
        onClose={() => { setShowForm(false); setEditing(null); }}
        title={editing ? `Edit — ${editing.title}` : 'Create Event'}
        fields={EVENT_FIELDS}
        initialValues={editing || { is_active: true }}
        onSubmit={handleSave}
        saving={saving}
        columns={2}
      />

      <ConfirmDialog
        open={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={handleDelete}
        title="Delete Event"
        message={`Remove "${deleting?.title}"? This cannot be undone.`}
        loading={saving}
      />
    </div>
  );
}
