import { Link } from 'react-router-dom';
import DifficultyBadge from '@/components/ui/DifficultyBadge';
import WaveIcon from '@/components/ui/WaveIcon';
import Stars from '@/components/ui/Stars';
import { beachAmenities, beachCover } from '@/baas/beaches';

/** Beach card: cover (or wave placeholder), name, location, difficulty, short description, amenities. */
export default function BeachCard({ beach }) {
  const cover = beachCover(beach);
  const amenities = beachAmenities(beach);
  const visible = amenities.slice(0, 4);
  const hidden = Math.max(amenities.length - visible.length, 0);

  return (
    <article className="group overflow-hidden rounded-[2rem] border border-ocean-sky/40 bg-white/80 shadow-xl shadow-ocean-deep/5 backdrop-blur transition duration-300 hover:-translate-y-1 hover:shadow-2xl">
      <Link to={`/playas/${beach.slug}`} className="block">
        <div className="relative h-56 overflow-hidden bg-ocean-sky/15">
          {cover ? (
            <img
              src={cover}
              alt={beach.name}
              loading="lazy"
              className="h-full w-full object-cover transition duration-500 group-hover:scale-105"
            />
          ) : (
            <div className="grid h-full place-items-center text-ocean-deep">
              <WaveIcon />
            </div>
          )}
          <div className="absolute left-4 top-4 flex flex-wrap gap-2">
            <DifficultyBadge value={beach.difficulty} className="bg-white/90 !text-ocean-deep" />
            {beach.location?.name && (
              <span className="rounded-full bg-ocean/85 px-3 py-1 text-xs font-bold text-white shadow-sm backdrop-blur">
                {beach.location.name}
              </span>
            )}
          </div>
        </div>
      </Link>

      <div className="p-5">
        <div className="flex items-start justify-between gap-3">
          <Link to={`/playas/${beach.slug}`}>
            <h2 className="text-xl font-black text-ocean transition hover:text-ocean-mid">{beach.name}</h2>
          </Link>
          {Number(beach.rating_count) > 0 && (
            <Stars value={beach.rating_avg} count={beach.rating_count} className="shrink-0 pt-1" />
          )}
        </div>
        {(beach.break_type || beach.difficulty) && (
          <div className="mt-2 flex flex-wrap gap-2">
            {beach.break_type && (
              <span className="rounded-full bg-ocean/10 px-3 py-1 text-xs font-bold text-ocean-deep">
                🌊 {beach.break_type}
              </span>
            )}
            <DifficultyBadge value={beach.difficulty} className="!text-ocean-deep" />
          </div>
        )}
        <p className="mt-3 line-clamp-3 min-h-[4.5rem] text-sm leading-6 text-ocean-mid">
          {beach.short_description || 'Playa publicada en Surfind Spain.'}
        </p>
        <div className="mt-4 flex min-h-8 flex-wrap gap-2">
          {visible.length ? (
            visible.map((a, i) => (
              <span key={i} className="chip">
                {a.icon ? `${a.icon} ` : ''}
                {a.name}
              </span>
            ))
          ) : (
            <span className="text-xs font-semibold text-ocean-teal">Sin servicios indicados</span>
          )}
          {hidden > 0 && <span className="chip ring-1 ring-ocean-sky/45">+{hidden}</span>}
        </div>
        <div className="mt-5 flex items-center justify-end border-t border-ocean-sky/25 pt-4 text-sm font-semibold">
          <Link to={`/playas/${beach.slug}`} className="text-ocean transition hover:text-ocean-mid">
            Ver playa →
          </Link>
        </div>
      </div>
    </article>
  );
}
