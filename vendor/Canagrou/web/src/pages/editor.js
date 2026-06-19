// editor.js — capture & upload page. A polished two-pane creator: live webcam
// preview with the chosen overlay, webcam/upload tabs, an overlay picker, a
// drop-zone, prominent Capture/GIF actions with progress feedback, and a "My
// Captures" strip. The imperative camera/capture/publish logic lives in
// editor-capture.js. "Create New Post" + "Capture Photo" are test contract.

import { baas } from '../lib/baas.js';
import { el, clear, toast, setButtonLoading } from '../lib/dom.js';
import { resolvePostImage } from '../lib/images.js';
import { createOverlayPicker } from '../components/overlay-picker.js';
import { icon } from '../components/icons.js';
import { createEditorState } from './editor-state.js';
import { doCapture, doGif, startCamera, stopCamera } from './editor-capture.js';

/**
 * render mounts the editor: preview area + tabs, overlay picker, action buttons,
 * and the captures strip. The default export the router calls (route is guarded,
 * so the user is authenticated here). Returns a cleanup that stops the camera.
 * @param slot the content container provided by the router
 * @returns cleanup function stopping the webcam + overlay loop
 */
export default async function render(slot) {
  const state = createEditorState();
  const video = buildVideo();
  const previewCanvas = el('canvas', { class: 'absolute inset-0 w-full h-full pointer-events-none z-10' });
  const uploadImg = el('img', { alt: 'Upload preview', class: 'w-full h-full object-contain hidden' });
  const strip = el('div', { class: 'grid grid-cols-2 gap-2.5 max-h-[70vh] overflow-y-auto pr-1' });
  const denied = deniedBanner();
  const buttons = actionButtons(state, { video, uploadImg });
  const picker = createOverlayPicker((url) => (state.overlayUrl = url));

  slot.append(layout({ video, previewCanvas, uploadImg, picker, buttons, strip, state, denied }));
  startCamera(state, video, previewCanvas, () => showDenied(denied));
  loadCaptures(strip);
  return () => stopCamera(state);
}

/** layout assembles the two-column editor grid and the input-mode tabs. */
function layout({ video, previewCanvas, uploadImg, picker, buttons, strip, state, denied }) {
  const preview = el('div', { class: 'relative card overflow-hidden', style: 'aspect-ratio:4/3;' });
  const drop = dropZone(state, uploadImg);
  preview.append(video, uploadImg, previewCanvas, drop);
  const tabs = modeTabs(state, video, drop, uploadImg);
  const main = el('div', { class: 'lg:col-span-2 space-y-4' }, [tabs, denied, preview, picker, buttons]);
  const aside = el('div', { class: 'space-y-3' }, [
    el('h2', { class: 'text-xs font-bold text-ig-text uppercase tracking-wider' }, ['My Captures']),
    strip,
  ]);
  return el('div', { class: 'max-w-[1040px] mx-auto px-4 py-6 md:py-10' }, [
    el('div', { class: 'mb-6' }, [
      el('h1', { class: 'text-2xl font-extrabold text-ig-text tracking-tight' }, ['Create New Post']),
      el('p', { class: 'text-ig-muted text-sm mt-1' }, ['Capture from your webcam or upload an image, then add an overlay.']),
    ]),
    el('div', { class: 'grid grid-cols-1 lg:grid-cols-3 gap-6' }, [main, aside]),
  ]);
}

/** buildVideo returns the mirrored, autoplaying webcam <video> element. */
function buildVideo() {
  return el('video', { autoplay: true, playsinline: true, muted: true, class: 'absolute inset-0 w-full h-full object-cover webcam-mirror' });
}

/** deniedBanner builds the hidden webcam-permission notice (shown on denial). */
function deniedBanner() {
  return el('div', { class: 'alert alert-error hidden', role: 'alert' }, [
    icon('camera', 'alert-icon'),
    el('span', {}, ['Webcam unavailable or blocked. Switch to the ', el('b', {}, ['Upload']), ' tab to add an image instead.']),
  ]);
}

/** showDenied reveals the webcam-denied banner and switches focus to upload. */
function showDenied(denied) {
  denied.classList.remove('hidden');
}

/** modeTabs returns the webcam/upload tab bar toggling the active input mode. */
function modeTabs(state, video, drop, uploadImg) {
  const webcam = tabButton('Webcam', 'camera', true, 'webcam-tab');
  const upload = tabButton('Upload', 'upload', false, 'upload-tab');
  const set = (mode) => {
    state.mode = mode;
    const on = mode === 'webcam';
    webcam.className = tabClass(on);
    upload.className = tabClass(!on);
    video.classList.toggle('hidden', !on);
    drop.classList.toggle('hidden', on || Boolean(state.uploadFile));
    uploadImg.classList.toggle('hidden', on || !state.uploadFile);
  };
  webcam.addEventListener('click', () => set('webcam'));
  upload.addEventListener('click', () => set('upload'));
  return el('div', { class: 'flex card overflow-hidden p-1 gap-1' }, [webcam, upload]);
}

