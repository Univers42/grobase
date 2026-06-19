import { useEffect, useMemo, useState } from 'react';
import baas from '@/baas/client';
import { publishedBeaches } from '@/baas/beaches';
import BeachCard from '@/components/BeachCard';
import { DIFFICULTY_LABELS } from '@/components/ui/DifficultyBadge';
import LoadingScreen from '@/components/ui/LoadingScreen';

export default function Beaches() {
  const [beaches, setBeaches] = useState(null);
  const [locations, setLocations] = useState([]);
  const [search, setSearch] = useState('');
  const [locationId, setLocationId] = useState('');
  const [difficulty, setDifficulty] = useState('all');

  useEffect(() => {
    publishedBeaches().get().then(setBeaches).catch(() => setBeaches([]));
    baas.collection('locations').select('id,name,slug').order('name').get().then(setLocations).catch(() => {});
  }, []);

  const filtered = useMemo(() => {
    if (!beaches) return [];
    const q = search.trim().toLowerCase();
    return beaches.filter((b) => {
      if (locationId && String(b.location_id) !== String(locationId)) return false;
      if (difficulty !== 'all' && b.difficulty !== difficulty) return false;
      if (q) {
        const hay = `${b.name} ${b.short_description || ''} ${b.description || ''}`.toLowerCase();
        if (!hay.includes(q)) return false;
      }
      return true;
    });
  }, [beaches, search, locationId, difficulty]);

  const dirty = search || locationId || difficulty !== 'all';

  return (
    <section className="mx-auto flex max-w-7xl flex-col gap-8 px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Directorio</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Playas de surf</h1>
      </div>

      <div className="panel p-5">
        <div className="grid gap-4 xl:grid-cols-[1fr_220px_200px_auto] xl:items-end">
          <div>
            <label htmlFor="search" className="mb-2 block text-sm font-semibold text-ocean-deep">Buscar</label>
            <input
              id="search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Nombre o descripción"
              className="field"
            />
          </div>
          <div>
            <label htmlFor="location" className="mb-2 block text-sm font-semibold text-ocean-deep">Provincia</label>
            <select id="location" value={locationId} onChange={(e) => setLocationId(e.target.value)} className="field">
              <option value="">Todas</option>
              {locations.map((l) => (
                <option key={l.id} value={l.id}>{l.name}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="difficulty" className="mb-2 block text-sm font-semibold text-ocean-deep">Dificultad</label>
            <select id="difficulty" value={difficulty} onChange={(e) => setDifficulty(e.target.value)} className="field">
              <option value="all">Todas</option>
              {Object.entries(DIFFICULTY_LABELS).map(([v, label]) => (
                <option key={v} value={v}>{label}</option>
              ))}
            </select>
          </div>
          {dirty && (
            <button
              onClick={() => { setSearch(''); setLocationId(''); setDifficulty('all'); }}
              className="btn-ghost h-12"
            >
              Limpiar
            </button>
          )}
        </div>
      </div>

      {beaches === null ? (
        <LoadingScreen />
      ) : filtered.length ? (
        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
          {filtered.map((b) => (
            <BeachCard key={b.id} beach={b} />
          ))}
        </div>
      ) : (
        <div className="panel px-6 py-14 text-center">
          <h2 className="text-2xl font-black text-ocean">No hay playas con estos filtros</h2>
          <p className="mx-auto mt-3 max-w-xl text-sm leading-6 text-ocean-mid">
            Prueba a cambiar la provincia o la dificultad para ampliar los resultados.
          </p>
        </div>
      )}
    </section>
  );
}
