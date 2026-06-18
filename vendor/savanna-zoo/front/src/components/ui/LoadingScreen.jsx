import { TreePine } from 'lucide-react';

export default function LoadingScreen() {
  return (
    <div className="flex min-h-screen items-center justify-center bg-ivory">
      <div className="flex flex-col items-center gap-4">
        <TreePine className="h-12 w-12 animate-pulse-slow text-forest" />
        <p className="font-display text-lg text-forest/60">Loading…</p>
      </div>
    </div>
  );
}
