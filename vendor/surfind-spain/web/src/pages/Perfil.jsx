import { useEffect, useState } from 'react';
import { Navigate } from 'react-router-dom';
import baas from '@/baas/client';
import useBaasAuth from '@/hooks/useBaasAuth';
import LoadingScreen from '@/components/ui/LoadingScreen';

const LEVELS = ['principiante', 'intermedio', 'avanzado', 'pro'];

/** Perfil — upsert the caller's public surfer_profiles row. */
export default function Perfil() {
  const { user, loading, name } = useBaasAuth();
  const [form, setForm] = useState(null);
  const [beaches, setBeaches] = useState([]);
  const [busy, setBusy] = useState(false);
  const [saved, setSaved] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!user) return;
    baas.collection('beaches').select('id,name').eq('status', 'published').order('name').get()
      .then(setBeaches).catch(() => {});
    baas.collection('surfer_profiles').select('*').eq('user_id', user.id).single()
      .then((p) => setForm(p || {
        display_name: name || '', level: 'intermedio', home_break_id: '', board_quiver: '', bio: '',
      }))
      .catch(() => setForm({ display_name: name || '', level: 'intermedio', home_break_id: '', board_quiver: '', bio: '' }));
  }, [user]);

  function set(k, v) { setForm((f) => ({ ...f, [k]: v })); setSaved(false); }

  async function submit(e) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      await baas.collection('surfer_profiles').upsert({
        user_id: user.id,
        display_name: form.display_name?.trim() || null,
        level: form.level,
        home_break_id: form.home_break_id ? Number(form.home_break_id) : null,
        board_quiver: form.board_quiver?.trim() || null,
        bio: form.bio?.trim() || null,
      });
      setSaved(true);
    } catch (err) {
      setError(err.message || 'No se pudo guardar el perfil');
    } finally {
      setBusy(false);
    }
  }

  if (loading || (user && !form)) return <LoadingScreen />;
  if (!user) return <Navigate to="/acceder" replace />;

  return (
    <section className="mx-auto max-w-2xl px-5 pb-16 pt-2 sm:px-8">
      <div className="mb-6">
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Tu cuenta</p>
        <h1 className="mt-2 text-4xl font-black tracking-tight text-ocean md:text-5xl">Perfil de surfista</h1>
      </div>

      <form onSubmit={submit} className="panel space-y-4 p-6 md:p-8">
        <label className="block text-sm font-semibold text-ocean-deep">Nombre público
          <input value={form.display_name || ''} onChange={(e) => set('display_name', e.target.value)} className="field mt-1" placeholder="Tu nombre de surfista" />
        </label>
        <label className="block text-sm font-semibold text-ocean-deep">Nivel
          <select value={form.level || 'intermedio'} onChange={(e) => set('level', e.target.value)} className="field mt-1">
            {LEVELS.map((l) => <option key={l} value={l}>{l}</option>)}
          </select>
        </label>
        <label className="block text-sm font-semibold text-ocean-deep">Playa de casa
          <select value={form.home_break_id || ''} onChange={(e) => set('home_break_id', e.target.value)} className="field mt-1">
            <option value="">Sin elegir</option>
            {beaches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </label>
        <label className="block text-sm font-semibold text-ocean-deep">Quiver (tablas)
          <input value={form.board_quiver || ''} onChange={(e) => set('board_quiver', e.target.value)} className="field mt-1" placeholder="Shortboard 6'0, fish 5'8…" />
        </label>
        <label className="block text-sm font-semibold text-ocean-deep">Bio
          <textarea rows={3} value={form.bio || ''} onChange={(e) => set('bio', e.target.value)} className="field mt-1" placeholder="Cuéntale a la comunidad sobre ti" />
        </label>
        {error && <p className="text-sm font-semibold text-rose-700">{error}</p>}
        {saved && <p className="text-sm font-semibold text-emerald-700">✓ Perfil guardado.</p>}
        <button type="submit" disabled={busy} className="btn-primary w-full disabled:opacity-60">
          {busy ? 'Guardando…' : 'Guardar perfil'}
        </button>
      </form>
    </section>
  );
}
