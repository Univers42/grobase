import { useEffect, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import baas from '@/baas/client';
import { beachAmenities, beachBySlug, beachCover, beachGallery } from '@/baas/beaches';
import DifficultyBadge from '@/components/ui/DifficultyBadge';
import WaveIcon from '@/components/ui/WaveIcon';
import BeachMap from '@/components/BeachMap';
import Comments from '@/components/Comments';
import Conditions from '@/components/Conditions';
import VideoEmbed from '@/components/VideoEmbed';
import RateBeach from '@/components/RateBeach';
import BeachReports from '@/components/BeachReports';
import LoadingScreen from '@/components/ui/LoadingScreen';
import useBaasAuth from '@/hooks/useBaasAuth';
import useFavorite from '@/hooks/useFavorite';

export default function BeachDetail() {
  const { slug } = useParams();
  const navigate = useNavigate();
  const { user } = useBaasAuth();
  const [beach, setBeach] = useState(undefined);
  const [guide, setGuide] = useState(null);

  useEffect(() => {
    setBeach(undefined);
    setGuide(null);
    beachBySlug(slug).then((b) => {
      setBeach(b);
      if (b?.id) {
        baas.collection('articles').select('slug,title').eq('beach_id', b.id).eq('published', true)
          .order('published_at', 'desc').limit(1).get()
          .then((rows) => setGuide(rows[0] || null)).catch(() => {});
      }
    }).catch(() => setBeach(null));
  }, [slug]);

  const fav = useFavorite(beach?.id, !!user);

  if (beach === undefined) return <LoadingScreen />;
  if (beach === null) {
    return (
      <section className="mx-auto max-w-3xl px-5 py-24 text-center">
        <h1 className="text-3xl font-black text-ocean">Playa no encontrada</h1>
        <Link to="/playas" className="btn-primary mt-6">Volver a playas</Link>
      </section>
    );
  }

  const cover = beachCover(beach);
  const gallery = beachGallery(beach);
  const amenities = beachAmenities(beach);
  const hasCoords = beach.latitude != null && beach.longitude != null;

  return (
    <article className="mx-auto max-w-7xl px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div className="mb-6">
        <Link to="/playas" className="btn-ghost">← Volver a playas</Link>
      </div>

      <section className="overflow-hidden rounded-[2.5rem] border border-ocean-sky/45 bg-white/70 shadow-2xl shadow-ocean-deep/10 backdrop-blur">
        <div className="relative h-[22rem] bg-ocean-sky/15 md:h-[30rem]">
          {cover ? (
            <>
              <img src={cover} alt={beach.name} className="h-full w-full object-cover" />
              <div className="absolute inset-0 bg-gradient-to-t from-ocean/80 via-ocean/25 to-transparent" />
            </>
          ) : (
            <div className="grid h-full place-items-center text-ocean-deep">
              <WaveIcon className="size-16" />
            </div>
          )}

          {user && (
            <div className="absolute right-5 top-5 z-10">
              <button
                onClick={fav.toggle}
                disabled={fav.busy}
                aria-label={fav.saved ? 'Quitar de guardadas' : 'Guardar playa'}
                className="inline-flex items-center gap-2 rounded-full border border-white/80 bg-white/90 px-4 py-2.5 text-sm font-black text-ocean shadow-xl backdrop-blur transition hover:-translate-y-0.5 hover:bg-white disabled:opacity-60"
              >
                <span className={fav.saved ? 'text-rose-500' : 'text-ocean'}>{fav.saved ? '♥' : '♡'}</span>
                <span>{fav.saved ? 'Guardada' : 'Guardar'}</span>
              </button>
            </div>
          )}

          <div className="absolute inset-x-0 bottom-0 p-6 md:p-8">
            <div className="flex flex-wrap gap-2">
              {beach.location?.name && (
                <span className="rounded-full bg-white/90 px-3 py-1 text-xs font-bold text-ocean-deep shadow-sm backdrop-blur">
                  {beach.location.name}
                </span>
              )}
              <DifficultyBadge value={beach.difficulty} />
            </div>
            <h1 className="mt-4 max-w-4xl text-4xl font-black tracking-tight text-white md:text-6xl">{beach.name}</h1>
            {beach.short_description && (
              <p className="mt-4 max-w-3xl text-base leading-7 text-white/90 md:text-lg">{beach.short_description}</p>
            )}
          </div>
        </div>
      </section>

      {gallery.length > 0 && (
        <div className="mt-6 flex gap-4 overflow-x-auto pb-2">
          {gallery.map((src, i) => (
            <img
              key={i}
              src={src}
              alt={`${beach.name} ${i + 1}`}
              loading="lazy"
              className="h-40 w-64 shrink-0 rounded-2xl border border-ocean-sky/40 object-cover shadow-md"
            />
          ))}
        </div>
      )}

      <div className="mt-8 grid gap-8 xl:grid-cols-[1fr_360px]">
        <div className="space-y-8">
          <section className="panel p-6 md:p-8">
            <h2 className="text-2xl font-black text-ocean">Descripción</h2>
            <p className="mt-5 whitespace-pre-line text-base leading-8 text-ocean-mid">
              {beach.description || 'Esta playa aún no tiene una descripción completa.'}
            </p>
          </section>

          <Conditions beach={beach} />

          <VideoEmbed title={beach.name} region={beach.location?.name} poster={beach.cover_image} />

          <BeachReports beachId={beach.id} />

          <Comments beachId={beach.id} />
        </div>

        <aside className="space-y-5 xl:sticky xl:top-6 xl:self-start">
          <RateBeach beachId={beach.id} user={user} avg={beach.rating_avg} count={beach.rating_count} />

          {guide && (
            <Link to={`/blog/${guide.slug}`} className="panel block p-6 transition hover:-translate-y-0.5 hover:shadow-2xl">
              <p className="text-xs font-bold uppercase tracking-wider text-ocean-teal">Guía de la playa</p>
              <p className="mt-2 font-black text-ocean">{guide.title}</p>
              <p className="mt-2 text-sm font-bold text-ocean-teal">Leer guía →</p>
            </Link>
          )}

          <section className="panel p-6">
            <h2 className="text-lg font-black text-ocean">Servicios</h2>
            <div className="mt-5 flex flex-wrap gap-2">
              {amenities.length ? (
                amenities.map((a, i) => (
                  <span key={i} className="rounded-full bg-ocean-sky/12 px-4 py-2 text-sm font-bold text-ocean-deep shadow-sm">
                    {a.icon ? `${a.icon} ` : ''}{a.name}
                  </span>
                ))
              ) : (
                <span className="text-sm font-semibold text-ocean-teal">Aún no hay servicios indicados.</span>
              )}
            </div>
          </section>

          {hasCoords && (
            <section className="panel overflow-hidden p-2">
              <BeachMap
                beaches={[beach]}
                focusSlug={beach.slug}
                onSelect={(s) => navigate(`/playas/${s}`)}
                className="h-72"
              />
            </section>
          )}
        </aside>
      </div>
    </article>
  );
}
