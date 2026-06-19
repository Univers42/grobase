import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import LoadingScreen from '@/components/ui/LoadingScreen';

const LEVEL_RANK = { pro: 4, avanzado: 3, intermedio: 2, principiante: 1 };
const LEVEL_BADGE = {
  pro: 'bg-amber-100 text-amber-700', avanzado: 'bg-ocean/10 text-ocean-deep',
  intermedio: 'bg-ocean-sky/25 text-ocean-deep', principiante: 'bg-emerald-100 text-emerald-700',
};

/** Ranking — public surfer_profiles, ordered by level then name. */
export default function Ranking() {
  const [rows, setRows] = useState(null);

  useEffect(() => {
    baas
      .collection('surfer_profiles')
      .select('user_id,display_name,level,board_quiver,bio,home:beaches!home_break_id(name,slug)')
      .get()
      .then((data) => {
        data.sort((a, b) => (LEVEL_RANK[b.level] || 0) - (LEVEL_RANK[a.level] || 0)
          || (a.display_name || '').localeCompare(b.display_name || ''));
        setRows(data);
      })
      .catch(() => setRows([]));
  }, []);

  return (
    <section className="mx-auto flex max-w-4xl flex-col gap-6 px-5 pb-16 pt-2 sm:px-8">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Comunidad</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Ranking de surfistas</h1>
        <p className="mt-3 text-ocean-mid">La comunidad de Surfind Spain, por nivel y playa de casa.</p>
      </div>

      {rows === null ? (
        <LoadingScreen />
      ) : rows.length ? (
        <div className="space-y-3">
          {rows.map((p, i) => (
            <article key={p.user_id} className="panel flex items-center gap-4 p-4">
              <span className="grid size-10 shrink-0 place-items-center rounded-full bg-ocean text-sm font-black text-white">{i + 1}</span>
              <div className="min-w-0 flex-1">
                <div className="flex flex-wrap items-center gap-2">
                  <span className="font-black text-ocean">{p.display_name || 'Surfista'}</span>
                  {p.level && <span className={`rounded-full px-2.5 py-0.5 text-xs font-bold ${LEVEL_BADGE[p.level] || 'chip'}`}>{p.level}</span>}
                </div>
                {p.bio && <p className="mt-1 line-clamp-1 text-sm text-ocean-mid">{p.bio}</p>}
                {p.board_quiver && <p className="mt-1 text-xs font-semibold text-ocean-teal">🏄 {p.board_quiver}</p>}
              </div>
              {p.home?.slug && (
                <Link to={`/playas/${p.home.slug}`} className="shrink-0 text-sm font-bold text-ocean-teal hover:underline">
                  {p.home.name}
                </Link>
              )}
            </article>
          ))}
        </div>
      ) : (
        <p className="panel px-6 py-14 text-center font-semibold text-ocean-mid">Aún no hay perfiles públicos.</p>
      )}
    </section>
  );
}
