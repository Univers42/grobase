export const DIFFICULTY_LABELS = {
  beginner: 'Principiante',
  intermediate: 'Intermedio',
  advanced: 'Avanzado',
};

const TONES = {
  beginner: 'bg-emerald-100 text-emerald-800',
  intermediate: 'bg-amber-100 text-amber-800',
  advanced: 'bg-rose-100 text-rose-800',
};

/** Difficulty pill in Spanish; tone keyed to surf level. */
export default function DifficultyBadge({ value, className = '' }) {
  if (!value) return null;
  const tone = TONES[value] || 'bg-ocean-pale text-ocean-deep';
  return (
    <span className={`rounded-full px-3 py-1 text-xs font-bold ${tone} ${className}`}>
      {DIFFICULTY_LABELS[value] || value}
    </span>
  );
}
