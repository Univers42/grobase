// editor-capture.js — the imperative side of the editor: webcam lifecycle, the
// live overlay loop, still + GIF capture, and publishing (upload → posts row).
// Keeps editor.js focused on layout/wiring. Every action reports progress through
// the passed status callback and surfaces failures via toast.

import { baas } from '../lib/baas.js';
import { ensureProfile } from '../lib/profiles.js';
import { composition } from '../../../services/index.js';
import { el, toast } from '../lib/dom.js';

const GIF_FRAMES = 5;
const GIF_INTERVAL = 400;

/**
 * doCapture composes a still (webcam frame or uploaded image) and publishes it.
 * @param ctx { state, video, uploadImg, capture, onStatus }
 */
export async function doCapture(ctx) {
  if (!ctx.state.overlayUrl) {
    toast('Pick an overlay first', 'info');
    return;
  }
  ctx.onStatus('Processing…');
  try {
    const isWebcam = ctx.state.mode === 'webcam';
    const source = isWebcam ? ctx.video : ctx.uploadImg;
    if (isWebcam && !ctx.state.stream) throw new Error('Webcam is not available — use the Upload tab');
    if (!isWebcam && !ctx.state.uploadFile) throw new Error('Upload an image first');
    const blob = await composition.composePhoto({ source, overlayUrl: ctx.state.overlayUrl, mirror: isWebcam });
    await publish(blob, 'png', ctx);
  } catch (err) {
    ctx.onStatus(null);
    toast(err && err.message ? err.message : 'Capture failed', 'error');
  }
}

/**
 * doGif grabs N webcam frames at intervals, encodes a GIF, and publishes it.
 * @param ctx { state, video, capture, onStatus }
 */
export async function doGif(ctx) {
  if (!ctx.state.overlayUrl) {
    toast('Pick an overlay first', 'info');
    return;
  }
  if (ctx.state.mode !== 'webcam' || !ctx.state.stream) {
    toast('GIF capture needs an active webcam', 'error');
    return;
  }
  try {
    const frames = await grabFrames(ctx.video, ctx.onStatus);
    ctx.onStatus('Encoding GIF…');
    const blob = await composition.composeGif({ frames, overlayUrl: ctx.state.overlayUrl, mirror: true, delayMs: GIF_INTERVAL });
    await publish(blob, 'gif', ctx);
  } catch (err) {
    ctx.onStatus(null);
    toast(err && err.message ? err.message : 'GIF capture failed', 'error');
  }
}

/** grabFrames snapshots the webcam into N canvases, reporting "Recording (n/5)". */
async function grabFrames(video, onStatus) {
  const frames = [];
  for (let i = 0; i < GIF_FRAMES; i++) {
    onStatus(`Recording… (${i + 1}/${GIF_FRAMES})`);
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

/** publish uploads the composed blob, inserts a post row, and routes home.
 * ensureProfile first so the posts.user_id → profiles.id FK is always satisfied
 * (repairs accounts created before a profile row existed). */
async function publish(blob, ext, ctx) {
  ctx.onStatus('Uploading…');
  const profile = await ensureProfile();
  const user = baas.auth.currentUser();
  if (!profile || !user) throw new Error('Please log in again to post');
  const key = `${crypto.randomUUID()}.${ext}`;
  await baas.storage.upload(key, blob, ext === 'gif' ? 'image/gif' : 'image/png');
  await baas.db.insert('posts', { user_id: user.id, image_key: key });
  ctx.onStatus('Posted!');
  toast('Posted to your feed! 🎉', 'success');
  setTimeout(() => window.canagrouNavigate('/'), 350);
}

/** startCamera requests the webcam and starts the live overlay loop. */
export async function startCamera(state, video, previewCanvas, onDenied) {
  try {
    state.stream = await navigator.mediaDevices.getUserMedia({
      video: { width: { ideal: 1280 }, height: { ideal: 960 }, facingMode: 'user' },
      audio: false,
    });
    video.srcObject = state.stream;
    await video.play();
    state.stopOverlay = composition.liveOverlay({ canvas: previewCanvas, video, overlayImg: null, mirror: true });
    pollOverlay(state, previewCanvas, video);
  } catch (err) {
    if (onDenied) onDenied(err);
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
export function stopCamera(state) {
  if (state.stopOverlay) state.stopOverlay();
  if (state.overlayTimer) clearTimeout(state.overlayTimer);
  if (state.stream) {
    for (const track of state.stream.getTracks()) track.stop();
    state.stream = null;
  }
}
