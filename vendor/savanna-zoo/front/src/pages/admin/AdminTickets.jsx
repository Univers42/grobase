import { useState, useCallback } from 'react';
import { motion } from 'framer-motion';
import { Ticket, Search, Filter, XCircle, RotateCcw, CheckCircle2 } from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import useBaasRealtime from '@/hooks/useBaasRealtime';
import baas from '@/baas/client';
import ConfirmDialog from '@/components/ui/ConfirmDialog';

const STATUS_COLORS = {
  valid:     'bg-green-100 text-green-700',
  used:      'bg-gray-100  text-gray-600',
  cancelled: 'bg-red-100   text-red-700',
  refunded:  'bg-orange-100 text-orange-700',
};

export default function AdminTickets() {
  const [statusFilter, setStatusFilter] = useState('all');
  const filters = statusFilter !== 'all' ? { status: statusFilter } : {};

  const { data: tickets, loading, refetch } = useBaasCollection('tickets', {
    filters,
    order: 'created_at.desc',
    limit: 100,
  });

  const [flash, setFlash] = useState(false);
  useBaasRealtime('tickets', 'insert', useCallback(() => {
    refetch();
    setFlash(true);
    setTimeout(() => setFlash(false), 2000);
  }, [refetch]));

  // ── Status change ───────────────────────────────────────
  const [changing, setChanging] = useState(null); // { ticket, newStatus }
  const [saving, setSaving] = useState(false);

  const requestChange = (ticket, newStatus) => {
    setChanging({ ticket, newStatus });
  };

  const handleStatusChange = async () => {
    if (!changing) return;
    setSaving(true);
    try {
      await baas.collection('tickets').eq('id', changing.ticket.id).update({
        status: changing.newStatus,
      });
      setChanging(null);
      refetch();
    } catch (err) {
      alert(`Error: ${err.message}`);
    } finally {
      setSaving(false);
    }
  };

  const totalRevenue = (tickets || []).reduce((s, t) => s + Number(t.total_eur), 0);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <div>
          <h2 className="font-display text-2xl font-bold text-forest">Tickets</h2>
          <p className="text-sm text-charcoal/50">
            {tickets?.length ?? 0} tickets · €{totalRevenue.toFixed(2)} revenue
            {flash && (
              <span className="ml-2 animate-pulse rounded-full bg-green-100 px-2 py-0.5 text-xs font-bold text-green-700">
                New sale!
              </span>
            )}
          </p>
        </div>
      </div>

      {/* Filters */}
      <div className="flex gap-2">
        {['all', 'valid', 'used', 'cancelled', 'refunded'].map((s) => (
          <button
            key={s}
            onClick={() => setStatusFilter(s)}
            className={`rounded-full px-4 py-2 text-xs font-medium transition ${
              statusFilter === s
                ? 'bg-forest text-ivory'
                : 'bg-white text-charcoal/60 hover:bg-sand/60'
            }`}
          >
            {s === 'all' ? 'All' : s.charAt(0).toUpperCase() + s.slice(1)}
          </button>
        ))}
      </div>

      {/* Table */}
      <div className="card overflow-hidden">
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="border-b border-sand bg-sand-light/50">
              <tr>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Visitor</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Visit Date</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">QR</th>
                <th className="px-4 py-3 text-center font-medium text-charcoal/60">Qty</th>
                <th className="px-4 py-3 text-left font-medium text-charcoal/60">Status</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Total</th>
                <th className="px-4 py-3 text-right font-medium text-charcoal/60">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-sand">
              {loading && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">Loading…</td></tr>
              )}
              {tickets?.map((t, i) => (
                <motion.tr
                  key={t.id}
                  initial={{ opacity: 0 }}
                  animate={{ opacity: 1 }}
                  transition={{ delay: Math.min(i * 0.01, 0.2) }}
                  className="hover:bg-sand-light/30 transition-colors"
                >
                  <td className="px-4 py-3">
                    <p className="font-medium text-forest">{t.visitor_name}</p>
                    {t.visitor_email && <p className="text-xs text-charcoal/40">{t.visitor_email}</p>}
                  </td>
                  <td className="px-4 py-3 text-charcoal/60">{t.visit_date}</td>
                  <td className="px-4 py-3 font-mono text-xs text-charcoal/40">{t.qr_code || '—'}</td>
                  <td className="px-4 py-3 text-center">{t.quantity}</td>
                  <td className="px-4 py-3">
                    <span className={`rounded-full px-2.5 py-0.5 text-xs font-semibold ${STATUS_COLORS[t.status] || ''}`}>
                      {t.status}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right font-medium">€{Number(t.total_eur).toFixed(2)}</td>
                  <td className="px-4 py-3 text-right">
                    <div className="flex justify-end gap-1">
                      {t.status === 'valid' && (
                        <>
                          <button
                            onClick={() => requestChange(t, 'used')}
                            className="rounded-lg p-1.5 text-charcoal/40 hover:bg-green-50 hover:text-green-700 transition-colors"
                            title="Mark as used"
                          >
                            <CheckCircle2 className="h-3.5 w-3.5" />
                          </button>
                          <button
                            onClick={() => requestChange(t, 'cancelled')}
                            className="rounded-lg p-1.5 text-charcoal/40 hover:bg-red-50 hover:text-red-600 transition-colors"
                            title="Cancel"
                          >
                            <XCircle className="h-3.5 w-3.5" />
                          </button>
                        </>
                      )}
                      {t.status === 'cancelled' && (
                        <button
                          onClick={() => requestChange(t, 'refunded')}
                          className="rounded-lg p-1.5 text-charcoal/40 hover:bg-orange-50 hover:text-orange-600 transition-colors"
                          title="Refund"
                        >
                          <RotateCcw className="h-3.5 w-3.5" />
                        </button>
                      )}
                    </div>
                  </td>
                </motion.tr>
              ))}
              {!loading && (!tickets || tickets.length === 0) && (
                <tr><td colSpan={7} className="px-4 py-8 text-center text-charcoal/40">No tickets found.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>

      {/* Status change confirmation */}
      <ConfirmDialog
        open={!!changing}
        onClose={() => setChanging(null)}
        onConfirm={handleStatusChange}
        title="Change Ticket Status"
        message={`Update ticket for "${changing?.ticket?.visitor_name}" to "${changing?.newStatus}"?`}
        loading={saving}
      />
    </div>
  );
}
