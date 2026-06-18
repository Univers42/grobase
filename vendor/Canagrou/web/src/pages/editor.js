// editor.js — capture & upload page. Webcam preview with a live overlay
// (composition.liveOverlay), Capture (still) and GIF (multi-frame) buttons, plus
// a file-upload tab. On capture it composes a Blob, uploads it under a random
// key, inserts a posts row, and routes to the gallery. Also shows a "my
// captures" strip. Ports the webcam/overlay flow from public/assets/js/camera.js.

import { baas } from '../lib/baas.js';
import { composition } from '../../../services/index.js';
import { el, clear, toast } from '../lib/dom.js';
import { resolvePostImage } from '../lib/images.js';
import { createOverlayPicker } from '../components/overlay-picker.js';
import { createEditorState } from './editor-state.js';

const GIF_FRAMES = 5;
const GIF_INTERVAL = 400;

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
  const strip = el('div', { class: 'grid grid-cols-2 gap-2 max-h-[70vh] overflow-y-auto pr-1' });
  const buttons = actionButtons(state, { video, uploadImg });
  const picker = createOverlayPicker((url) => (state.overlayUrl = url));

  slot.append(layout({ video, previewCanvas, uploadImg, picker, buttons, strip, state }));
  startCamera(state, video, previewCanvas);
  loadCaptures(strip);
  return () => stopCamera(state);
}

/** layout assembles the two-column editor grid and the input-mode tabs. */
function layout({ video, previewCanvas, uploadImg, picker, buttons, strip, state }) {
  const preview = el('div', { class: 'relative bg-white border border-ig-border rounded-lg overflow-hidden shadow-sm', style: 'aspect-ratio:4/3;' });
  const drop = dropZone(state, uploadImg);
  preview.append(video, uploadImg, previewCanvas, drop);
  const tabs = modeTabs(state, video, drop, uploadImg);
  const main = el('div', { class: 'lg:col-span-2 space-y-5' }, [tabs, preview, picker, buttons]);
  const aside = el('div', { class: 'space-y-4' }, [
    el('h2', { class: 'text-sm font-semibold text-ig-text uppercase tracking-wider' }, ['My Captures']),
    strip,
  ]);
  return el('div', { class: 'max-w-[935px] mx-auto px-4 py-6 md:py-8' }, [
    el('div', { class: 'mb-6' }, [
      el('h1', { class: 'text-2xl font-bold text-ig-text' }, ['Create New Post']),
      el('p', { class: 'text-ig-muted text-sm mt-1' }, ['Capture from your webcam or upload an image, then add an overlay.']),
    ]),
    el('div', { class: 'grid grid-cols-1 lg:grid-cols-3 gap-6' }, [main, aside]),
  ]);
}

/** buildVideo returns the mirrored, autoplaying webcam <video> element. */
function buildVideo() {
  return el('video', {
    autoplay: true,
    playsinline: true,
    muted: true,
    class: 'absolute inset-0 w-full h-full object-cover webcam-mirror',
  });
}

/** modeTabs returns the webcam/upload tab bar toggling the active input mode. */
function modeTabs(state, video, drop, uploadImg) {
  const webcam = tabButton('Webcam', true);
  const upload = tabButton('Upload', false);
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
  return el('div', { class: 'flex bg-white border border-ig-border rounded-lg overflow-hidden' }, [webcam, upload]);
}

/** tabButton/tabClass build a mode tab and its active/inactive styling. */
function tabButton(label, active) {
  return el('button', { type: 'button', class: tabClass(active) }, [label]);
}
function tabClass(active) {
  const base = 'flex-1 py-3 px-4 text-sm font-semibold transition-all border-b-2 ';
  return base + (active ? 'bg-ig-bg text-ig-text border-ig-text' : 'text-ig-muted hover:text-ig-text border-transparent');
}

