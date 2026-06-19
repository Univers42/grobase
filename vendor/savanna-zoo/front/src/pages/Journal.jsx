import { useEffect, useState, useCallback } from 'react';
import { Link } from 'react-router-dom';
import { motion, AnimatePresence } from 'framer-motion';
import { BookOpen, Star, Plus, Trash2, LogIn, Database } from 'lucide-react';
import useBaasAuth from '@/hooks/useBaasAuth';
import journal, { journalReady } from '@/baas/mongo';

const ZONES = ['savannah', 'arctic', 'rainforest', 'aquarium', 'reptile', 'aviary', 'petting'];

/**
 * Visit Journal — the MongoDB showcase. A visitor's animal observations are
 * stored as documents via Grobase's query-router and owner-scoped per user, so
 * this list shows only the signed-in visitor's own entries.
 */
export default function Journal() {
  const { user, loading: authLoading } = useBaasAuth();
  const [entries, setEntries] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [form, setForm] = useState({ animal: '', zone: 'savannah', note: '', rating: 5, tags: '' });
  const [saving, setSaving] = useState(false);

  const load = useCallback(async () => {
    setLoading(true);
    setError('');
    try {
      setEntries(await journal.list());
    } catch (err) {
      setError(err.message);
      setEntries([]);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    if (!authLoading && user && journalReady) load();
    else if (!authLoading) setLoading(false);
  }, [authLoading, user, load]);

  const add = async (e) => {
    e.preventDefault();
    if (!form.animal.trim()) return;
    setSaving(true);
    setError('');
    try {
      await journal.add({
        ...form,
        tags: form.tags.split(',').map((s) => s.trim()).filter(Boolean),
      });
      setForm({ animal: '', zone: 'savannah', note: '', rating: 5, tags: '' });
      await load();
    } catch (err) {
      setError(err.message);
    } finally {
      setSaving(false);
    }
  };

  const remove = async (id) => {
    try {
      await journal.remove(id);
      setEntries((list) => list.filter((e) => e._id !== id));
    } catch (err) {
      setError(err.message);
    }
  };

  if (!authLoading && !user) {
    return (
      <div className="flex min-h-screen flex-col items-center justify-center gap-4 pt-16 text-center">
        <BookOpen className="h-12 w-12 text-forest/40" />
        <h2 className="font-display text-2xl font-bold text-forest">Your visit journal</h2>
        <p className="max-w-sm text-charcoal/60">Sign in to record and revisit your animal observations.</p>
        <Link to="/account" state={{ from: '/journal' }} className="btn-primary mt-2">
          <LogIn className="h-4 w-4" /> Sign in
        </Link>
      </div>
    );
  }

  return (
    <div className="min-h-screen bg-sand-light pt-16">
      <section className="bg-forest px-4 py-14 text-center">
        <h1 className="font-display text-4xl font-bold text-ivory md:text-5xl">Visit Journal</h1>
        <p className="mx-auto mt-2 flex max-w-lg items-center justify-center gap-2 text-ivory/60">
          <Database className="h-4 w-4" /> Your private observations, stored in MongoDB.
        </p>
      </section>

      <div className="mx-auto grid max-w-5xl gap-8 px-4 py-10 sm:px-6 lg:grid-cols-5">
        {/* Add form */}
        <form onSubmit={add} className="card h-fit space-y-3 p-5 lg:col-span-2">
          <h2 className="font-display text-lg font-bold text-forest">Log an observation</h2>
          <input
            type="text" required placeholder="Animal (e.g. Kesi the Lioness)"
            value={form.animal} onChange={(e) => setForm((f) => ({ ...f, animal: e.target.value }))}
            className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
          />
          <select
            value={form.zone} onChange={(e) => setForm((f) => ({ ...f, zone: e.target.value }))}
            className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm capitalize outline-none focus:border-forest"
          >
            {ZONES.map((z) => <option key={z} value={z}>{z}</option>)}
          </select>
          <textarea
            rows={3} placeholder="What did you see?"
            value={form.note} onChange={(e) => setForm((f) => ({ ...f, note: e.target.value }))}
            className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
          />
          <div className="flex items-center gap-2">
            <span className="text-sm text-charcoal/60">Rating</span>
            {[1, 2, 3, 4, 5].map((n) => (
              <button
                key={n} type="button" onClick={() => setForm((f) => ({ ...f, rating: n }))}
                aria-label={`${n} star`}
              >
                <Star className={`h-5 w-5 ${n <= form.rating ? 'fill-amber text-amber' : 'text-sand'}`} />
              </button>
            ))}
          </div>
          <input
            type="text" placeholder="Tags (comma separated)"
            value={form.tags} onChange={(e) => setForm((f) => ({ ...f, tags: e.target.value }))}
            className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
          />
          <button type="submit" disabled={saving} className="btn-primary w-full disabled:opacity-50">
            <Plus className="h-4 w-4" /> {saving ? 'Saving…' : 'Add to journal'}
          </button>
          {error && <p className="text-sm text-red-600">{error}</p>}
        </form>

        {/* Entries */}
        <div className="space-y-4 lg:col-span-3">
          {loading && <p className="text-charcoal/50">Loading your journal…</p>}
          {!loading && entries.length === 0 && (
            <div className="card p-8 text-center text-charcoal/60">No entries yet — log your first sighting!</div>
          )}
          <AnimatePresence>
            {entries.map((e) => (
              <motion.div
                key={e._id}
                initial={{ opacity: 0, y: 12 }} animate={{ opacity: 1, y: 0 }} exit={{ opacity: 0, x: -20 }}
                className="card p-5"
              >
                <div className="flex items-start justify-between gap-3">
                  <div>
                    <h3 className="font-display text-lg font-bold text-forest">{e.animal}</h3>
                    {e.zone && <span className="text-xs uppercase tracking-wide text-charcoal/40">{e.zone}</span>}
                  </div>
                  <div className="flex items-center gap-3">
                    <div className="flex">
                      {[1, 2, 3, 4, 5].map((n) => (
                        <Star key={n} className={`h-4 w-4 ${n <= (e.rating || 0) ? 'fill-amber text-amber' : 'text-sand'}`} />
                      ))}
                    </div>
                    <button onClick={() => remove(e._id)} aria-label="Delete" className="text-charcoal/30 hover:text-red-600">
                      <Trash2 className="h-4 w-4" />
                    </button>
                  </div>
                </div>
                {e.note && <p className="mt-2 text-sm text-charcoal/70">{e.note}</p>}
                {Array.isArray(e.tags) && e.tags.length > 0 && (
                  <div className="mt-3 flex flex-wrap gap-1.5">
                    {e.tags.map((tag) => (
                      <span key={tag} className="rounded-full bg-forest/10 px-2.5 py-0.5 text-xs text-forest">#{tag}</span>
                    ))}
                  </div>
                )}
              </motion.div>
            ))}
          </AnimatePresence>
        </div>
      </div>
    </div>
  );
}
