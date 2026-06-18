import { useEffect, useState } from 'react';
import { motion } from 'framer-motion';
import { Plus, Pencil, Trash2, Search } from 'lucide-react';
import { useAnimalStore } from '@/stores/animalStore';
import baas from '@/baas/client';
import ZoneBadge, { ZONE_CONFIG } from '@/components/ui/ZoneBadge';
import StatusBadge from '@/components/ui/StatusBadge';
import ConservationBadge from '@/components/ui/ConservationBadge';
import useBaasRealtime from '@/hooks/useBaasRealtime';
import FormModal from '@/components/ui/FormModal';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

// ── Field definitions ─────────────────────────────────────────
const ZONE_OPTIONS = [
  { value: 'savannah', label: '🌾 Savannah' },
  { value: 'arctic', label: '❄️ Arctic' },
  { value: 'rainforest', label: '🌿 Rainforest' },
  { value: 'aquarium', label: '🐠 Aquarium' },
  { value: 'reptile', label: '🦎 Reptile House' },
  { value: 'aviary', label: '🦜 Aviary' },
  { value: 'petting', label: '🐰 Petting Zoo' },
];

const ANIMAL_FIELDS = [
  { name: 'name', label: 'Name', type: 'text', required: true, placeholder: 'Kibo', colSpan: 1 },
  { name: 'common_name', label: 'Common Name', type: 'text', required: true, placeholder: 'African Lion' },
  { name: 'species', label: 'Species (Latin)', type: 'text', required: true, placeholder: 'Panthera leo' },
  { name: 'zone', label: 'Zone', type: 'select', required: true, options: ZONE_OPTIONS },
  { name: 'status', label: 'Status', type: 'select', required: true, options: [
    { value: 'active', label: 'Active' }, { value: 'resting', label: 'Resting' },
    { value: 'medical', label: 'Medical' }, { value: 'quarantine', label: 'Quarantine' },
    { value: 'breeding', label: 'Breeding' },
  ]},
  { name: 'sex', label: 'Sex', type: 'select', options: [
    { value: 'male', label: 'Male' }, { value: 'female', label: 'Female' },
  ]},
  { name: 'conservation_status', label: 'IUCN Status', type: 'select', options: [
    { value: 'LC', label: 'Least Concern' }, { value: 'NT', label: 'Near Threatened' },
    { value: 'VU', label: 'Vulnerable' }, { value: 'EN', label: 'Endangered' },
    { value: 'CR', label: 'Critically Endangered' },
  ]},
  { name: 'diet_type', label: 'Diet', type: 'select', options: [
    { value: 'carnivore', label: 'Carnivore' }, { value: 'herbivore', label: 'Herbivore' },
    { value: 'omnivore', label: 'Omnivore' },
  ]},
  { name: 'weight_kg', label: 'Weight (kg)', type: 'number', step: '0.1', placeholder: '190' },
  { name: 'height_cm', label: 'Height (cm)', type: 'number', step: '0.1', placeholder: '120' },
  { name: 'date_of_birth', label: 'Date of Birth', type: 'date' },
  { name: 'origin', label: 'Origin', type: 'text', placeholder: 'Born at Savanna Park Zoo' },
  { name: 'description', label: 'Description', type: 'textarea', colSpan: 2, placeholder: 'Brief description of the animal…' },
  { name: 'is_featured', label: 'Featured on homepage', type: 'checkbox', colSpan: 2 },
];

