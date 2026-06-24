// ReportCard.jsx — one surf_report row. Shows author, beach (optional link),
// the wave facts, quality stars, comment and a relative time.
import { Link } from 'react-router-dom';
import Stars from '@/components/ui/Stars';

function timeAgo(iso) {
  const t = new Date(iso).getTime();
  if (Number.isNaN(t)) return '';
  const mins = Math.round((Date.now() - t) / 60000);
  if (mins < 1) return 'ahora';
  if (mins < 60) return `hace ${mins} min`;
  const hrs = Math.round(mins / 60);
  if (hrs < 24) return `hace ${hrs} h`;
  return `hace ${Math.round(hrs / 24)} d`;
}

/** A single live surf-report card. `beach` (embed) renders a link when present. */
export default function ReportCard({ report }) {
  const beach = report.beach;
  return (
    <article className="rounded-[1.5rem] border border-ocean-sky/30 bg-white/80 p-4 shadow-sm">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex items-center gap-2">
          <span className="font-black text-ocean">{report.author_name || 'Surfista'}</span>
          {beach?.slug && (
            <Link to={`/playas/${beach.slug}`} className="text-sm font-bold text-ocean-teal hover:underline">
              · {beach.name}
            </Link>
          )}
        </div>
        <time className="text-xs font-semibold text-ocean-teal">{timeAgo(report.created_at)}</time>
      </div>
      <div className="mt-3 flex flex-wrap items-center gap-2 text-xs font-bold text-ocean-deep">
        {report.wave_height_m != null && <span className="chip">🌊 {report.wave_height_m} m</span>}
        {report.period_s != null && <span className="chip">⏱ {report.period_s} s</span>}
        {report.wind && <span className="chip">💨 {report.wind}</span>}
        {report.crowd && <span className="chip">👥 {report.crowd}</span>}
        {report.quality != null && <Stars value={report.quality} />}
      </div>
      {report.comment && <p className="mt-3 text-sm leading-6 text-ocean-mid">{report.comment}</p>}
    </article>
  );
}
