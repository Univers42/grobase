import { useEffect, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import baas from '@/baas/client';
import Markdown from '@/components/Markdown';
import LoadingScreen from '@/components/ui/LoadingScreen';

/** A single article — renders the markdown body. */
export default function Article() {
  const { slug } = useParams();
  const [article, setArticle] = useState(undefined);

  useEffect(() => {
    setArticle(undefined);
    baas
      .collection('articles')
      .select('*,beach:beaches(name,slug)')
      .eq('slug', slug)
      .eq('published', true)
      .single()
      .then(setArticle)
      .catch(() => setArticle(null));
  }, [slug]);

  if (article === undefined) return <LoadingScreen />;
  if (article === null) {
    return (
      <section className="mx-auto max-w-3xl px-5 py-24 text-center">
        <h1 className="text-3xl font-black text-ocean">Artículo no encontrado</h1>
        <Link to="/blog" className="btn-primary mt-6">Volver al blog</Link>
      </section>
    );
  }

  return (
    <article className="mx-auto max-w-3xl px-5 pb-16 pt-2 sm:px-8">
      <div className="mb-6"><Link to="/blog" className="btn-ghost">← Volver al blog</Link></div>

      {article.cover_image && (
        <img src={article.cover_image} alt={article.title} className="mb-8 h-64 w-full rounded-[2rem] border border-ocean-sky/40 object-cover shadow-xl md:h-80" />
      )}

      <div className="flex flex-wrap gap-2">
        {(article.tags || []).map((t) => <span key={t} className="chip">{t}</span>)}
      </div>
      <h1 className="mt-4 text-4xl font-black tracking-tight text-ocean md:text-5xl">{article.title}</h1>
      <p className="mt-3 text-sm font-bold text-ocean-teal">
        {article.author_name || 'Surfind'}{article.read_minutes ? ` · ${article.read_minutes} min` : ''}
        {article.beach?.slug && (
          <> · <Link to={`/playas/${article.beach.slug}`} className="underline">{article.beach.name}</Link></>
        )}
      </p>

      <div className="panel mt-8 p-6 md:p-10">
        <Markdown>{article.body}</Markdown>
      </div>
    </article>
  );
}
