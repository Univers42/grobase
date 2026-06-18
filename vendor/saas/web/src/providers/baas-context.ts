// baas-context.ts — the React context holding the injected Baas client. Split out
// from BaasProvider.tsx so the hook file can import the context without pulling in
// the provider component (no module-singleton client; the value is supplied by the
// provider at the composition root).

import { createContext } from 'react';
import type { Baas } from '../lib/baas';

/** BaasContext carries the injected client; null until a BaasProvider supplies it. */
export const BaasContext = createContext<Baas | null>(null);
