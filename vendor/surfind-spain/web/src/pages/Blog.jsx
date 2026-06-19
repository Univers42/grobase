import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import LoadingScreen from '@/components/ui/LoadingScreen';

/** Blog list — published articles newest-first, cards with cover + excerpt. */
export default function Blog() {
  const [articles, setArticles] = useState(null);

  useEffect(() => {
    baas
      .collection('articles')
      .select('slug,title,excerpt,cover_image,author_name,read_minutes,published_at,tags')
      .eq('published', true)
      .order('published_at', 'desc')
      .get()
      .then(setArticles)
      .catch(() => setArticles([]));
  }, []);

  return (
    <section className="mx-auto flex max-w-7xl flex-col gap-8 px-5 pb-16 pt-2 sm:px-8 lg:px-10">
      <div>
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Surfind</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Blog</h1>
        <p className="mt-3 max-w-2xl text-ocean-mid">Guías de playas, técnica y cultura surf de la costa española.</p>
      </div>

      {articles === null ? (
        <LoadingScreen />
      ) : articles.length ? (
        <div className="grid gap-6 md:grid-cols-2 xl:grid-cols-3">
          {articles.map((a) => (
            <Link
              key={a.slug}
              to={`/blog/${a.slug}`}
              className="group overflow-hidden rounded-[2rem] border border-ocean-sky/40 bg-white/80 shadow-xl shadow-ocean-deep/5 backdrop-blur transition hover:-translate-y-1 hover:shadow-2xl"
            >
              {a.cover_image && (
                <img src={a.cover_image} alt={a.title} loading="lazy" className="h-44 w-full object-cover transition duration-500 group-hover:scale-105" />
              )}
              <div className="p-5">
                <div className="flex flex-wrap gap-2">
                  {(a.tags || []).slice(0, 3).map((t) => <span key={t} className="chip">{t}</span>)}
                </div>
                <h2 className="mt-3 text-xl font-black text-ocean transition group-hover:text-ocean-mid">{a.title}</h2>
                <p className="mt-2 line-clamp-3 text-sm leading-6 text-ocean-mid">{a.excerpt}</p>
                <p className="mt-4 text-xs font-bold text-ocean-teal">
                  {a.author_name || 'Surfind'}{a.read_minutes ? ` · ${a.read_minutes} min de lectura` : ''}
                </p>
              </div>
            </Link>
          ))}
        </div>
      ) : (
        <p className="panel px-6 py-14 text-center font-semibold text-ocean-mid">Aún no hay artículos publicados.</p>
      )}
    </section>
  );
}
