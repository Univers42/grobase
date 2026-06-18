// composition/index.js — the public photo-composition API the editor calls.
// Pure: no baas/SDK import. Ports the webcam overlay + capture logic from
// public/assets/js/camera.js (live preview, mirrored capture) and replaces the
// PHP server-side GD composition with client-side canvas + GIF encoding.

import {
  loadImage,
  sourceSize,
  drawMirrored,
  compositeOverlay,
  newCanvas,
  canvasToBlob,
} from './canvas.js';
import { encodeGif } from './gif-encoder.js';

/**
 * liveOverlay drives a requestAnimationFrame loop that mirrors the camera.js
 * preview: each tick draws the video frame (mirrored for a webcam) then the
 * overlay scaled to fill. Returns a stop() that cancels the loop.
 * @param canvas     the visible preview canvas to paint into
 * @param video      the playing HTMLVideoElement source
 * @param overlayImg an HTMLImageElement (or null) drawn on top each frame
 * @param mirror     flip horizontally to match the user-facing camera
 * @returns function that stops the animation loop
 */
export function liveOverlay({ canvas, video, overlayImg, mirror = true }) {
  const ctx = canvas.getContext('2d');
  let raf = 0;
  let running = true;
  const tick = () => {
    if (!running) return;
    paintLiveFrame(ctx, canvas, video, overlayImg, mirror);
    raf = requestAnimationFrame(tick);
  };
  raf = requestAnimationFrame(tick);
  return () => {
    running = false;
    cancelAnimationFrame(raf);
  };
}

/** paintLiveFrame sizes the canvas to the video and draws frame + overlay once. */
function paintLiveFrame(ctx, canvas, video, overlayImg, mirror) {
  const { width, height } = sourceSize(video);
  if (!width || !height) return;
  if (canvas.width !== width || canvas.height !== height) {
    canvas.width = width;
    canvas.height = height;
  }
  ctx.clearRect(0, 0, width, height);
  drawMirrored(ctx, video, width, height, mirror);
  compositeOverlay(ctx, overlayImg, width, height);
}

/**
 * composePhoto renders one still: the source (video frame, image, or canvas)
 * drawn at native resolution with the overlay composited on top, returned as a
 * Blob of the requested image type.
 * @param source     HTMLVideoElement | HTMLImageElement | HTMLCanvasElement
 * @param overlayUrl URL of the overlay PNG to composite (optional)
 * @param mirror     flip horizontally (webcam capture parity)
 * @param type       output MIME type (default image/png)
 * @returns Promise<Blob>
 */
export async function composePhoto({ source, overlayUrl, mirror = false, type = 'image/png' }) {
  const { width, height } = sourceSize(source);
  const { canvas, ctx } = newCanvas(width, height);
  drawMirrored(ctx, source, width, height, mirror);
  if (overlayUrl) compositeOverlay(ctx, await loadImage(overlayUrl), width, height);
  return canvasToBlob(canvas, type);
}

/**
 * composeGif composites the overlay onto every captured frame and encodes an
 * animated GIF. Frames are normalized to the first frame's size; the overlay is
 * loaded once and reused per frame.
 * @param frames     array of HTMLVideoElement|HTMLImageElement|HTMLCanvasElement
 * @param overlayUrl URL of the overlay PNG (optional)
 * @param mirror     flip each frame horizontally (webcam parity)
 * @param delayMs    per-frame delay in ms (default 200)
 * @param loop       loop count, 0 = infinite (default 0)
 * @returns Promise<Blob> of type image/gif
 */
export async function composeGif({ frames, overlayUrl, mirror = false, delayMs = 200, loop = 0 }) {
  if (!frames || !frames.length) throw new Error('composeGif: no frames provided');
  const { width, height } = sourceSize(frames[0]);
  const overlayImg = overlayUrl ? await loadImage(overlayUrl) : null;
  const rgbaFrames = frames.map((frame) => renderRgbaFrame(frame, overlayImg, width, height, mirror));
  return encodeGif({ frames: rgbaFrames, width, height, delayMs, loop });
}

/** renderRgbaFrame draws one source + overlay and extracts its RGBA pixel data. */
function renderRgbaFrame(source, overlayImg, width, height, mirror) {
  const { canvas, ctx } = newCanvas(width, height);
  drawMirrored(ctx, source, width, height, mirror);
  compositeOverlay(ctx, overlayImg, width, height);
  return { data: ctx.getImageData(0, 0, width, height).data };
}

export const composition = { liveOverlay, composePhoto, composeGif };
