import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import BeachCard from '@/components/BeachCard';
import LoadingScreen from '@/components/ui/LoadingScreen';
import { publishedBeaches } from '@/baas/beaches';

const HEADLINE = ['¿Buscas', 'una', 'playa', 'para', 'hacer', 'surf?'];

export default function Home() {
  const [beaches, setBeaches] = useState(null);

  useEffect(() => {
    publishedBeaches()
      .limit(3)
      .get()
      .then(setBeaches)
      .catch(() => setBeaches([]));
  }, []);

  return (
    <div className="animate-fade-in">
      <section className="relative isolate mx-auto grid min-h-[70vh] max-w-7xl place-items-center px-5 py-24 text-center sm:px-8 lg:px-10">
        <div className="absolute -top-10 right-10 -z-10 size-72 rounded-full bg-ocean-sky/25 blur-3xl" />
        <div className="absolute bottom-0 left-10 -z-10 size-64 rounded-full bg-ocean-teal/20 blur-3xl" />
        <div className="mx-auto max-w-4xl">
          <h1 className="text-balance text-5xl font-black leading-[0.98] tracking-tight text-ocean sm:text-7xl">
            {HEADLINE.map((w, i) => (
              <span key={i} className="mr-3 inline-block animate-slide-up" style={{ animationDelay: `${i * 90}ms` }}>
                {w}
              </span>
            ))}
          </h1>
          <p className="mx-auto mt-6 max-w-2xl text-lg leading-7 text-ocean-mid">
            Surfind Spain reúne las mejores playas de surf de la costa española: dificultad, servicios,
            ubicación y la opinión de la comunidad, todo en un solo sitio.
          </p>
          <Link to="/playas" className="btn-primary mt-10 px-9 py-4 text-lg">
            Encuéntrala aquí
          </Link>
        </div>
      </section>

      <section className="mx-auto max-w-7xl px-5 pb-8 sm:px-8 lg:px-10">
        <div className="flex items-end justify-between gap-4">
          <div>
            <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Destacadas</p>
            <h2 className="mt-2 text-3xl font-black tracking-tight text-ocean md:text-4xl">Playas publicadas</h2>
          </div>
          <Link to="/playas" className="btn-ghost">
            Ver todas
          </Link>
        </div>

        {beaches === null ? (
          <LoadingScreen />
        ) : beaches.length ? (
          <div className="mt-8 grid gap-6 md:grid-cols-2 xl:grid-cols-3">
            {beaches.map((b) => (
              <BeachCard key={b.id} beach={b} />
            ))}
          </div>
        ) : (
          <p className="panel mt-8 px-6 py-12 text-center font-semibold text-ocean-mid">
            Aún no hay playas publicadas.
          </p>
        )}
      </section>
    </div>
  );
}
