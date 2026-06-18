import { useState } from 'react';
import { motion } from 'framer-motion';
import { Users, Plus, Mail, Phone, Shield, Pencil, Trash2 } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import baas from '@/baas/client';
import FormModal from '@/components/ui/FormModal';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

const ROLE_BADGE = {
  admin:      'bg-purple-100 text-purple-700',
  zookeeper:  'bg-green-100  text-green-700',
  vet:        'bg-blue-100   text-blue-700',
  reception:  'bg-amber/15   text-amber-dark',
};

const ZONE_OPTIONS = [
  { value: 'savannah', label: 'Savannah' },
  { value: 'arctic', label: 'Arctic' },
  { value: 'rainforest', label: 'Rainforest' },
  { value: 'aquarium', label: 'Aquarium' },
  { value: 'reptile', label: 'Reptile House' },
  { value: 'aviary', label: 'Aviary' },
  { value: 'petting', label: 'Petting Zoo' },
];

const STAFF_FIELDS = [
  { name: 'full_name', label: 'Full Name', type: 'text', required: true, placeholder: 'Sophie Laurent' },
  { name: 'email', label: 'Email', type: 'email', required: true, placeholder: 'sophie@savanna-zoo.com' },
  { name: 'phone', label: 'Phone', type: 'text', placeholder: '+33 6 12 34 56 78' },
  { name: 'role', label: 'Role', type: 'select', required: true, options: [
    { value: 'admin', label: 'Admin' },
    { value: 'zookeeper', label: 'Zookeeper' },
    { value: 'vet', label: 'Veterinarian' },
    { value: 'reception', label: 'Reception' },
  ]},
  { name: 'zone', label: 'Zone', type: 'select', options: ZONE_OPTIONS },
  { name: 'is_active', label: 'Active', type: 'checkbox', default: true },
];

export default function AdminStaff() {
  const { data: staff, loading, refetch } = useBaasCollection('staff', {
    order: 'full_name.asc',
  });

  const [showForm, setShowForm] = useState(false);
  const [editing, setEditing]   = useState(null);
  const [deleting, setDeleting] = useState(null);
  const [saving, setSaving]     = useState(false);

  const openCreate = () => { setEditing(null); setShowForm(true); };
  const openEdit   = (s) => { setEditing(s); setShowForm(true); };

  const handleSave = async (data) => {
    setSaving(true);
    try {
      if (editing) {
        await baas.collection('staff').eq('id', editing.id).update(data);
      } else {
        await baas.collection('staff').insert({
          ...data,
          hired_at: new Date().toISOString(),
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
      await baas.collection('staff').eq('id', deleting.id).remove();
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
          <h2 className="font-display text-2xl font-bold text-forest">Staff</h2>
          <p className="text-sm text-charcoal/50">Team management · {staff?.length ?? 0} members</p>
        </div>
        <button onClick={openCreate} className="btn-primary text-sm">
          <Plus className="h-4 w-4" /> Add Staff
        </button>
      </div>

      <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
        {loading && <p className="text-charcoal/40 col-span-full">Loading staff…</p>}

        {staff?.map((s, i) => (
          <motion.div
            key={s.id}
            initial={{ opacity: 0, y: 15 }}
            animate={{ opacity: 1, y: 0 }}
            transition={{ delay: Math.min(i * 0.05, 0.3) }}
            className="card p-5"
          >
            <div className="flex items-start gap-4">
              <div className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-full bg-forest/10 font-display text-lg font-bold text-forest">
                {s.full_name?.split(' ').map((w) => w[0]).join('').slice(0, 2)}
              </div>
              <div className="min-w-0 flex-1">
                <h3 className="truncate font-display text-lg font-bold text-forest">{s.full_name}</h3>
                <span className={`inline-block rounded-full px-2.5 py-0.5 text-xs font-semibold ${ROLE_BADGE[s.role] || 'bg-gray-100 text-gray-600'}`}>
                  {s.role}
                </span>
              </div>
              {/* Card actions */}
              <div className="flex gap-1">
                <button
                  onClick={() => openEdit(s)}
                  className="rounded-lg p-1.5 text-charcoal/30 hover:bg-sand/50 hover:text-forest transition-colors"
                  title="Edit"
                >
                  <Pencil className="h-3.5 w-3.5" />
                </button>
                <button
                  onClick={() => setDeleting(s)}
                  className="rounded-lg p-1.5 text-charcoal/30 hover:bg-red-50 hover:text-red-600 transition-colors"
                  title="Delete"
                >
                  <Trash2 className="h-3.5 w-3.5" />
                </button>
              </div>
            </div>

            <div className="mt-4 space-y-2 text-sm">
              <div className="flex items-center gap-2 text-charcoal/60">
                <Mail className="h-3.5 w-3.5" />
                <span className="truncate">{s.email}</span>
              </div>
              {s.phone && (
                <div className="flex items-center gap-2 text-charcoal/60">
                  <Phone className="h-3.5 w-3.5" />
                  <span>{s.phone}</span>
                </div>
              )}
              {s.zone && (
                <div className="flex items-center gap-2 text-charcoal/60">
                  <Shield className="h-3.5 w-3.5" />
                  <span className="capitalize">{s.zone} zone</span>
                </div>
              )}
            </div>

            <div className="mt-4 flex items-center justify-between text-xs text-charcoal/40">
              <span>Hired {new Date(s.hired_at).toLocaleDateString('en-GB', { month: 'short', year: 'numeric' })}</span>
              <span className={s.is_active ? 'text-green-600' : 'text-red-500'}>
                {s.is_active ? '● Active' : '● Inactive'}
              </span>
            </div>
          </motion.div>
        ))}

        {!loading && (!staff || staff.length === 0) && (
          <div className="col-span-full py-12 text-center">
            <Users className="mx-auto h-10 w-10 text-charcoal/20" />
            <p className="mt-3 text-charcoal/40">No staff members found.</p>
          </div>
        )}
      </div>

      <FormModal
        open={showForm}
        onClose={() => { setShowForm(false); setEditing(null); }}
        title={editing ? `Edit — ${editing.full_name}` : 'Add Staff Member'}
        fields={STAFF_FIELDS}
        initialValues={editing || { is_active: true }}
        onSubmit={handleSave}
        saving={saving}
        columns={2}
      />

      <ConfirmDialog
        open={!!deleting}
        onClose={() => setDeleting(null)}
        onConfirm={handleDelete}
        title="Remove Staff Member"
        message={`Remove "${deleting?.full_name}" from the team? This cannot be undone.`}
        loading={saving}
      />
    </div>
  );
}