/** tabButton/tabClass build a mode tab and its active/inactive styling. */
function tabButton(label, glyph, active, testid) {
  return el('button', { type: 'button', class: tabClass(active), dataset: { testid } }, [icon(glyph, 'w-4 h-4'), label]);
}
function tabClass(active) {
  const base = 'flex-1 inline-flex items-center justify-center gap-2 py-2.5 px-4 text-sm font-semibold rounded-lg transition-all ';
  return base + (active ? 'bg-gradient-to-r from-purple-600 to-pink-500 text-white shadow' : 'text-ig-muted hover:text-ig-text hover:bg-ig-bg');
}

/** dropZone builds the click/drag upload target wiring file selection. */
function dropZone(state, uploadImg) {
  const input = el('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', class: 'hidden', dataset: { testid: 'file-input' } });
  const zone = el('div', {
    class: 'absolute inset-0 hidden flex-col items-center justify-center cursor-pointer border-2 border-dashed border-ig-border hover:border-purple-500 hover:bg-purple-50/40 transition-colors m-4 rounded-xl text-center',
  }, [
    el('div', { class: 'text-purple-400 mb-2' }, [icon('upload', 'w-10 h-10')]),
    el('p', { class: 'text-ig-text text-sm font-semibold' }, ['Drag a photo here or click to browse']),
    el('p', { class: 'text-ig-muted text-xs mt-1' }, ['JPEG, PNG or WebP — max 5 MB']),
    input,
  ]);
  zone.addEventListener('click', () => input.click());
  input.addEventListener('change', () => input.files[0] && acceptFile(state, input.files[0], uploadImg, zone));
  wireDrag(state, zone, uploadImg);
  return zone;
}

/** wireDrag adds dragover/drop handlers that accept a dropped image file. */
function wireDrag(state, zone, uploadImg) {
  zone.addEventListener('dragover', (e) => {
    e.preventDefault();
    zone.classList.add('border-purple-500', 'bg-purple-50/40');
  });
  zone.addEventListener('dragleave', () => zone.classList.remove('bg-purple-50/40'));
  zone.addEventListener('drop', (e) => {
    e.preventDefault();
    zone.classList.remove('bg-purple-50/40');
    const file = e.dataTransfer.files[0];
    if (file) acceptFile(state, file, uploadImg, zone);
  });
}

/** acceptFile validates an image, previews it, and stores it on the state. */
function acceptFile(state, file, uploadImg, zone) {
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) {
    toast('Only JPEG, PNG or WebP images are accepted', 'error');
    return;
  }
  if (file.size > 5 * 1024 * 1024) {
    toast('Image must be smaller than 5 MB', 'error');
    return;
  }
  state.uploadFile = file;
  const reader = new FileReader();
  reader.onload = (e) => {
    uploadImg.src = e.target.result;
    uploadImg.classList.remove('hidden');
    zone.classList.add('hidden');
    toast('Image ready — pick an overlay and capture', 'success');
  };
  reader.readAsDataURL(file);
}

/** actionButtons returns the Capture + GIF buttons wired to the capture flows. */
function actionButtons(state, sources) {
  const capture = el('button', { type: 'button', class: 'btn btn-primary flex-1 py-3 text-sm', dataset: { testid: 'capture-btn' } }, [icon('camera', 'w-5 h-5'), 'Capture Photo']);
  const gif = el('button', { type: 'button', class: 'btn btn-secondary py-3 px-5 text-sm', dataset: { testid: 'gif-btn' } }, [icon('sparkle', 'w-5 h-5'), 'GIF']);
  const onStatus = (label) => updateActionState(capture, gif, label);
  capture.addEventListener('click', () => guardBusy(state, () => doCapture({ state, video: sources.video, uploadImg: sources.uploadImg, capture, onStatus })));
  gif.addEventListener('click', () => guardBusy(state, () => doGif({ state, video: sources.video, capture, onStatus })));
  return el('div', { class: 'flex gap-3' }, [capture, gif]);
}

/** updateActionState shows progress on the capture button (null = restore idle). */
function updateActionState(capture, gif, label) {
  gif.disabled = Boolean(label);
  if (label) {
    setButtonLoading(capture, true, label);
  } else {
    setButtonLoading(capture, false);
  }
}

/** guardBusy serializes capture actions so two clicks can't overlap. */
async function guardBusy(state, fn) {
  if (state.busy) return;
  state.busy = true;
  try {
    await fn();
  } finally {
    state.busy = false;
  }
}

/** loadCaptures lists the current user's own posts into the captures strip. */
async function loadCaptures(strip) {
  try {
    const user = baas.auth.currentUser();
    const posts = await baas.db.list('posts', { where: { user_id: user.id }, sort: { created_at: 'desc' }, limit: 30 });
    clear(strip);
    if (!posts.length) {
      strip.append(el('p', { class: 'col-span-2 text-ig-muted text-sm text-center py-8' }, ['No captures yet — your posts show up here.']));
      return;
    }
    for (const post of posts) strip.append(captureThumb(post));
  } catch (err) {
    console.warn('[editor] captures', err && err.message);
  }
}

/** captureThumb renders one of the user's own posts as a rounded thumbnail. */
function captureThumb(post) {
  const img = el('img', { class: 'media-fade w-full aspect-square object-cover', loading: 'lazy', alt: `Capture ${post.id}` });
  img.addEventListener('load', () => img.classList.add('loaded'));
  resolvePostImage(img, post.image_key);
  return el('div', { class: 'card card-hover overflow-hidden' }, [img]);
}
