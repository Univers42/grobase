// BaasProvider.tsx — constructs the Baas client ONCE (useState initializer) from
// the runtime config and injects it through context. This is the composition
// root; nothing imports a module-level client.

import { useState } from 'react';
import type { ReactNode } from 'react';
import { getConfig } from '../lib/config';
import { createBaas } from '../lib/baas';
import { BaasContext } from './baas-context';

/** BaasProviderProps wraps the app subtree the client is provided to. */
export type BaasProviderProps = { children: ReactNode };

/** BaasProvider builds the client once and supplies it to descendants. */
export function BaasProvider({ children }: BaasProviderProps) {
  const [client] = useState(() => createBaas(getConfig()));
  return <BaasContext.Provider value={client}>{children}</BaasContext.Provider>;
}
