import { useEffect, useState } from 'react';
import { useNavigate, useSearchParams } from 'react-router-dom';
import baas from '@/baas/client';
import BeachMap from '@/components/BeachMap';
import LoadingScreen from '@/components/ui/LoadingScreen';

export default function MapPage() {
  const navigate = useNavigate();
  const [params] = useSearchParams();
  const focusSlug = params.get('playa');
  const [beaches, setBeaches] = useState(null);

  useEffect(() => {
    baas
      .collection('beaches')
      .select('id,name,slug,difficulty,latitude,longitude,location:locations(name)')
      .eq('status', 'published')
      .not('latitude', 'is', null)
      .get()
      .then(setBeaches)
      .catch(() => setBeaches([]));
  }, []);

  return (
    <section className="mx-auto flex max-w-7xl flex-col gap-5 px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Mapa interactivo</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Explora playas de surf</h1>
      </div>

      {beaches === null ? (
        <LoadingScreen label="Cargando mapa…" />
      ) : beaches.length ? (
        <div className="overflow-hidden rounded-[2.25rem] border border-ocean-sky/45 bg-white/70 p-2 shadow-2xl shadow-ocean-deep/10 backdrop-blur">
          <BeachMap
            beaches={beaches}
            focusSlug={focusSlug}
            onSelect={(s) => navigate(`/playas/${s}`)}
            className="h-[38rem] md:h-[46rem]"
          />
        </div>
      ) : (
        <div className="panel px-6 py-16 text-center">
          <h2 className="text-2xl font-black text-ocean">Aún no hay playas publicadas en el mapa</h2>
        </div>
      )}
    </section>
  );
}
