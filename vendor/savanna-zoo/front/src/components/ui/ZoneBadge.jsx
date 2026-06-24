const ZONE_CONFIG = {
  savannah:   { label: 'Savannah',   emoji: '🦁', bg: 'bg-amber/15',         text: 'text-amber-dark' },
  arctic:     { label: 'Arctic',     emoji: '🐻‍❄️', bg: 'bg-blue-100',         text: 'text-blue-700' },
  rainforest: { label: 'Rainforest', emoji: '🌿', bg: 'bg-green-100',        text: 'text-green-700' },
  aquarium:   { label: 'Aquarium',   emoji: '🐠', bg: 'bg-cyan-100',         text: 'text-cyan-700' },
  reptile:    { label: 'Reptile',    emoji: '🐊', bg: 'bg-lime-100',         text: 'text-lime-700' },
  aviary:     { label: 'Aviary',     emoji: '🦩', bg: 'bg-pink-100',         text: 'text-pink-700' },
  petting:    { label: 'Petting',    emoji: '🐰', bg: 'bg-yellow-100',       text: 'text-yellow-700' },
};

export default function ZoneBadge({ zone, className = '' }) {
  const cfg = ZONE_CONFIG[zone] || { label: zone, emoji: '📍', bg: 'bg-gray-100', text: 'text-gray-700' };

  return (
    <span className={`zone-badge ${cfg.bg} ${cfg.text} ${className}`}>
      <span>{cfg.emoji}</span>
      {cfg.label}
    </span>
  );
}

export { ZONE_CONFIG };
