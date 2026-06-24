// baas.ts — the single Grobase client factory. createBaas composes the verified
// gateway surfaces (auth · db · tx · realtime) into one client. It is NOT a module
// singleton: the app constructs it once at the composition root and injects it
// through BaasProvider, so there is no global mutable state.

import type { BaasConfig } from './config';
import { createSessionStore } from './session';
import type { Auth } from './auth';
import { createAuth } from './auth';
import type { Db } from './db';
import { createDb } from './db';
import type { Tx } from './tx';
import { createTx } from './tx';
import type { Realtime } from './realtime';
import { createRealtime } from './realtime';

/** Baas is the composed client surface injected through React context. */
export type Baas = {
  config: BaasConfig;
  auth: Auth;
  db: { pg: Db; mongo: Db };
  tx: Tx;
  realtime: Realtime;
};

/** createBaas builds the client bound to a config. db.pg targets the Postgres
 * mount (pgDbId), db.mongo the Mongo mount (mongoDbId). The session store backs
 * auth (the GoTrue JWT) AND supplies that JWT to every db/tx call (read at call
 * time via `token`), so the data plane owner-scopes each request off the caller's
 * identity — never off the public app key alone. */
export function createBaas(config: BaasConfig): Baas {
  const store = createSessionStore();
  const token = () => store.load()?.accessToken ?? '';
  return {
    config,
    auth: createAuth(config, store),
    db: { pg: createDb(config, config.pgDbId, token), mongo: createDb(config, config.mongoDbId, token) },
    tx: createTx(config, config.pgDbId, token),
    realtime: createRealtime(config),
  };
}
