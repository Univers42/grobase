// useBaas.ts — reads the injected Baas client from context. Throws if used outside
// a BaasProvider so a missing composition root fails loudly, not silently.

import { useContext } from 'react';
import type { Baas } from '../lib/baas';
import { BaasContext } from './baas-context';

/** useBaas returns the injected client, asserting a BaasProvider is present. */
export function useBaas(): Baas {
  const client = useContext(BaasContext);
  if (!client) throw new Error('useBaas must be used within a <BaasProvider>');
  return client;
}
