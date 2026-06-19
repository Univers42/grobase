// SessionForm.jsx — log one surf session to the mongo bitácora. Owner-scoped by
// the Bearer (data plane stamps owner_id). onSaved hands the new doc to the page.
import { useState } from 'react';
import { insert } from '@/baas/mongo';

/** Form to log a surf session. beaches[] populates the spot picker. */
export default function SessionForm({ beaches, onSaved }) {
  const [beachId, setBeachId] = useState('');
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [duration, setDuration] = useState('90');
  const [waves, setWaves] = useState('10');
  const [board, setBoard] = useState('');
  const [swell, setSwell] = useState('1.0');
  const [wind, setWind] = useState('');
  const [temp, setTemp] = useState('');
  const [rating, setRating] = useState('4');
  const [tags, setTags] = useState('');
  const [notes, setNotes] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function submit(e) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    const beach = (beaches || []).find((b) => String(b.id) === String(beachId));
    try {
      const doc = await insert({
        beach_id: beachId ? Number(beachId) : null,
        beach_name: beach?.name || null,
        date,
        duration_min: Number(duration),
        waves: Number(waves),
        board: board.trim() || null,
        swell_m: Number(swell),
        wind: wind.trim() || null,
        water_temp_c: temp.trim() || null,
        rating: Number(rating),
        tags: tags.split(',').map((t) => t.trim()).filter(Boolean),
        notes: notes.trim() || null,
      });
      setNotes('');
      setTags('');
      onSaved?.(doc?.row ?? doc?.data ?? doc);
    } catch (err) {
      setError(err.message || 'No se pudo guardar la sesión');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="panel p-6">
      <h2 className="text-lg font-black text-ocean">Registrar sesión</h2>
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <label className="text-sm font-semibold text-ocean-deep sm:col-span-2">Playa
          <select value={beachId} onChange={(e) => setBeachId(e.target.value)} className="field mt-1">
            <option value="">Otra / sin especificar</option>
            {(beaches || []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Fecha
          <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Duración (min)
          <input type="number" min="1" max="600" value={duration} onChange={(e) => setDuration(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Olas cogidas
          <input type="number" min="0" max="500" value={waves} onChange={(e) => setWaves(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Tabla
          <input value={board} onChange={(e) => setBoard(e.target.value)} placeholder="Shortboard 6'0" className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Swell (m)
          <input type="number" step="0.1" min="0" value={swell} onChange={(e) => setSwell(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Viento
          <input value={wind} onChange={(e) => setWind(e.target.value)} placeholder="Terral" className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Temp. agua (°C)
          <input value={temp} onChange={(e) => setTemp(e.target.value)} placeholder="16" className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Valoración (1-5)
          <input type="range" min="1" max="5" value={rating} onChange={(e) => setRating(e.target.value)} className="mt-3 w-full accent-ocean" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep sm:col-span-2">Etiquetas (coma)
          <input value={tags} onChange={(e) => setTags(e.target.value)} placeholder="tubos, amanecer" className="field mt-1" />
        </label>
        <textarea rows={3} value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="¿Cómo fue la sesión?" className="field sm:col-span-2" />
      </div>
      {error && <p className="mt-2 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-4 flex justify-end">
        <button type="submit" disabled={busy} className="btn-primary px-6 py-3 disabled:opacity-60">
          {busy ? 'Guardando…' : 'Guardar sesión'}
        </button>
      </div>
    </form>
  );
}
