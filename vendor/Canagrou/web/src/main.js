// main.js — SPA boot: assert the generated BaaS config is present, mount the
// persistent layout chrome, then start the History-API router. Loaded as a
// module after /baas-config.js has populated window.__BAAS__.

import { baas, assertConfigured } from './lib/baas.js';
import { ensureProfile } from './lib/profiles.js';
import { mountLayout } from './components/layout.js';
import { startRouter } from './router.js';
import { toast } from './lib/dom.js';

/** boot validates config, mounts chrome, starts routing, and self-heals the
 * signed-in user's profile; fails loudly on a config error. */
function boot() {
  try {
    assertConfigured();
  } catch (err) {
    showFatal(err);
    return;
  }
  mountLayout();
  startRouter();
  healSession();
}

/** healSession ensures a logged-in user (incl. a session predating profile
 * creation) has a profiles row, so every write that FKs to profiles —
 * posts/likes/comments — succeeds. Best-effort; never blocks boot. */
function healSession() {
  if (!baas.auth.isAuthed()) return;
  ensureProfile().catch((err) => console.warn('[canagrou] profile heal failed:', err && err.message));
}

/** showFatal renders a clear configuration error when boot cannot proceed. */
function showFatal(err) {
  const root = document.getElementById('app');
  if (root) {
    root.innerHTML =
      '<div class="max-w-[480px] mx-auto mt-24 alert alert-error text-sm"><span></span></div>';
    root.querySelector('span').textContent = err && err.message ? err.message : String(err);
  }
  toast('BaaS not configured', 'error');
  console.error('[canagrou] boot aborted:', err);
}

boot();
