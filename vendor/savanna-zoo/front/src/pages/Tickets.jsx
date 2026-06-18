import { useState } from 'react';
import { motion } from 'framer-motion';
import {
  Ticket, Users, Baby, GraduationCap, Crown, Heart,
  Plus, Minus, CreditCard, CheckCircle2,
} from 'lucide-react';
import useBaasCollection from '@/hooks/useBaasCollection';
import baas from '@/baas/client';

const TICKET_ICONS = {
  Adult:  Users,
  Child:  Baby,
  Senior: GraduationCap,
  VIP:    Crown,
  Family: Heart,
};

export default function Tickets() {
  const { data: types, loading } = useBaasCollection('ticket_types', {
    filters: { is_active: true },
    order: 'price_eur.asc',
  });

  const [cart, setCart] = useState({});       // { typeId: qty }
  const [visitor, setVisitor] = useState({ name: '', email: '' });
  const [visitDate, setVisitDate] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [success, setSuccess] = useState(false);

  const total = (types || []).reduce((sum, t) => {
    return sum + (cart[t.id] || 0) * parseFloat(t.price_eur);
  }, 0);

  const cartCount = Object.values(cart).reduce((a, b) => a + b, 0);

  const inc = (id) => setCart((c) => ({ ...c, [id]: (c[id] || 0) + 1 }));
  const dec = (id) => setCart((c) => ({ ...c, [id]: Math.max((c[id] || 0) - 1, 0) }));

  const handleSubmit = async (e) => {
    e.preventDefault();
    if (!cartCount || !visitor.name || !visitDate) return;

    setSubmitting(true);
    try {
      // Create one ticket per type with qty > 0
      const promises = (types || [])
        .filter((t) => (cart[t.id] || 0) > 0)
        .map((t) =>
          baas.collection('tickets').insert({
            ticket_type_id: t.id,
            visitor_name: visitor.name,
            visitor_email: visitor.email,
            visit_date: visitDate,
            quantity: cart[t.id],
            total_eur: cart[t.id] * parseFloat(t.price_eur),
          }),
        );
      await Promise.all(promises);
      setSuccess(true);
      setCart({});
    } catch (err) {
      alert('Booking failed: ' + err.message);
    } finally {
      setSubmitting(false);
    }
  };

  if (success) {
    return (
      <div className="flex min-h-screen items-center justify-center pt-16">
        <motion.div
          initial={{ scale: 0.8, opacity: 0 }}
          animate={{ scale: 1, opacity: 1 }}
          className="text-center"
        >
          <CheckCircle2 className="mx-auto h-16 w-16 text-forest" />
          <h2 className="mt-4 font-display text-3xl font-bold text-forest">Booking Confirmed!</h2>
          <p className="mt-2 text-charcoal/60">
            A confirmation email has been sent to <strong>{visitor.email}</strong>.
          </p>
          <p className="mt-1 text-charcoal/60">
            Visit date: <strong>{visitDate}</strong> — Total: <strong>€{total.toFixed(2)}</strong>
          </p>
          <button
            onClick={() => { setSuccess(false); setVisitor({ name: '', email: '' }); setVisitDate(''); }}
            className="btn-primary mt-8"
          >
            Book Again
          </button>
        </motion.div>
      </div>
    );
  }

  return (
    <div className="pt-16">
      {/* Header */}
      <section className="bg-forest px-4 py-16 text-center">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="font-display text-5xl font-bold text-ivory md:text-6xl"
        >
          Buy Tickets
        </motion.h1>
        <p className="mx-auto mt-3 max-w-xl text-ivory/60">
          Choose your ticket type, pick a date, and you're set. Children under 3 enter free.
        </p>
      </section>

      <div className="mx-auto max-w-5xl px-4 py-12 sm:px-6">
        <form onSubmit={handleSubmit}>
          <div className="grid gap-10 lg:grid-cols-3">
            {/* Ticket types */}
            <div className="lg:col-span-2 space-y-4">
              <h2 className="font-display text-2xl font-bold text-forest">Select Tickets</h2>

              {loading && <p className="text-charcoal/50">Loading ticket types…</p>}

              {types?.map((t, i) => {
                const Icon = TICKET_ICONS[t.name] || Ticket;
                const qty = cart[t.id] || 0;

                return (
                  <motion.div
                    key={t.id}
                    initial={{ opacity: 0, y: 15 }}
                    animate={{ opacity: 1, y: 0 }}
                    transition={{ delay: i * 0.05 }}
                    className="card flex items-center gap-4 p-5"
                  >
                    <div
                      className="flex h-12 w-12 flex-shrink-0 items-center justify-center rounded-xl"
                      style={{ backgroundColor: (t.color || '#1a3a2a') + '18' }}
                    >
                      <Icon className="h-6 w-6" style={{ color: t.color || '#1a3a2a' }} />
                    </div>

                    <div className="flex-1 min-w-0">
                      <h3 className="font-display text-lg font-bold text-forest">{t.name}</h3>
                      <p className="text-xs text-charcoal/50">{t.description}</p>
                    </div>

                    <span className="font-display text-xl font-bold text-amber whitespace-nowrap">
                      €{parseFloat(t.price_eur).toFixed(2)}
                    </span>

                    {/* Qty control */}
                    <div className="flex items-center gap-2">
                      <button
                        type="button"
                        onClick={() => dec(t.id)}
                        disabled={qty === 0}
                        className="flex h-8 w-8 items-center justify-center rounded-full border border-sand text-charcoal/50 hover:bg-sand disabled:opacity-30"
                      >
                        <Minus className="h-4 w-4" />
                      </button>
                      <span className="w-8 text-center font-medium">{qty}</span>
                      <button
                        type="button"
                        onClick={() => inc(t.id)}
                        className="flex h-8 w-8 items-center justify-center rounded-full bg-forest text-ivory hover:bg-forest-light"
                      >
                        <Plus className="h-4 w-4" />
                      </button>
                    </div>
                  </motion.div>
                );
              })}
            </div>

            {/* Summary sidebar */}
            <div>
              <div className="card sticky top-24 p-6 space-y-5">
                <h3 className="font-display text-lg font-bold text-forest">Your Order</h3>

                {cartCount === 0 ? (
                  <p className="text-sm text-charcoal/40">No tickets selected yet.</p>
                ) : (
                  <ul className="space-y-2 text-sm">
                    {types?.filter((t) => (cart[t.id] || 0) > 0).map((t) => (
                      <li key={t.id} className="flex justify-between">
                        <span>{t.name} × {cart[t.id]}</span>
                        <span className="font-medium">€{(cart[t.id] * parseFloat(t.price_eur)).toFixed(2)}</span>
                      </li>
                    ))}
                  </ul>
                )}

                <div className="border-t border-sand pt-3 flex justify-between font-display text-xl font-bold text-forest">
                  <span>Total</span>
                  <span>€{total.toFixed(2)}</span>
                </div>

                {/* Visitor info */}
                <div className="space-y-3">
                  <input
                    type="text"
                    placeholder="Your name *"
                    value={visitor.name}
                    onChange={(e) => setVisitor((v) => ({ ...v, name: e.target.value }))}
                    required
                    className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                  />
                  <input
                    type="email"
                    placeholder="Email"
                    value={visitor.email}
                    onChange={(e) => setVisitor((v) => ({ ...v, email: e.target.value }))}
                    className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                  />
                  <input
                    type="date"
                    value={visitDate}
                    onChange={(e) => setVisitDate(e.target.value)}
                    required
                    min={new Date().toISOString().split('T')[0]}
                    className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
                  />
                </div>

                <button
                  type="submit"
                  disabled={!cartCount || !visitor.name || !visitDate || submitting}
                  className="btn-amber w-full disabled:opacity-50 disabled:cursor-not-allowed"
                >
                  <CreditCard className="h-5 w-5" />
                  {submitting ? 'Processing…' : 'Confirm Booking'}
                </button>
              </div>
            </div>
          </div>
        </form>
      </div>
    </div>
  );
}
