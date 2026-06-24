export default function LoadingScreen({ label = 'Cargando…' }) {
  return (
    <div className="grid min-h-[60vh] place-items-center">
      <div className="flex flex-col items-center gap-4 text-ocean-mid">
        <span className="text-4xl animate-pulse">🌊</span>
        <p className="text-sm font-bold uppercase tracking-[0.28em]">{label}</p>
      </div>
    </div>
  );
}
