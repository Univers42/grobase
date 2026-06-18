const STATUS_CONFIG = {
  active:     { dot: 'bg-green-500',  text: 'text-green-700',  label: 'Active' },
  resting:    { dot: 'bg-blue-400',   text: 'text-blue-700',   label: 'Resting' },
  medical:    { dot: 'bg-red-400',    text: 'text-red-700',    label: 'Medical' },
  quarantine: { dot: 'bg-orange-400', text: 'text-orange-700', label: 'Quarantine' },
  breeding:   { dot: 'bg-purple-400', text: 'text-purple-700', label: 'Breeding' },
};

export default function StatusBadge({ status, className = '' }) {
  const cfg = STATUS_CONFIG[status] || { dot: 'bg-gray-400', text: 'text-gray-600', label: status };

  return (
    <span className={`inline-flex items-center gap-1.5 text-xs font-medium ${cfg.text} ${className}`}>
      <span className={`h-2 w-2 rounded-full ${cfg.dot}`} />
      {cfg.label}
    </span>
  );
}
