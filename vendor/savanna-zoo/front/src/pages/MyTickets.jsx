import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Ticket, QrCode, Calendar, LogIn, BookOpen } from 'lucide-react';
import useBaasAuth from '@/hooks/useBaasAuth';
import baas from '@/baas/client';

const STATUS_STYLE = {
  valid:     'bg-forest/10 text-forest',
  used:      'bg-charcoal/10 text-charcoal/60',
  cancelled: 'bg-red-100 text-red-700',
  refunded:  'bg-amber/15 text-amber-700',
};

/**
 * My Tickets — a visitor's own bookings. RLS owner-scopes the read, so a plain
 * `tickets` GET returns only this user's rows (no client-side filtering needed).
 */
export default function MyTickets() {
  const { user, loading: authLoading } = useBaasAuth();
  const [tickets, setTickets] = useState([]);
  const [loading, setLoading] = useState(true);

  const load = useCallback(async () => {
    setLoading(true);
    try {
      const rows = await baas
        .collection('tickets')
        .select('*,ticket_type:ticket_types(name,color)')
        .order('created_at', 'desc')
        .get();
      setTickets(Array.isArray(rows) ? rows : []);
    } catch {
      setTickets([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!authLoading && user) load();
    else if (!authLoading) setLoading(false);
  }, [authLoading, user, load]);

  if (!authLoading && !user) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 pt-16 text-center">
        <Ticket className="h-12 w-12 text-forest/40" />
        <h2 className="font-display text-2xl font-bold text-forest">Your tickets live here</h2>
        <p className="max-w-sm text-charcoal/60">Sign in or create an account to view the tickets you've booked.</p>
        <Link to="/account" state={{ from: '/my-tickets' }} className="btn-primary mt-2">
          <LogIn className="h-4 w-4" /> Sign in
        </Link>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-sand-light pt-16">
      <section className="bg-forest px-4 py-14 text-center">
        <h1 className="font-display text-4xl font-bold text-ivory md:text-5xl">My Tickets</h1>
        <p className="mx-auto mt-2 max-w-lg text-ivory/60">Every booking under your account, with its entry QR code.</p>
      </section>

      <div className="mx-auto max-w-3xl px-4 py-10 sm:px-6">
        {loading && <p className="text-charcoal/50">Loading your tickets…</p>}

        {!loading && tickets.length === 0 && (
          <div className="card flex flex-col items-center gap-3 p-10 text-center">
            <Ticket className="h-10 w-10 text-forest/30" />
            <p className="text-charcoal/60">You haven't booked any tickets yet.</p>
            <Link to="/tickets" className="btn-amber mt-1">Buy tickets</Link>
          </div>
        )}

        <div className="space-y-4">
          {tickets.map((t, i) => (
            <motion.div
              key={t.id}
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: i * 0.04 }}
              className="card flex flex-col gap-4 p-5 sm:flex-row sm:items-center sm:justify-between"
            >
              <div className="flex items-center gap-4">
                <div
                  className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-xl"
                  style={{ backgroundColor: (t.ticket_type?.color || '#1a3a2a') + '18' }}
                >
                  <Ticket className="h-6 w-6" style={{ color: t.ticket_type?.color || '#1a3a2a' }} />
                </div>
                <div>
                  <h3 className="font-display text-lg font-bold text-forest">
                    {t.ticket_type?.name || 'Ticket'} × {t.quantity}
                  </h3>
                  <p className="flex items-center gap-1.5 text-sm text-charcoal/50">
                    <Calendar className="h-3.5 w-3.5" /> {t.visit_date} · €{parseFloat(t.total_eur).toFixed(2)}
                  </p>
                </div>
              </div>

              <div className="flex items-center gap-4">
                <span className={`rounded-full px-3 py-1 text-xs font-medium ${STATUS_STYLE[t.status] || ''}`}>
                  {t.status}
                </span>
                <div className="flex items-center gap-2 rounded-xl bg-sand px-3 py-2 font-mono text-xs text-charcoal/70">
                  <QrCode className="h-4 w-4 text-forest" /> {t.qr_code}
                </div>
              </div>
            </motion.div>
          ))}
        </div>

        {!loading && tickets.length > 0 && (
          <div className="mt-8 text-center">
            <Link to="/journal" className="inline-flex items-center gap-2 text-sm font-medium text-forest hover:underline">
              <BookOpen className="h-4 w-4" /> Open your visit journal
            </Link>
          </div>
        )}
      </div>
    </div>
  );
}
