// Stars.jsx — read-only ★ rating display. value is 0-5 (numeric ok).
export default function Stars({ value = 0, count, className = '' }) {
  const v = Math.round(Number(value) || 0);
  return (
    <span className={`inline-flex items-center gap-1 ${className}`} aria-label={`${value} de 5`}>
      <span className="text-amber-400" aria-hidden="true">
        {'★'.repeat(v)}<span className="text-ocean-sky/40">{'★'.repeat(5 - v)}</span>
      </span>
      {count != null && <span className="text-xs font-semibold text-ocean-teal">({count})</span>}
    </span>
  );
}
