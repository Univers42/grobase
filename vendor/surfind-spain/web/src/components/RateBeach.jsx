// RateBeach.jsx — interactive star widget. Upserts the caller's beach_ratings row
// (owner-scoped), then re-reads the beach's public rating_avg/rating_count (the
// SECURITY DEFINER trigger recomputes them). Guests see the aggregate read-only.
import { useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import Stars from '@/components/ui/Stars';

/** Star-rating widget for one beach. avg/count are the seeded aggregate. */
export default function RateBeach({ beachId, user, avg = 0, count = 0 }) {
  const [agg, setAgg] = useState({ avg, count });
  const [hover, setHover] = useState(0);
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);

  async function rate(stars) {
    if (busy || !user) return;
    setBusy(true);
    try {
      // PostgREST upsert: POST with Prefer resolution=merge-duplicates on the PK.
      await baas.collection('beach_ratings').upsert({ beach_id: beachId, stars });
      const fresh = await baas.collection('beaches').select('rating_avg,rating_count').eq('id', beachId).single();
      if (fresh) setAgg({ avg: fresh.rating_avg, count: fresh.rating_count });
      setDone(true);
    } catch {
      // a duplicate PK without merge support still counts as "rated"; refresh anyway
      const fresh = await baas.collection('beaches').select('rating_avg,rating_count').eq('id', beachId).single().catch(() => null);
      if (fresh) setAgg({ avg: fresh.rating_avg, count: fresh.rating_count });
      setDone(true);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="panel p-6">
      <h2 className="text-lg font-black text-ocean">Valoración</h2>
      <div className="mt-3 flex items-center gap-3">
        <Stars value={agg.avg} count={agg.count} className="text-lg" />
        <span className="text-sm font-semibold text-ocean-mid">{Number(agg.avg).toFixed(1)} / 5</span>
      </div>
      {user ? (
        <div className="mt-4">
          <p className="text-sm font-semibold text-ocean-deep">{done ? '¡Gracias por tu voto!' : 'Tu valoración:'}</p>
          <div className="mt-2 flex gap-1 text-2xl" onMouseLeave={() => setHover(0)}>
            {[1, 2, 3, 4, 5].map((n) => (
              <button
                key={n}
                disabled={busy}
                onMouseEnter={() => setHover(n)}
                onClick={() => rate(n)}
                aria-label={`${n} estrellas`}
                className={`transition disabled:opacity-50 ${n <= hover ? 'text-amber-400' : 'text-ocean-sky/50 hover:text-amber-300'}`}
              >
                ★
              </button>
            ))}
          </div>
        </div>
      ) : (
        <p className="mt-4 text-sm font-semibold text-ocean-mid">
          <Link to="/acceder" className="font-black text-ocean hover:text-ocean-mid">Inicia sesión</Link> para valorar esta playa.
        </p>
      )}
    </section>
  );
}
