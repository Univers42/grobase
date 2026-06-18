// main.js — SPA boot: assert the generated BaaS config is present, mount the
// persistent layout chrome, then start the History-API router. Loaded as a
// module after /baas-config.js has populated window.__BAAS__.

import { assertConfigured } from './lib/baas.js';
import { mountLayout } from './components/layout.js';
import { startRouter } from './router.js';
import { toast } from './lib/dom.js';

/** boot validates config, mounts chrome, and starts routing; fails loudly. */
function boot() {
  try {
    assertConfigured();
  } catch (err) {
    showFatal(err);
    return;
  }
  mountLayout();
  startRouter();
}

/** showFatal renders a clear configuration error when boot cannot proceed. */
function showFatal(err) {
  const root = document.getElementById('app');
  if (root) {
    root.innerHTML =
      '<div class="max-w-[500px] mx-auto mt-20 p-6 bg-white border border-ig-red rounded-lg text-sm text-ig-red"></div>';
    root.firstChild.textContent = err && err.message ? err.message : String(err);
  }
  toast('BaaS not configured', 'error');
  console.error('[canagrou] boot aborted:', err);
}

boot();