/** dropZone builds the click/drag upload target wiring file selection. */
function dropZone(state, uploadImg) {
  const input = el('input', { type: 'file', accept: 'image/jpeg,image/png,image/webp', class: 'hidden' });
  const zone = el('div', {
    class: 'absolute inset-0 hidden flex-col items-center justify-center cursor-pointer border-2 border-dashed border-gray-300 hover:border-ig-blue transition-colors m-4 rounded-lg',
  }, [
    el('p', { class: 'text-ig-text text-sm font-medium' }, ['Drag a photo here or click to select']),
    el('p', { class: 'text-ig-muted text-xs mt-1' }, ['JPEG, PNG or WebP — Max 5 MB']),
    input,
  ]);
  zone.addEventListener('click', () => input.click());
  input.addEventListener('change', () => input.files[0] && acceptFile(state, input.files[0], uploadImg, zone));
  wireDrag(state, zone, uploadImg);
  return zone;
}

/** wireDrag adds dragover/drop handlers that accept a dropped image file. */
function wireDrag(state, zone, uploadImg) {
  zone.addEventListener('dragover', (e) => e.preventDefault());
  zone.addEventListener('drop', (e) => {
    e.preventDefault();
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
  };
  reader.readAsDataURL(file);
}

/** actionButtons returns the Capture + GIF buttons wired to the capture flows. */
function actionButtons(state, sources) {
  const capture = el('button', {
    type: 'button',
    class: 'flex-1 bg-ig-blue hover:bg-blue-600 disabled:opacity-50 text-white font-semibold py-3 rounded-lg transition-all text-sm',
  }, ['Capture Photo']);
  const gif = el('button', {
    type: 'button',
    class: 'bg-purple-500 hover:bg-purple-600 disabled:opacity-50 text-white font-semibold py-3 px-5 rounded-lg transition-all text-sm',
  }, ['GIF']);
  capture.addEventListener('click', () => guardBusy(state, () => doCapture(state, sources, capture)));
  gif.addEventListener('click', () => guardBusy(state, () => doGif(state, sources, capture)));
  return el('div', { class: 'flex gap-3' }, [capture, gif]);
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

/** doCapture composes a still (webcam frame or uploaded image) and publishes it. */
async function doCapture(state, sources, capture) {
  if (!state.overlayUrl) {
    toast('Select an overlay first', 'info');
    return;
  }
  capture.textContent = 'Processing…';
  try {
    const isWebcam = state.mode === 'webcam';
    const source = isWebcam ? sources.video : sources.uploadImg;
    if (isWebcam && !state.stream) throw new Error('Webcam is not available');
    if (!isWebcam && !state.uploadFile) throw new Error('Upload an image first');
    const blob = await composition.composePhoto({ source, overlayUrl: state.overlayUrl, mirror: isWebcam });
    await publish(blob, 'png');
  } catch (err) {
    toast(err && err.message ? err.message : 'Capture failed', 'error');
    capture.textContent = 'Capture Photo';
  }
}

/** doGif grabs N webcam frames at intervals, encodes a GIF, and publishes it. */
async function doGif(state, sources, capture) {
  if (!state.overlayUrl) {
    toast('Select an overlay first', 'info');
    return;
  }
  if (state.mode !== 'webcam' || !state.stream) {
    toast('GIF capture requires an active webcam', 'error');
    return;
  }
  capture.textContent = 'Recording…';
  try {
    const frames = await grabFrames(sources.video);
    const blob = await composition.composeGif({ frames, overlayUrl: state.overlayUrl, mirror: true, delayMs: GIF_INTERVAL });
    await publish(blob, 'gif');
  } catch (err) {
    toast(err && err.message ? err.message : 'GIF capture failed', 'error');
    capture.textContent = 'Capture Photo';
  }
}

/** grabFrames snapshots the webcam into N canvases spaced by GIF_INTERVAL. */
async function grabFrames(video) {
  const frames = [];
  for (let i = 0; i < GIF_FRAMES; i++) {
    frames.push(snapshot(video));
    if (i < GIF_FRAMES - 1) await wait(GIF_INTERVAL);
  }
  return frames;
}

/** snapshot copies the current video frame into a canvas at native resolution. */
function snapshot(video) {
  const canvas = el('canvas');
  canvas.width = video.videoWidth || 640;
  canvas.height = video.videoHeight || 480;
  canvas.getContext('2d').drawImage(video, 0, 0, canvas.width, canvas.height);
  return canvas;
}

/** wait resolves after `ms` milliseconds (frame pacing for GIF capture). */
function wait(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/** publish uploads the composed blob, inserts a post row, and routes home. */
async function publish(blob, ext) {
  const user = baas.auth.currentUser();
  const key = `${crypto.randomUUID()}.${ext}`;
  await baas.storage.upload(key, blob, ext === 'gif' ? 'image/gif' : 'image/png');
  await baas.db.insert('posts', { user_id: user.id, image_key: key });
  toast('Posted!', 'success');
  window.canagrouNavigate('/');
}

/** startCamera requests the webcam and starts the live overlay loop. */
async function startCamera(state, video, previewCanvas) {
  try {
    state.stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 1280 }, height: { ideal: 960 }, facingMode: 'user' },
      audio: false,
    });
    video.srcObject = state.stream;
    await video.play();
    state.stopOverlay = composition.liveOverlay({
      canvas: previewCanvas,
      video,
      overlayImg: null,
      mirror: true,
    });
    pollOverlay(state, previewCanvas, video);
  } catch (err) {
    toast('Webcam unavailable — use the Upload tab', 'info');
    console.warn('[editor] webcam', err && err.message);
  }
}

