const IUCN = {
  LC: { label: 'Least Concern',     color: 'bg-green-100  text-green-800' },
  NT: { label: 'Near Threatened',   color: 'bg-lime-100   text-lime-800' },
  VU: { label: 'Vulnerable',        color: 'bg-yellow-100 text-yellow-800' },
  EN: { label: 'Endangered',        color: 'bg-orange-100 text-orange-800' },
  CR: { label: 'Critically Endangered', color: 'bg-red-100 text-red-800' },
  EW: { label: 'Extinct in Wild',   color: 'bg-red-200    text-red-900' },
  EX: { label: 'Extinct',           color: 'bg-gray-200   text-gray-800' },
};

export default function ConservationBadge({ status, className = '' }) {
  const cfg = IUCN[status] || { label: status, color: 'bg-gray-100 text-gray-600' };

  return (
    <span
      className={`inline-flex items-center gap-1 rounded-full px-2.5 py-0.5 text-xs font-semibold ${cfg.color} ${className}`}
      title={cfg.label}
    >
      {status}
      <span className="hidden sm:inline">— {cfg.label}</span>
    </span>
  );
}
