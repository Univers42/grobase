// auth-form.js — shared building blocks for the auth pages (login/register/
// forgot/reset): the centered premium card with the brand mark, labelled inputs
// with per-field validation hints, the gradient submit button, and inline
// alert rendering (error + success). Keeps each page module small.

import { el } from '../lib/dom.js';
import { icon } from './icons.js';

/**
 * authCard wraps a form's contents in the centered card used by every auth
 * page, with the gradient Canagrou wordmark and an optional subtitle.
 * @param children the card body nodes (form, links, etc.)
 * @param subtitle optional muted line under the wordmark
 */
export function authCard(children, subtitle) {
  const head = [
    el('div', { class: 'flex items-center justify-center gap-2 mb-1' }, [
      el('span', { class: 'text-purple-600' }, [icon('sparkle', 'w-7 h-7')]),
      el('h1', { class: 'text-3xl font-extrabold tracking-tight brand-text' }, ['Canagrou']),
    ]),
  ];
  if (subtitle) head.push(el('p', { class: 'text-ig-muted text-sm mt-2' }, [subtitle]));
  const card = el('div', { class: 'card px-8 pt-9 pb-7 shadow-lg' }, [
    el('div', { class: 'text-center mb-6' }, head),
    ...children,
  ]);
  return el('div', { class: 'flex items-center justify-center min-h-[82vh] py-10 px-4' }, [
    el('div', { class: 'w-full max-w-[380px] space-y-3' }, [card]),
  ]);
}

/**
 * field returns a styled input wrapped with a hint slot for inline validation.
 * Returns { wrap, input, hint } so the page can read the value and set hints.
 * @param props input attributes (type, name, placeholder, required, …)
 * @param label optional visible label above the input
 */
export function field(props, label) {
  const input = el('input', { class: 'input', ...props });
  const hint = el('p', { class: 'field-hint' });
  const parts = [];
  if (label) parts.push(el('label', { class: 'block text-xs font-semibold text-ig-text mb-1.5' }, [label]));
  parts.push(input, hint);
  const wrap = el('div', {}, parts);
  return { wrap, input, hint };
}

/** setHint writes an inline validation hint under a field (kind: 'error'|'ok'|''). */
export function setHint(ref, message, kind = 'error') {
  ref.hint.className = `field-hint ${kind}`;
  ref.hint.textContent = message || '';
  ref.input.classList.toggle('invalid', kind === 'error' && Boolean(message));
  ref.input.classList.toggle('valid', kind === 'ok' && Boolean(message));
}

/** submitButton returns the primary gradient submit button with the given label. */
export function submitButton(label) {
  return el('button', { type: 'submit', class: 'btn btn-primary w-full py-2.5 text-sm mt-2', dataset: { testid: 'auth-submit' } }, [label]);
}

const ALERT_ICON = {
  error: 'M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z',
  success: 'M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z',
};

/**
 * showError renders (or replaces) an inline alert at the top of a form.
 * @param form    the form element to prepend the box to
 * @param message the message text (rendered as text, not markup)
 * @param kind    'error' (default) or 'success'
 */
export function showError(form, message, kind = 'error') {
  form.querySelector('.alert')?.remove();
  const glyph = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
  glyph.setAttribute('class', 'alert-icon');
  glyph.setAttribute('viewBox', '0 0 24 24');
  glyph.setAttribute('fill', 'none');
  glyph.setAttribute('stroke', 'currentColor');
  glyph.setAttribute('stroke-width', '1.8');
  glyph.innerHTML = `<path stroke-linecap="round" stroke-linejoin="round" d="${ALERT_ICON[kind] || ALERT_ICON.error}"/>`;
  const box = el('div', {
    class: `alert alert-${kind} mb-4`,
    dataset: { testid: 'auth-error' },
    role: 'alert',
    'aria-live': 'assertive',
  }, [glyph, el('span', { text: message })]);
  form.prepend(box);
}

/** clearAlert removes any inline alert from a form. */
export function clearAlert(form) {
  form.querySelector('.alert')?.remove();
}

/** linkRow returns a centered prompt + SPA link line under the card. */
export function linkRow(prompt, href, linkText, testid) {
  const link = el('a', { href, 'data-link': true, class: 'text-purple-600 font-semibold hover:text-purple-700 transition-colors', dataset: { testid } }, [linkText]);
  return el('div', { class: 'card px-8 py-4 text-center' }, [
    el('p', { class: 'text-sm text-ig-text' }, [`${prompt} `, link]),
  ]);
}
