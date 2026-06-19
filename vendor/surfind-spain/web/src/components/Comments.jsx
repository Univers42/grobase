import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import baas from '@/baas/client';
import useBaasAuth from '@/hooks/useBaasAuth';

function initials(name) {
  return (name || '?')
    .split(' ')
    .map((p) => p[0])
    .slice(0, 2)
    .join('')
    .toUpperCase();
}

function timeAgo(iso) {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleDateString('es-ES', { day: 'numeric', month: 'short', year: 'numeric' });
}

/** Published comments for a beach (newest first) + an add-comment form for signed-in users. */
export default function Comments({ beachId }) {
  const { user, name } = useBaasAuth();
  const [comments, setComments] = useState(null);
  const [content, setContent] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  function load() {
    baas
      .collection('comments')
      .select('id,content,created_at,user_id')
      .eq('beach_id', beachId)
      .eq('published', true)
      .order('created_at', 'desc')
      .get()
      .then(setComments)
      .catch(() => setComments([]));
  }

  useEffect(() => { if (beachId) load(); }, [beachId]);

  async function submit(e) {
    e.preventDefault();
    const text = content.trim();
    if (!text || busy) return;
    setBusy(true);
    setError(null);
    try {
      await baas.collection('comments').insert({ beach_id: beachId, content: text });
      setContent('');
      load();
    } catch (err) {
      setError(err.message || 'No se pudo publicar el comentario');
    } finally {
      setBusy(false);
    }
  }

  return (
    <section id="comentarios" className="panel p-6 md:p-8">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between">
        <div>
          <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Comunidad</p>
          <h2 className="mt-2 text-2xl font-black text-ocean">Comentarios</h2>
        </div>
        {comments && (
          <span className="text-sm font-bold text-ocean-teal">
            {comments.length} {comments.length === 1 ? 'comentario' : 'comentarios'}
          </span>
        )}
      </div>

      {user ? (
        <form onSubmit={submit} className="mt-6 rounded-[1.5rem] bg-ocean-pale/45 p-4">
          <label htmlFor="content" className="sr-only">Publicar comentario</label>
          <textarea
            id="content"
            rows={4}
            maxLength={1000}
            value={content}
            onChange={(e) => setContent(e.target.value)}
            placeholder="Comparte algo útil sobre esta playa…"
            className="block w-full resize-none rounded-[1.25rem] bg-white px-4 py-3 text-sm leading-6 text-ocean shadow-sm outline-none transition placeholder:text-ocean-teal/70 focus:ring-4 focus:ring-ocean-sky/30"
          />
          {error && <p className="mt-2 text-sm font-semibold text-rose-700">{error}</p>}
          <div className="mt-3 flex justify-end">
            <button type="submit" disabled={busy} className="btn-primary px-5 py-2.5 disabled:opacity-60">
              {busy ? 'Publicando…' : 'Publicar'}
            </button>
          </div>
        </form>
      ) : (
        <div className="mt-6 rounded-[1.5rem] bg-ocean-pale/45 p-4 text-sm font-semibold text-ocean-mid">
          <Link to="/acceder" className="font-black text-ocean hover:text-ocean-mid">Inicia sesión</Link> para comentar esta playa.
        </div>
      )}

      <div className="mt-7 space-y-5">
        {comments === null ? (
          <p className="text-sm font-semibold text-ocean-mid">Cargando comentarios…</p>
        ) : comments.length ? (
          comments.map((c) => (
            <article key={c.id} className="flex gap-4">
              <div className="grid size-11 shrink-0 place-items-center rounded-full bg-ocean text-sm font-black text-white shadow-md">
                {initials(c.user_id === user?.id ? name : 'S')}
              </div>
              <div className="min-w-0 flex-1 border-b border-ocean-sky/25 pb-5 last:border-b-0 last:pb-0">
                <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                  <h3 className="font-bold text-ocean">{c.user_id === user?.id ? name : 'Surfista'}</h3>
                  <time className="text-xs font-semibold text-ocean-teal">{timeAgo(c.created_at)}</time>
                </div>
                <p className="mt-2 whitespace-pre-line text-sm leading-7 text-ocean-mid">{c.content}</p>
              </div>
            </article>
          ))
        ) : (
          <p className="rounded-[1.5rem] bg-white/70 p-5 text-sm font-semibold leading-6 text-ocean-mid shadow-sm">
            Todavía no hay comentarios. Sé la primera persona en compartir algo útil sobre esta playa.
          </p>
        )}
      </div>
    </section>
  );
}
