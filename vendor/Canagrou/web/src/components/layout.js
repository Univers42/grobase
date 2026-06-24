// layout.js — the persistent app chrome: a glassy top nav (auth-aware, with the
// avatar menu), a content slot pages render into, a footer, and a mobile bottom
// tab bar. Mounts once into #app; the router calls renderNav() on every
// navigation and swaps page content via contentSlot().

import { baas } from '../lib/baas.js';
import { el, clear } from '../lib/dom.js';
import { icon } from './icons.js';
import { createUserMenu } from './user-menu.js';

/** brandLogo returns the gradient Canagrou wordmark linking home. */
function brandLogo() {
  return el('a', { href: '/', 'data-link': true, class: 'flex items-center gap-2 flex-shrink-0 group' }, [
    el('span', { class: 'text-purple-600 group-hover:scale-110 transition-transform' }, [icon('sparkle', 'w-6 h-6')]),
    el('span', { class: 'text-xl font-extrabold tracking-tight brand-text' }, ['Canagrou']),
  ]);
}

/** navLink builds a header text link with the animated active underline. */
function navLink(href, label, path, testid) {
  const active = path === href;
  return el('a', {
    href,
    'data-link': true,
    class: `nav-link text-sm font-semibold ${active ? 'active text-ig-text' : 'text-ig-muted hover:text-ig-text'}`,
    dataset: { testid },
  }, [label]);
}

/** ctaCreate returns the prominent gradient "Create" button. */
function ctaCreate(path) {
  return el('a', {
    href: '/editor',
    'data-link': true,
    class: 'btn btn-primary px-4 py-2 text-sm',
    dataset: { testid: 'nav-create' },
  }, [icon('plus', 'w-4 h-4'), el('span', { class: 'hidden sm:inline' }, ['Create'])]);
}

/** guestLinks returns the log-in / sign-up buttons for an anonymous visitor. */
function guestLinks(path) {
  const login = el('a', {
    href: '/login',
    'data-link': true,
    class: 'btn btn-ghost px-3 py-2 text-sm',
    dataset: { testid: 'nav-login' },
  }, ['Log in']);
  const register = el('a', {
    href: '/register',
    'data-link': true,
    class: 'btn btn-primary px-4 py-2 text-sm',
    dataset: { testid: 'nav-register' },
  }, ['Sign up']);
  return [login, register];
}

/**
 * renderNav (re)builds the navbar reflecting the current auth state and path.
 * Called by the router after every navigation.
 */
export function renderNav(path) {
  const nav = document.getElementById('app-nav');
  if (!nav) return;
  clear(nav);
  const authed = baas.auth.isAuthed();
  const links = el('div', { class: 'hidden md:flex items-center gap-7' }, [navLink('/', 'Gallery', path, 'nav-gallery')]);
  const right = el('div', { class: 'flex items-center gap-3' }, authed ? [ctaCreate(path), createUserMenu()] : guestLinks(path));
  nav.append(brandLogo(), links, right);
  renderMobileNav(path, authed);
}

/** renderMobileNav (re)builds the bottom tab bar shown on small screens. */
function renderMobileNav(path, authed) {
  const bar = document.getElementById('mobile-nav');
  if (!bar) return;
  clear(bar);
  const tabs = [tabLink('/', 'home', 'Gallery', path, 'nav-gallery-m')];
  if (authed) {
    tabs.push(tabLink('/editor', 'plus', 'Create', path, 'nav-create-m'));
    tabs.push(tabLink('/settings', 'gear', 'Settings', path, 'nav-settings-m'));
  } else {
    tabs.push(tabLink('/login', 'logout', 'Log in', path, 'nav-login-m'));
  }
  bar.append(...tabs);
}

/** tabLink builds one bottom-bar icon tab, highlighting the active route. */
function tabLink(href, glyph, label, path, testid) {
  const active = path === href;
  return el('a', {
    href,
    'data-link': true,
    class: `flex flex-col items-center gap-0.5 px-3 py-1 text-[10px] font-semibold transition-colors ${active ? 'text-purple-600' : 'text-ig-muted'}`,
    dataset: { testid },
  }, [icon(glyph, 'w-6 h-6', active && glyph === 'home'), label]);
}

/** contentSlot returns the page-content container the router fills per route. */
export function contentSlot() {
  return document.getElementById('app-content');
}

/**
 * mountLayout installs the fixed chrome (header/nav, content slot, footer, mobile
 * bar) into #app exactly once, returning the content slot for the router.
 */
export function mountLayout() {
  const root = document.getElementById('app');
  clear(root);
  const nav = el('nav', { id: 'app-nav', class: 'max-w-[1040px] mx-auto px-4 h-16 flex items-center justify-between gap-4' });
  const header = el('header', { class: 'sticky top-0 z-40 glass-nav' }, [nav]);
  const content = el('main', { id: 'app-content', class: 'flex-1 w-full pb-20 md:pb-0' });
  const mobile = el('nav', {
    id: 'mobile-nav',
    class: 'md:hidden fixed bottom-0 inset-x-0 z-40 glass-nav flex items-center justify-around h-16 px-2',
    'aria-label': 'Primary',
  });
  root.append(header, content, footer(), mobile);
  return content;
}

/** footer renders the muted copyright strip (hidden under the mobile bar). */
function footer() {
  return el('footer', { class: 'mt-auto hidden md:block border-t border-ig-border bg-white/40' }, [
    el('div', { class: 'max-w-[1040px] mx-auto px-4 py-8 text-center text-xs text-ig-muted' }, [
      `© ${new Date().getFullYear()} Canagrou — Capture, Create, Share`,
    ]),
  ]);
}
