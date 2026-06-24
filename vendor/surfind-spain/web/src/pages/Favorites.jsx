import { useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import baas from '@/baas/client';
import { BEACH_SELECT } from '@/baas/beaches';
import BeachCard from '@/components/BeachCard';
import LoadingScreen from '@/components/ui/LoadingScreen';
import useBaasAuth from '@/hooks/useBaasAuth';

export default function Favorites() {
  const { user, loading } = useBaasAuth();
  const [beaches, setBeaches] = useState(null);

  useEffect(() => {
    if (!user) return;
    // favorites is owner-scoped by RLS → a plain GET returns only mine.
    baas
      .collection('favorites')
      .select(`beach_id,beach:beaches(${BEACH_SELECT})`)
      .order('created_at', 'desc')
      .get()
      .then((rows) => setBeaches(rows.map((r) => r.beach).filter(Boolean)))
      .catch(() => setBeaches([]));
  }, [user]);

  if (loading) return <LoadingScreen />;
  if (!user) return <Navigate to="/acceder" replace />;

  return (
    <section className="mx-auto flex max-w-7xl flex-col gap-8 px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Tu cuenta</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Mis favoritos</h1>
      </div>

      {beaches === null ? (
        <LoadingScreen />
      ) : beaches.length ? (
        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
          {beaches.map((b) => (
            <BeachCard key={b.id} beach={b} />
          ))}
        </div>
      ) : (
        <div className="panel px-6 py-14 text-center">
          <h2 className="text-2xl font-black text-ocean">Aún no has guardado ninguna playa</h2>
          <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-ocean-mid">
            Pulsa “Guardar” en la ficha de una playa para verla aquí.
          </p>
        </div>
      )}
    </section>
  );
}
