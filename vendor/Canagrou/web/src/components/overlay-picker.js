// overlay-picker.js — a grid of the seven overlay thumbnails. Selecting one
// highlights it (selected state + check badge) and calls onSelect with its
// public URL so the editor can swap the live-preview / capture overlay. Pure
// presentation; no baas import. The `.overlay-thumb` class is test contract.

import { el } from '../lib/dom.js';
import { icon } from './icons.js';

const OVERLAYS = [
  { id: 'film-frame', name: 'Film Frame' },
  { id: 'halftone', name: 'Halftone' },
  { id: 'heart-vignette', name: 'Heart Vignette' },
  { id: 'neon-glow', name: 'Neon Glow' },
  { id: 'pixel-border', name: 'Pixel Border' },
  { id: 'retro-border', name: 'Retro Border' },
  { id: 'sparkles', name: 'Sparkles' },
];

/**
 * createOverlayPicker builds the overlay grid. onSelect receives the chosen
 * overlay's URL (e.g. "/overlays/sparkles.png"). Returns the container element.
 * @param onSelect callback invoked with the selected overlay URL
 */
export function createOverlayPicker(onSelect) {
  const grid = el('div', { id: 'overlay-list', class: 'grid grid-cols-4 sm:grid-cols-7 gap-2.5' });
  for (const overlay of OVERLAYS) grid.append(overlayThumb(overlay, grid, onSelect));
  return el('div', { class: 'card p-4' }, [
    el('div', { class: 'flex items-center gap-2 mb-3 text-ig-text' }, [
      el('span', { class: 'text-purple-500' }, [icon('sparkle', 'w-4 h-4')]),
      el('h2', { class: 'text-xs font-bold uppercase tracking-wider' }, ['Choose an overlay']),
    ]),
    grid,
  ]);
}

/** overlayThumb builds one selectable thumbnail button for an overlay. */
function overlayThumb(overlay, grid, onSelect) {
  const url = `/overlays/${overlay.id}.png`;
  const img = el('img', { src: url, alt: overlay.name, class: 'w-full h-full object-contain', loading: 'lazy' });
  const btn = el('button', {
    type: 'button',
    class: 'overlay-thumb group aspect-square bg-ig-bg p-2 flex items-center justify-center',
    title: overlay.name,
    'aria-label': `Overlay: ${overlay.name}`,
    dataset: { overlayId: overlay.id, testid: 'overlay-thumb' },
  }, [img]);
  btn.addEventListener('click', () => selectOverlay(btn, grid, url, onSelect));
  return btn;
}

/** selectOverlay clears prior selection, marks this one, and notifies onSelect. */
function selectOverlay(btn, grid, url, onSelect) {
  for (const sel of grid.querySelectorAll('.overlay-thumb.selected')) {
    sel.classList.remove('selected');
    sel.setAttribute('aria-pressed', 'false');
  }
  btn.classList.add('selected');
  btn.setAttribute('aria-pressed', 'true');
  onSelect(url);
}
