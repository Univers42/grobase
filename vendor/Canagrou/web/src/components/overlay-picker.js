// overlay-picker.js — a grid of the seven overlay thumbnails. Selecting one
// highlights it and calls onSelect with its public URL so the editor can swap
// the live-preview / capture overlay. Pure presentation; no baas import.

import { el } from '../lib/dom.js';

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
  const grid = el('div', {
    id: 'overlay-list',
    class: 'grid grid-cols-3 sm:grid-cols-5 md:grid-cols-6 lg:grid-cols-7 gap-2',
  });
  for (const overlay of OVERLAYS) grid.append(overlayThumb(overlay, grid, onSelect));
  return el('div', { class: 'bg-white border border-ig-border rounded-lg p-4' }, [
    el('h2', { class: 'text-sm font-semibold text-ig-text uppercase tracking-wider mb-3' }, ['Choose an Overlay']),
    grid,
  ]);
}

/** overlayThumb builds one selectable thumbnail button for an overlay. */
function overlayThumb(overlay, grid, onSelect) {
  const url = `/overlays/${overlay.id}.png`;
  const img = el('img', {
    src: url,
    alt: overlay.name,
    class: 'w-full h-full object-contain',
    loading: 'lazy',
  });
  const btn = el(
    'button',
    {
      type: 'button',
      class: 'overlay-thumb group relative aspect-square bg-ig-bg rounded-lg p-2 flex items-center justify-center hover:bg-gray-100',
      title: overlay.name,
      dataset: { overlayId: overlay.id },
    },
    [img],
  );
  btn.addEventListener('click', () => selectOverlay(btn, grid, url, onSelect));
  return btn;
}

/** selectOverlay clears prior selection, marks this one, and notifies onSelect. */
function selectOverlay(btn, grid, url, onSelect) {
  for (const sel of grid.querySelectorAll('.overlay-thumb.selected')) sel.classList.remove('selected');
  btn.classList.add('selected');
  onSelect(url);
}
