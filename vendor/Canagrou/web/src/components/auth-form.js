// auth-form.js — shared building blocks for the auth pages (login/register/
// forgot/reset). Builds the Instagram-style card, labelled inputs, the submit
// button, and inline error rendering so each page module stays small.

import { el } from '../lib/dom.js';

/**
 * authCard wraps a form's contents in the centered white card used by every
 * auth page, with the Canagrou wordmark on top.
 * @param children the card body nodes (form, links, etc.)
 * @param subtitle optional muted line under the wordmark
 */
export function authCard(children, subtitle) {
  const head = [el('h1', { class: 'text-4xl font-extrabold text-ig-text tracking-tight' }, ['Canagrou'])];
  if (subtitle) head.push(el('p', { class: 'text-ig-muted text-sm mt-3' }, [subtitle]));
  const card = el('div', { class: 'bg-white border border-ig-border rounded-sm px-10 pt-10 pb-6 mb-2.5' }, [
    el('div', { class: 'text-center mb-6' }, head),
    ...children,
  ]);
  return el('div', { class: 'flex items-center justify-center min-h-[80vh] py-8 px-4' }, [
    el('div', { class: 'w-full max-w-[350px]' }, [card]),
  ]);
}

/**
 * field returns a styled input element. Caller keeps the reference to read its
 * value on submit.
 * @param props input attributes (type, name, placeholder, required, …)
 */
export function field(props) {
  return el('input', {
    class: 'w-full px-3 py-[9px] mb-2 rounded-[3px] bg-ig-bg border border-ig-border text-ig-text text-xs placeholder-ig-muted focus:outline-none focus:border-gray-400 transition-colors',
    ...props,
  });
}

/** submitButton returns the primary blue submit button with the given label. */
export function submitButton(label) {
  return el('button', {
    type: 'submit',
    class: 'w-full py-[7px] rounded-lg font-semibold text-sm text-white bg-ig-blue hover:bg-blue-600 disabled:opacity-50 transition-colors mt-3',
  }, [label]);
}

/**
 * showError renders (or replaces) an inline red error box at the top of a form.
 * @param form    the form element to prepend the box to
 * @param message the error text (rendered as text, not markup)
 */
export function showError(form, message) {
  const existing = form.querySelector('.auth-error');
  if (existing) existing.remove();
  const box = el('div', {
    class: 'auth-error bg-red-50 border border-red-200 text-ig-red px-4 py-3 rounded-lg text-sm mb-4',
    text: message,
  });
  form.prepend(box);
}

/** linkRow returns a centered prompt + SPA link line under the card. */
export function linkRow(prompt, href, linkText) {
  const link = el('a', { href, 'data-link': true, class: 'text-ig-blue font-semibold hover:text-blue-700' }, [linkText]);
  return el('div', { class: 'bg-white border border-ig-border rounded-sm px-10 py-5 text-center' }, [
    el('p', { class: 'text-sm text-ig-text' }, [`${prompt} `, link]),
  ]);
}
