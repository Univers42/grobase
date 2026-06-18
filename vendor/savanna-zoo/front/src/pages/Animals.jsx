import { useEffect, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import { motion } from 'framer-motion';
import { Search, SlidersHorizontal } from 'lucide-react';
import { useAnimalStore } from '@/stores/animalStore';
import ZoneBadge, { ZONE_CONFIG } from '@/components/ui/ZoneBadge';
import ConservationBadge from '@/components/ui/ConservationBadge';
import StatusBadge from '@/components/ui/StatusBadge';

const zones = ['all', ...Object.keys(ZONE_CONFIG)];

export default function Animals() {
  const [params, setParams] = useSearchParams();
  const activeZone = params.get('zone') || 'all';
  const [search, setSearch] = useState('');

  const { animals, loading, fetchAnimals } = useAnimalStore();

  useEffect(() => {
    const filters = {};
    if (activeZone !== 'all') filters.zone = activeZone;
    fetchAnimals(filters);
  }, [activeZone, fetchAnimals]);

  // Client-side text filter
  const filtered = animals.filter((a) => {
    if (!search) return true;
    const q = search.toLowerCase();
    return (
      a.name.toLowerCase().includes(q) ||
      a.common_name?.toLowerCase().includes(q) ||
      a.species.toLowerCase().includes(q)
    );
  });

  const setZone = (z) => {
    if (z === 'all') {
      params.delete('zone');
    } else {
      params.set('zone', z);
    }
    setParams(params);
  };

  return (
    <div className="pt-16">
      {/* Header */}
      <section className="bg-forest px-4 py-16 text-center">
        <motion.h1
          initial={{ opacity: 0, y: 20 }}
          animate={{ opacity: 1, y: 0 }}
          className="font-display text-5xl font-bold text-ivory md:text-6xl"
        >
          Our Animals
        </motion.h1>
        <p className="mx-auto mt-3 max-w-xl text-ivory/60">
          Discover over 200 species across 7 immersive zones — from the mighty
          African elephant to the tiny clownfish.
        </p>
      </section>

      <div className="mx-auto max-w-7xl px-4 py-10 sm:px-6 lg:px-8">
        {/* Filters bar */}
        <div className="flex flex-col gap-4 md:flex-row md:items-center md:justify-between">
          {/* Zone pills */}
          <div className="flex flex-wrap gap-2">
            {zones.map((z) => (
              <button
                key={z}
                onClick={() => setZone(z)}
                className={`rounded-full px-4 py-2 text-sm font-medium transition-all duration-200 ${
                  activeZone === z
                    ? 'bg-forest text-ivory shadow-md'
                    : 'bg-white text-charcoal/70 hover:bg-sand/60'
                }`}
              >
                {z === 'all'
                  ? 'All Zones'
                  : `${ZONE_CONFIG[z]?.emoji || ''} ${ZONE_CONFIG[z]?.label || z}`}
              </button>
            ))}
          </div>

          {/* Search */}
          <div className="relative">
            <Search className="absolute left-3 top-1/2 h-4 w-4 -translate-y-1/2 text-charcoal/40" />
            <input
              type="text"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search by name or species…"
              className="w-full rounded-full border border-sand bg-white py-2.5 pl-10 pr-4 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20 md:w-72"
            />
          </div>
        </div>

        {/* Results count */}
        <p className="mt-6 text-sm text-charcoal/50">
          {loading ? 'Loading…' : `${filtered.length} animal${filtered.length !== 1 ? 's' : ''} found`}
        </p>

        {/* Grid */}
        <div className="mt-6 grid gap-6 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-4">
          {filtered.map((animal, i) => (
            <motion.div
              key={animal.id}
              initial={{ opacity: 0, y: 20 }}
              animate={{ opacity: 1, y: 0 }}
              transition={{ delay: Math.min(i * 0.05, 0.5) }}
            >
              <Link to={`/animals/${animal.id}`} className="card group block">
                {/* Image placeholder */}
                <div className="relative aspect-[4/3] overflow-hidden bg-sand">
                  <div className="flex h-full items-center justify-center bg-forest/5">
                    <span className="text-5xl opacity-60">
                      {ZONE_CONFIG[animal.zone]?.emoji || '🌍'}
                    </span>
                  </div>
                  <div className="absolute inset-0 bg-card-gradient opacity-0 transition-opacity duration-300 group-hover:opacity-100" />
                  <div className="absolute bottom-3 left-3 right-3 translate-y-4 opacity-0 transition-all duration-300 group-hover:translate-y-0 group-hover:opacity-100">
                    <span className="text-sm font-medium text-ivory">View Profile →</span>
                  </div>
                </div>

                <div className="p-4">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <h3 className="truncate font-display text-lg font-bold text-forest">
                        {animal.name}
                      </h3>
                      <p className="truncate text-xs italic text-charcoal/50">
                        {animal.common_name} · <span className="text-charcoal/40">{animal.species}</span>
                      </p>
                    </div>
                    <StatusBadge status={animal.status} />
                  </div>

                  <div className="mt-3 flex flex-wrap items-center gap-2">
                    <ZoneBadge zone={animal.zone} />
                    <ConservationBadge status={animal.conservation_status} />
                  </div>

                  <div className="mt-3 flex items-center justify-between text-xs text-charcoal/40">
                    <span>{animal.weight_kg} kg</span>
                    <span>{animal.diet_type}</span>
                  </div>
                </div>
              </Link>
            </motion.div>
          ))}
        </div>

        {!loading && filtered.length === 0 && (
          <div className="py-20 text-center">
            <SlidersHorizontal className="mx-auto h-12 w-12 text-charcoal/20" />
            <p className="mt-4 text-charcoal/50">No animals match your search.</p>
          </div>
        )}
      </div>
    </div>
  );
}
