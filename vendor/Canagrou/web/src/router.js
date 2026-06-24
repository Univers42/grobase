// router.js — History-API SPA router with an auth guard. Maps a path to a page
// renderer, intercepts in-app link clicks ([data-link]), handles popstate and
// the initial load, and redirects unauthenticated users away from protected
// routes. Pages are lazy-imported so each loads only when first visited.

import { baas } from './lib/baas.js';
import { renderNav, contentSlot } from './components/layout.js';
import { clear, toast } from './lib/dom.js';

const PROTECTED = new Set(['/editor', '/settings']);

const lifecycle = { cleanup: null };

const ROUTES = {
  '/': () => import('./pages/gallery.js'),
  '/login': () => import('./pages/login.js'),
  '/register': () => import('./pages/register.js'),
  '/verify': () => import('./pages/verify.js'),
  '/forgot-password': () => import('./pages/forgot-password.js'),
  '/reset-password': () => import('./pages/reset-password.js'),
  '/editor': () => import('./pages/editor.js'),
  '/settings': () => import('./pages/settings.js'),
};

const PARAM_ROUTES = [
  { prefix: '/profile/', loader: () => import('./pages/profile.js'), key: 'userId' },
  { prefix: '/tag/', loader: () => import('./pages/tag.js'), key: 'tag' },
];

/**
 * matchParamRoute resolves a parameterized path (/profile/:userId, /tag/:tag) to
 * its loader and a decoded {key:value} param, or null when none match.
 * @param pathname the current pathname
 */
function matchParamRoute(pathname) {
  for (const route of PARAM_ROUTES) {
    if (!pathname.startsWith(route.prefix)) continue;
    const raw = pathname.slice(route.prefix.length).split('/')[0];
    if (!raw) continue;
    return { loader: route.loader, params: { [route.key]: decodeURIComponent(raw) } };
  }
  return null;
}

/**
 * navigate pushes a new path (unless replacing/same) and renders it. Exposed as
 * window.canagrouNavigate so non-router modules (layout, pages) can redirect.
 * @param path    the target pathname
 * @param replace use history.replaceState instead of pushState
 */
export function navigate(path, replace = false) {
  const url = new URL(path, window.location.origin);
  if (url.pathname + url.search !== window.location.pathname + window.location.search) {
    if (replace) window.history.replaceState({}, '', url);
    else window.history.pushState({}, '', url);
  }
  render();
}

/** guard redirects protected routes to /login when not authenticated. */
function guard(pathname) {
  if (PROTECTED.has(pathname) && !baas.auth.isAuthed()) {
    toast('Please log in to continue', 'info');
    return '/login';
  }
  return pathname;
}

/** render resolves the current path, refreshes the nav, and mounts the page. */
async function render() {
  const pathname = guard(window.location.pathname);
  if (pathname !== window.location.pathname) {
    window.history.replaceState({}, '', pathname);
  }
  renderNav(pathname);
  const slot = contentSlot();
  if (!slot) return;
  const param = matchParamRoute(pathname);
  const loader = param ? param.loader : ROUTES[pathname] || ROUTES['/'];
  await mountPage(loader, slot, param ? param.params : null);
}

/**
 * mountPage tears down the previous page (calling its returned cleanup), clears
 * the slot, lazy-imports the next page module, and runs its default(slot,params)
 * renderer — storing any cleanup function it returns for the next navigation.
 * @param params decoded route params for parameterized routes, else null
 */
async function mountPage(loader, slot, params) {
  if (typeof lifecycle.cleanup === 'function') {
    try {
      lifecycle.cleanup();
    } catch (err) {
      console.warn('[router] cleanup error', err && err.message);
    }
  }
  lifecycle.cleanup = null;
  clear(slot);
  slot.classList.remove('route-enter');
  void slot.offsetWidth;
  slot.classList.add('route-enter');
  try {
    const mod = await loader();
    lifecycle.cleanup = (await mod.default(slot, params)) || null;
  } catch (err) {
    console.error('[router] page render failed', err);
    toast(err && err.message ? err.message : 'Page failed to load', 'error');
  }
}

/** onLinkClick intercepts left-clicks on [data-link] anchors for SPA nav. */
function onLinkClick(event) {
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
  const link = event.target.closest('a[data-link]');
  if (!link) return;
  const href = link.getAttribute('href');
  if (!href || href.startsWith('http')) return;
  event.preventDefault();
  navigate(href);
}

/**
 * startRouter wires global listeners (link clicks, popstate), exposes the
 * navigate helper, and renders the initial route for the current URL.
 */
export function startRouter() {
  window.canagrouNavigate = navigate;
  document.addEventListener('click', onLinkClick);
  window.addEventListener('popstate', render);
  render();
}
