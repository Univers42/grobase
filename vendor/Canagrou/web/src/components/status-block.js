// status-block.js — a small spinner→outcome panel for the verify / reset-password
// landing pages. Starts as a centered spinner with a message and an onward link;
// setStatus() swaps the spinner for a success/error icon and recolours the text.
// Pure presentation; no baas import.

import { el, spinner, iconSvg } from '../lib/dom.js';

const GLYPH = {
  success: '<path stroke-linecap="round" stroke-linejoin="round" d="M9 12.75L11.25 15 15 9.75M21 12a9 9 0 11-18 0 9 9 0 0118 0z"/>',
  error: '<path stroke-linecap="round" stroke-linejoin="round" d="M12 9v3.75m9-.75a9 9 0 11-18 0 9 9 0 0118 0zm-9 3.75h.008v.008H12v-.008z"/>',
};

/**
 * statusBlock builds the verifying panel and returns { element, icon, text }
 * so the caller can update it once the async outcome is known.
 * @param message  the initial (verifying) message
 * @param href     the onward SPA link href
 * @param linkText the onward link label
 */
export function statusBlock(message, href, linkText) {
  const iconHost = el('div', { class: 'flex justify-center mb-4 text-purple-600' }, [spinner()]);
  const text = el('p', { class: 'text-ig-muted text-sm' }, [message]);
  const link = el('a', { href, 'data-link': true, class: 'btn btn-secondary mt-5 inline-flex px-5 py-2 text-sm' }, [linkText]);
  const element = el('div', { class: 'text-center' }, [iconHost, text, el('div', {}, [link])]);
  return { element, iconHost, text };
}

/** setStatus swaps the spinner for an outcome icon and recolours the message. */
export function setStatus(block, message, kind) {
  block.iconHost.replaceChildren(iconSvg(GLYPH[kind] || GLYPH.success, `w-12 h-12 ${kind === 'error' ? 'text-ig-red' : 'text-emerald-500'}`));
  block.text.className = `text-sm font-medium ${kind === 'error' ? 'text-ig-red' : 'text-ig-text'}`;
  block.text.textContent = message;
}
