import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import LoadingScreen from '@/components/ui/LoadingScreen';

function timeAgo(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? ''
    : d.toLocaleDateString('es-ES', { day: 'numeric', month: 'short', year: 'numeric' });
}

export default function Community() {
  const [comments, setComments] = useState(null);

  useEffect(() => {
    baas
      .collection('comments')
      .select('id,content,created_at,beach:beaches(name,slug)')
      .eq('published', true)
      .order('created_at', 'desc')
      .limit(40)
      .get()
      .then(setComments)
      .catch(() => setComments([]));
  }, []);

  return (
    <section className="mx-auto flex max-w-5xl flex-col gap-8 px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div className="relative overflow-hidden rounded-[2.25rem] bg-ocean px-6 py-10 text-white shadow-2xl shadow-ocean-deep/20 sm:px-10">
        <div className="absolute -right-16 -top-20 size-72 rounded-full bg-ocean-sky/18 blur-3xl" />
        <p className="relative text-xs font-black uppercase tracking-[0.32em] text-ocean-sky">Comunidad</p>
        <h1 className="relative mt-4 max-w-3xl text-4xl font-black tracking-tight sm:text-5xl">
          Lo último que dice la comunidad surfista
        </h1>
      </div>

      {comments === null ? (
        <LoadingScreen />
      ) : comments.length ? (
        <div className="space-y-4">
          {comments.map((c) => (
            <article key={c.id} className="panel p-5 md:p-6">
              <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                {c.beach?.slug ? (
                  <Link to={`/playas/${c.beach.slug}`} className="font-black text-ocean transition hover:text-ocean-mid">
                    {c.beach.name}
                  </Link>
                ) : (
                  <span className="font-black text-ocean">Playa</span>
                )}
                <time className="text-xs font-semibold text-ocean-teal">{timeAgo(c.created_at)}</time>
              </div>
              <p className="mt-3 whitespace-pre-line text-sm leading-7 text-ocean-mid">{c.content}</p>
            </article>
          ))}
        </div>
      ) : (
        <div className="panel px-6 py-14 text-center">
          <h2 className="text-2xl font-black text-ocean">Todavía no hay comentarios publicados</h2>
        </div>
      )}
    </section>
  );
}
