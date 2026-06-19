// user-menu.js — the authed avatar dropdown in the top nav: shows the user's
// initials avatar and, on click, a popover with Create / Settings / Log out.
// Closes on outside-click or Escape. Calls baas.auth.signOut on log out.

import { baas } from '../lib/baas.js';
import { el, toast, setButtonLoading } from '../lib/dom.js';
import { authorName } from '../lib/profiles.js';
import { avatar, icon } from './icons.js';

/**
 * createUserMenu builds the avatar + dropdown for a signed-in user. Returns the
 * trigger element (the popover is appended to it and toggled in place).
 */
export function createUserMenu() {
  const user = baas.auth.currentUser();
  const name = (user && authorName(user.id)) || (user && user.email) || 'You';
  const trigger = el('button', {
    class: 'relative flex items-center rounded-full transition-transform hover:scale-105',
    'aria-haspopup': 'true',
    'aria-expanded': 'false',
    'aria-label': 'Account menu',
  }, [avatar(name, 'w-9 h-9')]);
  const pop = popover(name, user);
  pop.classList.add('hidden');
  trigger.append(pop);
  wireToggle(trigger, pop);
  return trigger;
}

/** popover builds the dropdown panel listing the account actions. */
function popover(name, user) {
  return el('div', {
    class: 'menu-pop absolute right-0 top-12 w-56 card p-1.5 z-50 text-left',
    role: 'menu',
  }, [
    el('div', { class: 'px-3 py-2 border-b border-ig-border mb-1' }, [
      el('p', { class: 'text-sm font-semibold text-ig-text truncate' }, [name]),
      el('p', { class: 'text-xs text-ig-muted truncate' }, [(user && user.email) || '']),
    ]),
    menuItem('home', 'My profile', () => window.canagrouNavigate(`/profile/${user && user.id ? user.id : ''}`), 'nav-profile'),
    menuItem('plus', 'Create', () => window.canagrouNavigate('/editor'), 'nav-create-menu'),
    menuItem('settings', 'Settings', () => window.canagrouNavigate('/settings'), 'nav-settings'),
    logoutItem(),
  ]);
}

/** menuItem builds one dropdown row (icon + label) running an action on click. */
function menuItem(name, label, onClick, testid) {
  return el('button', {
    class: 'w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium text-ig-text hover:bg-ig-bg transition-colors',
    role: 'menuitem',
    dataset: { testid },
    onClick,
  }, [icon(name, 'w-[18px] h-[18px] text-ig-muted'), label]);
}

/** logoutItem builds the destructive log-out row with its loading + sign-out. */
function logoutItem() {
  const btn = el('button', {
    class: 'w-full flex items-center gap-3 px-3 py-2 rounded-lg text-sm font-medium text-ig-red hover:bg-red-50 transition-colors',
    role: 'menuitem',
    dataset: { testid: 'nav-logout' },
  }, [icon('logout', 'w-[18px] h-[18px]'), 'Log out']);
  btn.addEventListener('click', () => onLogout(btn));
  return btn;
}

/** onLogout signs out with feedback then routes home. */
async function onLogout(btn) {
  setButtonLoading(btn, true, 'Signing out…');
  try {
    await baas.auth.signOut();
    toast('Signed out', 'success');
  } catch (err) {
    console.warn('[user-menu] signOut error', err && err.message);
  }
  window.canagrouNavigate('/');
}

/** wireToggle opens/closes the popover and installs outside-click/Escape close. */
function wireToggle(trigger, pop) {
  const close = () => {
    pop.classList.add('hidden');
    trigger.setAttribute('aria-expanded', 'false');
    document.removeEventListener('keydown', onKey);
    document.removeEventListener('click', onOutside);
  };
  const onKey = (e) => e.key === 'Escape' && close();
  const onOutside = (e) => !trigger.contains(e.target) && close();
  trigger.addEventListener('click', (e) => {
    e.stopPropagation();
    if (pop.classList.contains('hidden')) openMenu(trigger, pop, onKey, onOutside);
    else close();
  });
}

/** openMenu reveals the popover and arms the outside-close listeners. */
function openMenu(trigger, pop, onKey, onOutside) {
  pop.classList.remove('hidden');
  trigger.setAttribute('aria-expanded', 'true');
  setTimeout(() => {
    document.addEventListener('keydown', onKey);
    document.addEventListener('click', onOutside);
  }, 0);
}
