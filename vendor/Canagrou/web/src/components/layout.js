// layout.js — the persistent app chrome: navbar (auth-aware), a content slot
// pages render into, and a footer. Mounts once into #app; the router calls
// renderNav() on each navigation and swaps content via contentSlot().

import { baas } from '../lib/baas.js';
import { el, clear } from '../lib/dom.js';

/** brandLogo returns the gradient Canagrou wordmark linking home. */
function brandLogo() {
  const mark = el('span', {
    class: 'text-xl font-extrabold bg-gradient-to-r from-purple-600 via-pink-500 to-orange-400 bg-clip-text text-transparent',
  });
  mark.textContent = 'Canagrou';
  return el('a', { href: '/', 'data-link': true, class: 'flex items-center gap-2 flex-shrink-0' }, [mark]);
}

/** navLink builds a header link, highlighting it when it matches the path. */
function navLink(href, label, path) {
  const active = path === href;
  return el(
    'a',
    {
      href,
      'data-link': true,
      class: `text-sm font-semibold transition-colors ${active ? 'text-ig-text' : 'text-ig-muted hover:text-ig-text'}`,
    },
    [label],
  );
}

/** authedLinks returns the create/settings/logout cluster for a signed-in user. */
function authedLinks(path) {
  const logout = el('button', { class: 'text-sm font-semibold text-ig-red hover:opacity-70 transition-opacity' }, [
    'Log Out',
  ]);
  logout.addEventListener('click', onLogout);
  return [navLink('/editor', 'Create', path), navLink('/settings', 'Settings', path), logout];
}

/** guestLinks returns the log-in / sign-up buttons for an anonymous visitor. */
function guestLinks(path) {
  const login = el('a', {
    href: '/login',
    'data-link': true,
    class: 'px-4 py-[6px] rounded-lg text-sm font-semibold text-white bg-ig-blue hover:bg-blue-600 transition-colors',
  });
  login.textContent = 'Log In';
  const register = navLink('/register', 'Sign Up', path);
  return [login, register];
}

/** onLogout signs out then routes home via the global navigate helper. */
async function onLogout() {
  try {
    await baas.auth.signOut();
  } catch (err) {
    console.warn('[layout] signOut error', err && err.message);
  }
  window.canagrouNavigate('/');
}

/**
 * renderNav (re)builds the navbar reflecting the current auth state and path.
 * Called by the router after every navigation.
 */
export function renderNav(path) {
  const nav = document.getElementById('app-nav');
  if (!nav) return;
  clear(nav);
  const right = el('div', { class: 'flex items-center gap-5' }, [
    navLink('/', 'Gallery', path),
    ...(baas.auth.isAuthed() ? authedLinks(path) : guestLinks(path)),
  ]);
  nav.append(brandLogo(), right);
}

/** contentSlot returns the page-content container the router fills per route. */
export function contentSlot() {
  return document.getElementById('app-content');
}

/**
 * mountLayout installs the fixed chrome (header/nav, content slot, footer) into
 * #app exactly once, returning the content slot for the router to populate.
 */
export function mountLayout() {
  const root = document.getElementById('app');
  clear(root);
  const nav = el('nav', {
    id: 'app-nav',
    class: 'max-w-[935px] mx-auto px-4 h-[60px] flex items-center justify-between',
  });
  const header = el('header', { class: 'sticky top-0 z-50 bg-white border-b border-ig-border' }, [nav]);
  const content = el('main', { id: 'app-content', class: 'flex-1 w-full' });
  const footer = el(
    'footer',
    { class: 'mt-auto border-t border-ig-border bg-white' },
    [
      el('div', { class: 'max-w-[935px] mx-auto px-4 py-8 text-center text-xs text-ig-muted' }, [
        `© ${new Date().getFullYear()} Canagrou — Capture, Create, Share`,
      ]),
    ],
  );
  root.append(header, content, footer);
  return content;
}
