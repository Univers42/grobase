import { useEffect, useMemo, useState } from 'react';
import { Navigate } from 'react-router-dom';
import baas from '@/baas/client';
import mongo, { journalReady } from '@/baas/mongo';
import useBaasAuth from '@/hooks/useBaasAuth';
import SessionForm from '@/components/SessionForm';
import Stars from '@/components/ui/Stars';
import sessionStats from '@/utils/sessionStats';
import LoadingScreen from '@/components/ui/LoadingScreen';

const STATS = [
  ['sessions', 'Sesiones'], ['waves', 'Olas'], ['hours', 'Horas'],
  ['spots', 'Spots'], ['best', 'Mejor valoración'], ['streak', 'Racha (días)'],
];

/** Mi Bitácora — log + list the surfer's MongoDB sessions, with a stats summary. */
export default function Bitacora() {
  const { user, loading } = useBaasAuth();
  const [sessions, setSessions] = useState(journalReady ? null : []);
  const [beaches, setBeaches] = useState([]);

  useEffect(() => {
    if (!user || !journalReady) return;
    mongo.list(200).then(setSessions).catch(() => setSessions([]));
    baas.collection('beaches').select('id,name').eq('status', 'published').order('name').get()
      .then(setBeaches).catch(() => {});
  }, [user]);

  const stats = useMemo(() => sessionStats(sessions || []), [sessions]);

  if (loading) return <LoadingScreen />;
  if (!user) return <Navigate to="/acceder" replace />;

  return (
    <section className="mx-auto flex max-w-5xl flex-col gap-6 px-5 pb-16 pt-2 sm:px-8">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Tu cuenta</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Mi Bitácora</h1>
        <p className="mt-3 text-ocean-mid">Tu registro privado de sesiones, guardado en MongoDB y visible sólo para ti.</p>
      </div>

      {!journalReady ? (
        <div className="panel p-6 text-sm font-semibold leading-7 text-ocean-mid">
          La bitácora necesita el plano de documentos (MongoDB). Pide al administrador que ejecute
          <code className="mx-1 rounded bg-ocean-pale/60 px-2 py-0.5">scripts/seed/surfind-tenant.sh</code>
          para activar <code className="rounded bg-ocean-pale/60 px-2 py-0.5">VITE_BAAS_MONGO_DBID</code>.
        </div>
      ) : (
        <>
          <div className="grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-6">
            {STATS.map(([k, label]) => (
              <div key={k} className="panel p-4 text-center">
                <p className="text-3xl font-black text-ocean">
                  {k === 'best' ? (stats.best ? <Stars value={stats.best} /> : '—') : stats[k]}
                </p>
                <p className="mt-1 text-xs font-bold uppercase tracking-wider text-ocean-teal">{label}</p>
              </div>
            ))}
          </div>

          <div className="grid gap-6 lg:grid-cols-[1fr_360px]">
            <div className="space-y-3">
              {sessions === null ? (
                <LoadingScreen />
              ) : sessions.length ? (
                sessions.map((s, i) => (
                  <article key={s._id || i} className="panel p-4">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-black text-ocean">{s.beach_name || 'Sesión'}</span>
                      <span className="text-xs font-semibold text-ocean-teal">{(s.date || s.created_at || '').slice(0, 10)}</span>
                    </div>
                    <div className="mt-2 flex flex-wrap items-center gap-2 text-xs font-bold text-ocean-deep">
                      {s.duration_min != null && <span className="chip">⏱ {s.duration_min} min</span>}
                      {s.waves != null && <span className="chip">🏄 {s.waves} olas</span>}
                      {s.board && <span className="chip">{s.board}</span>}
                      {s.swell_m != null && <span className="chip">🌊 {s.swell_m} m</span>}
                      {s.rating != null && <Stars value={s.rating} />}
                    </div>
                    {(s.tags || []).length > 0 && (
                      <div className="mt-2 flex flex-wrap gap-1">{s.tags.map((t) => <span key={t} className="chip">#{t}</span>)}</div>
                    )}
                    {s.notes && <p className="mt-2 text-sm leading-6 text-ocean-mid">{s.notes}</p>}
                  </article>
                ))
              ) : (
                <p className="panel px-6 py-12 text-center font-semibold text-ocean-mid">Aún no has registrado ninguna sesión.</p>
              )}
            </div>
            <div className="lg:sticky lg:top-6 lg:self-start">
              <SessionForm beaches={beaches} onSaved={(doc) => setSessions((prev) => [doc, ...(prev || [])])} />
            </div>
          </div>
        </>
      )}
    </section>
  );
}
