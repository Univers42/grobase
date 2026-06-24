// ReportForm.jsx — post a surf_report. Used per-beach (beachId fixed) and on the
// global /reportes feed (beach picker). Sends the owner Bearer; author_name from
// the signed-in profile name. onPosted lets the parent optimistically prepend.
import { useState } from 'react';
import baas from '@/baas/client';

/** Quick surf-report form. Pass beachId to fix the beach, or beaches[] to pick. */
export default function ReportForm({ beachId, beaches, authorName, onPosted }) {
  const [pick, setPick] = useState('');
  const [height, setHeight] = useState('1.0');
  const [period, setPeriod] = useState('10');
  const [wind, setWind] = useState('');
  const [crowd, setCrowd] = useState('Medio');
  const [quality, setQuality] = useState('3');
  const [comment, setComment] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function submit(e) {
    e.preventDefault();
    const bid = beachId || Number(pick);
    if (!bid || busy) return;
    setBusy(true);
    setError(null);
    try {
      const row = await baas.collection('surf_reports').insert({
        beach_id: bid,
        author_name: authorName || 'Surfista',
        wave_height_m: Number(height),
        period_s: Number(period),
        wind: wind.trim() || null,
        crowd,
        quality: Number(quality),
        comment: comment.trim() || null,
      });
      setComment('');
      setWind('');
      onPosted?.(row);
    } catch (err) {
      setError(err.message || 'No se pudo publicar el reporte');
    } finally {
      setBusy(false);
    }
  }

  return (
    <form onSubmit={submit} className="rounded-[1.5rem] bg-ocean-pale/45 p-4">
      <div className="grid gap-3 sm:grid-cols-2">
        {!beachId && (
          <select value={pick} onChange={(e) => setPick(e.target.value)} required className="field sm:col-span-2">
            <option value="">Elige una playa…</option>
            {(beaches || []).map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
          </select>
        )}
        <label className="text-sm font-semibold text-ocean-deep">Altura (m)
          <input type="number" step="0.1" min="0" max="15" value={height} onChange={(e) => setHeight(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Periodo (s)
          <input type="number" min="1" max="30" value={period} onChange={(e) => setPeriod(e.target.value)} className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Viento
          <input value={wind} onChange={(e) => setWind(e.target.value)} placeholder="Terral flojo" className="field mt-1" />
        </label>
        <label className="text-sm font-semibold text-ocean-deep">Gente
          <select value={crowd} onChange={(e) => setCrowd(e.target.value)} className="field mt-1">
            {['Bajo', 'Medio', 'Alto'].map((c) => <option key={c} value={c}>{c}</option>)}
          </select>
        </label>
        <label className="text-sm font-semibold text-ocean-deep sm:col-span-2">Calidad (1-5)
          <input type="range" min="1" max="5" value={quality} onChange={(e) => setQuality(e.target.value)} className="mt-2 w-full accent-ocean" />
        </label>
        <textarea
          rows={2} maxLength={400} value={comment} onChange={(e) => setComment(e.target.value)}
          placeholder="¿Cómo está hoy?" className="field sm:col-span-2"
        />
      </div>
      {error && <p className="mt-2 text-sm font-semibold text-rose-700">{error}</p>}
      <div className="mt-3 flex justify-end">
        <button type="submit" disabled={busy} className="btn-primary px-5 py-2.5 disabled:opacity-60">
          {busy ? 'Publicando…' : 'Publicar reporte'}
        </button>
      </div>
    </form>
  );
}