/** pollOverlay rebinds the live loop whenever the chosen overlay changes. */
function pollOverlay(state, previewCanvas, video) {
  let current = null;
  const tick = () => {
    if (!state.stream) return;
    if (state.overlayUrl !== current) {
      current = state.overlayUrl;
      rebindOverlay(state, previewCanvas, video, current);
    }
    state.overlayTimer = setTimeout(tick, 300);
  };
  tick();
}

/** rebindOverlay loads the new overlay image and restarts the live loop. */
function rebindOverlay(state, previewCanvas, video, url) {
  if (state.stopOverlay) state.stopOverlay();
  const img = new Image();
  img.crossOrigin = 'anonymous';
  img.onload = () => {
    state.stopOverlay = composition.liveOverlay({ canvas: previewCanvas, video, overlayImg: img, mirror: true });
  };
  if (url) img.src = url;
  else state.stopOverlay = composition.liveOverlay({ canvas: previewCanvas, video, overlayImg: null, mirror: true });
}

/** stopCamera tears down the stream, overlay loop, and overlay-poll timer. */
function stopCamera(state) {
  if (state.stopOverlay) state.stopOverlay();
  if (state.overlayTimer) clearTimeout(state.overlayTimer);
  if (state.stream) {
    for (const track of state.stream.getTracks()) track.stop();
    state.stream = null;
  }
}

/** loadCaptures lists the current user's own posts into the captures strip. */
async function loadCaptures(strip) {
  try {
    const user = baas.auth.currentUser();
    const posts = await baas.db.list('posts', { where: { user_id: user.id }, sort: { created_at: 'desc' }, limit: 30 });
    clear(strip);
    if (!posts.length) {
      strip.append(el('p', { class: 'col-span-2 text-ig-muted text-sm text-center py-8' }, ['No captures yet.']));
      return;
    }
    for (const post of posts) strip.append(captureThumb(post));
  } catch (err) {
    console.warn('[editor] captures', err && err.message);
  }
}

/** captureThumb renders one of the user's own posts as a square thumbnail. */
function captureThumb(post) {
  const img = el('img', { class: 'w-full aspect-square object-cover', loading: 'lazy', alt: `Capture ${post.id}` });
  resolvePostImage(img, post.image_key);
  return el('div', { class: 'rounded-lg overflow-hidden bg-white border border-ig-border' }, [img]);
}