export default function AdminAnimals() {
  const { animals, loading, fetchAnimals } = useAnimalStore();
  const [search, setSearch] = useState('');

  // CRUD state
  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing]   = useState(null);
  const [deleting, setDeleting] = useState(null);
  const [saving, setSaving]     = useState(false);

  useEffect(() => { fetchAnimals(); }, [fetchAnimals]);

  // Live refresh on animal changes
  useBaasRealtime('animals', '*', () => fetchAnimals());

  const filtered = animals.filter((a) => {
    if (!search) return true;
    const q = search.toLowerCase();
    return a.name.toLowerCase().includes(q) || a.common_name?.toLowerCase().includes(q);
  });

  // ── Handlers ──────────────────────────────────────────────
  const openCreate = () => { setEditing(null); setShowForm(true); };
  const openEdit   = (a) => { setEditing(a); setShowForm(true); };

  const handleSave = async (data) => {
    setSaving(true);
    try {
      if (editing) {
        await baas.collection('animals').eq('id', editing.id).update(data);
      } else {
        await baas.collection('animals').insert({
          ...data,
          total_feedings: 0,
          created_at: new Date(),
          updated_at: new Date(),
        });
      }
      setShowForm(false);
      setEditing(null);
      fetchAnimals();
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
      await baas.collection('animals').eq('id', deleting.id).remove();
      setDeleting(null);
      fetchAnimals();
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
          <h2 className="font-display text-2xl font-bold text-forest">Animals</h2>
          <p className="text-sm text-charcoal/50">Manage all zoo residents · {animals.length} total</p>
        </div>
        <button onClick={openCreate} className="btn-primary text-sm">
          <Plus className="h-4 w-4" /> Add Animal
        </button>
      </div>

      {/* Search */}
      <div className="relative max-w-sm">
        <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-charcoal/40" />
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search animals…"
          className="w-full rounded-xl border border-sand bg-white py-2.5 pl-10 pr-4 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
        />
      </div>

      {/* Table */}
      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-sand bg-sand-light/50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Name</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Species</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Zone</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Status</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">IUCN</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Weight</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-sand">
              {loading && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">Loading…</td></tr>
              )}
              {!loading && filtered.map((a, i) => (
                <motion.tr
                  key={a.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: Math.min(i * 0.02, 0.3) }}
                  className="hover:bg-sand-light/30 transition-colors"
                >
                  <td className="px-4 py-3">
                    <div>
                      <p className="font-medium text-forest">{a.name}</p>
                      {a.is_featured && (
                        <span className="text-[10px] text-amber font-bold uppercase">★ Featured</span>
                      )}
                    </div>
                  </td>
                  <td className="px-4 py-3">
                    <p className="text-charcoal/70">{a.common_name}</p>
                    <p className="text-xs italic text-charcoal/40">{a.species}</p>
                  </td>
                  <td className="px-4 py-3"><ZoneBadge zone={a.zone} /></td>
                  <td className="px-4 py-3"><StatusBadge status={a.status} /></td>
                  <td className="px-4 py-3"><ConservationBadge status={a.conservation_status} /></td>
                  <td className="px-4 py-3 text-charcoal/60">{a.weight_kg} kg</td>
                  <td className="px-4 py-3 text-right">
                    <button
                      onClick={() => openEdit(a)}
                      className="mr-2 text-charcoal/40 hover:text-forest transition-colors"
                      title="Edit"
                    >
                      <Pencil className="h-4 w-4" />
                    </button>
                    <button
                      onClick={() => setDeleting(a)}
                      className="text-charcoal/40 hover:text-red-600 transition-colors"
                      title="Delete"
                    >
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </td>
                </motion.tr>
              ))}
              {!loading && filtered.length === 0 && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">No animals found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Create / Edit modal */}
      <FormModal
        open={showForm}
        onClose={() => { setShowForm(false); setEditing(null); }}
        title={editing ? `Edit — ${editing.name}` : 'Add Animal'}
        fields={ANIMAL_FIELDS}
        initialValues={editing || {}}
        onSubmit={handleSave}
        saving={saving}
        columns={2}
      />

      {/* Delete confirmation */}
      <ConfirmDialog
        open={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={handleDelete}
        title="Delete Animal"
        message={`Remove "${deleting?.name}" from the zoo? This cannot be undone.`}
        loading={saving}
      />
    </div>
  );
}
