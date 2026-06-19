// Conditions.jsx — the 'Condiciones' panel: a labelled grid of the beach's
// surf-intel columns. Skips any field the beach doesn't have.
import Stars from '@/components/ui/Stars';

const FIELDS = [
  ['break_type', 'Tipo de rompiente'],
  ['wave_direction', 'Dirección de la ola'],
  ['best_tide', 'Mejor marea'],
  ['best_season', 'Mejor temporada'],
  ['bottom_type', 'Fondo'],
  ['crowd_level', 'Masificación'],
  ['water_temp_c', 'Temp. del agua'],
  ['hazards', 'Peligros'],
];

/** Surf-condition fact grid for a beach (only shows populated fields). */
export default function Conditions({ beach }) {
  const rows = FIELDS.filter(([k]) => beach[k]);
  if (!rows.length && !beach.wave_quality) return null;
  return (
    <section className="panel p-6 md:p-8">
      <h2 className="text-2xl font-black text-ocean">Condiciones</h2>
      {beach.wave_quality != null && (
        <div className="mt-4 flex items-center gap-3">
          <span className="text-sm font-bold uppercase tracking-wider text-ocean-teal">Calidad de la ola</span>
          <Stars value={beach.wave_quality} />
        </div>
      )}
      <dl className="mt-5 grid gap-x-8 gap-y-4 sm:grid-cols-2">
        {rows.map(([k, label]) => (
          <div key={k} className="border-b border-ocean-sky/25 pb-3">
            <dt className="text-xs font-bold uppercase tracking-wider text-ocean-teal">{label}</dt>
            <dd className="mt-1 font-semibold text-ocean-deep">{beach[k]}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
