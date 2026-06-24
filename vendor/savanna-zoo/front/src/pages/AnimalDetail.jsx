import { useEffect } from 'react';
import { useParams, Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { ArrowLeft, Weight, Ruler, Utensils, Heart, Calendar, User } from 'lucide-react';
import { useAnimalStore } from '@/stores/animalStore';
import ZoneBadge from '@/components/ui/ZoneBadge';
import ConservationBadge from '@/components/ui/ConservationBadge';
import StatusBadge from '@/components/ui/StatusBadge';
import LoadingScreen from '@/components/ui/LoadingScreen';

export default function AnimalDetail() {
  const { id } = useParams();
  const { current: animal, loading, fetchAnimal } = useAnimalStore();

  useEffect(() => {
    fetchAnimal(id);
  }, [id, fetchAnimal]);

  if (loading) return <LoadingScreen />;
  if (!animal) {
    return (
      <div className="flex min-h-screen items-center justify-center pt-16">
        <div className="text-center">
          <p className="text-lg text-charcoal/50">Animal not found.</p>
          <Link to="/animals" className="btn-secondary mt-4">← Back to Animals</Link>
        </div>
      </div>
    );
  }

  const keeper = animal.keeper;

  return (
    <div className="pt-16">
      {/* Hero banner */}
      <section className="relative bg-forest px-4 py-20">
        <div className="mx-auto max-w-5xl">
          <Link to="/animals" className="mb-6 inline-flex items-center gap-1 text-sm text-ivory/60 hover:text-ivory transition-colors">
            <ArrowLeft className="h-4 w-4" /> Back to Animals
          </Link>

          <div className="flex flex-col gap-8 md:flex-row md:items-end md:justify-between">
            <motion.div initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }}>
              <div className="flex items-center gap-3">
                <ZoneBadge zone={animal.zone} />
                <StatusBadge status={animal.status} className="!text-ivory/70" />
              </div>
              <h1 className="mt-3 font-display text-5xl font-bold text-ivory md:text-7xl">
                {animal.name}
              </h1>
              <p className="mt-2 text-lg italic text-ivory/50">
                {animal.common_name} · <span className="text-ivory/30">{animal.species}</span>
              </p>
            </motion.div>

            <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} transition={{ delay: 0.2 }}>
              <ConservationBadge status={animal.conservation_status} className="text-sm" />
            </motion.div>
          </div>
        </div>
      </section>

      <div className="mx-auto max-w-5xl px-4 py-12 sm:px-6">
        <div className="grid gap-12 lg:grid-cols-3">
          {/* Main column */}
          <div className="lg:col-span-2 space-y-10">
            {/* Description */}
            <motion.section initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.1 }}>
              <h2 className="font-display text-2xl font-bold text-forest">About {animal.name}</h2>
              <p className="mt-3 leading-relaxed text-charcoal/70">{animal.description}</p>
            </motion.section>

            {/* Fun Facts */}
            {animal.fun_facts?.length > 0 && (
              <motion.section initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.2 }}>
                <h2 className="font-display text-2xl font-bold text-forest">Fun Facts</h2>
                <ul className="mt-4 space-y-3">
                  {animal.fun_facts.map((fact, i) => (
                    <li key={i} className="flex items-start gap-3">
                      <span className="mt-1 flex h-6 w-6 flex-shrink-0 items-center justify-center rounded-full bg-amber/15 text-xs font-bold text-amber">
                        {i + 1}
                      </span>
                      <span className="text-charcoal/70">{fact}</span>
                    </li>
                  ))}
                </ul>
              </motion.section>
            )}

            {/* Feeding Schedule */}
            {animal.feeding_schedule?.length > 0 && (
              <motion.section initial={{ opacity: 0, y: 20 }} animate={{ opacity: 1, y: 0 }} transition={{ delay: 0.3 }}>
                <h2 className="font-display text-2xl font-bold text-forest">Feeding Schedule</h2>
                <div className="mt-4 overflow-hidden rounded-xl border border-sand">
                  <table className="w-full text-sm">
                    <thead className="bg-sand-light">
                      <tr>
                        <th className="px-4 py-3 text-left font-medium text-charcoal/60">Time</th>
                        <th className="px-4 py-3 text-left font-medium text-charcoal/60">Food</th>
                        <th className="px-4 py-3 text-right font-medium text-charcoal/60">Qty (kg)</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-sand">
                      {animal.feeding_schedule.map((s, i) => (
                        <tr key={i} className="hover:bg-sand-light/50">
                          <td className="px-4 py-3 font-medium text-forest">{s.time}</td>
                          <td className="px-4 py-3 text-charcoal/70">{s.food_type}</td>
                          <td className="px-4 py-3 text-right text-charcoal/50">{s.quantity_kg}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              </motion.section>
            )}
          </div>

          {/* Sidebar */}
          <motion.aside
            initial={{ opacity: 0, x: 20 }}
            animate={{ opacity: 1, x: 0 }}
            transition={{ delay: 0.3 }}
            className="space-y-6"
          >
            {/* Stats card */}
            <div className="card p-6">
              <h3 className="font-display text-lg font-bold text-forest">Quick Stats</h3>
              <dl className="mt-4 space-y-3 text-sm">
                <div className="flex items-center gap-3">
                  <Weight className="h-4 w-4 text-amber" />
                  <dt className="text-charcoal/50">Weight</dt>
                  <dd className="ml-auto font-medium">{animal.weight_kg} kg</dd>
                </div>
                {animal.height_cm && (
                  <div className="flex items-center gap-3">
                    <Ruler className="h-4 w-4 text-amber" />
                    <dt className="text-charcoal/50">Height</dt>
                    <dd className="ml-auto font-medium">{animal.height_cm} cm</dd>
                  </div>
                )}
                <div className="flex items-center gap-3">
                  <Utensils className="h-4 w-4 text-amber" />
                  <dt className="text-charcoal/50">Diet</dt>
                  <dd className="ml-auto font-medium capitalize">{animal.diet_type}</dd>
                </div>
                <div className="flex items-center gap-3">
                  <Heart className="h-4 w-4 text-amber" />
                  <dt className="text-charcoal/50">Total Feedings</dt>
                  <dd className="ml-auto font-medium">{animal.total_feedings?.toLocaleString()}</dd>
                </div>
                {animal.date_of_birth && (
                  <div className="flex items-center gap-3">
                    <Calendar className="h-4 w-4 text-amber" />
                    <dt className="text-charcoal/50">Born</dt>
                    <dd className="ml-auto font-medium">
                      {new Date(animal.date_of_birth).toLocaleDateString('en-GB', { year: 'numeric', month: 'short', day: 'numeric' })}
                    </dd>
                  </div>
                )}
                {animal.origin && (
                  <div className="flex items-center gap-3">
                    <span className="h-4 w-4 text-center text-amber">🌍</span>
                    <dt className="text-charcoal/50">Origin</dt>
                    <dd className="ml-auto font-medium">{animal.origin}</dd>
                  </div>
                )}
              </dl>
            </div>

            {/* Keeper card */}
            {keeper && (
              <div className="card p-6">
                <h3 className="font-display text-lg font-bold text-forest">Assigned Keeper</h3>
                <div className="mt-3 flex items-center gap-3">
                  <div className="flex h-10 w-10 items-center justify-center rounded-full bg-forest/10">
                    <User className="h-5 w-5 text-forest" />
                  </div>
                  <div>
                    <p className="text-sm font-medium">{keeper.full_name}</p>
                    <p className="text-xs text-charcoal/50 capitalize">{keeper.role}</p>
                  </div>
                </div>
              </div>
            )}

            {/* Sex badge */}
            {animal.sex && (
              <div className="card p-6 text-center">
                <span className="text-3xl">{animal.sex === 'male' ? '♂️' : '♀️'}</span>
                <p className="mt-1 text-sm capitalize text-charcoal/60">{animal.sex}</p>
              </div>
            )}
          </motion.aside>
        </div>
      </div>
    </div>
  );
}
