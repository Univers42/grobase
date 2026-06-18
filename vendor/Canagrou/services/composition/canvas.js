// canvas.js — pure canvas drawing helpers for photo composition. No baas/SDK
// import: every function takes raw inputs (elements, urls, canvases) and returns
// canvases/images/blobs. Shared by composition/index.js for the still-photo,
// GIF, and live-preview paths.

/**
 * loadImage resolves an HTMLImageElement once the URL has decoded, with
 * crossOrigin set so the drawn pixels stay readable (no tainted canvas).
 */
export function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = () => resolve(img);
    img.onerror = () => reject(new Error(`failed to load image: ${url}`));
    img.src = url;
  });
}

/**
 * sourceSize returns the natural pixel dimensions of a video, image, or canvas
 * source, falling back to a sane default when the source is not yet measured.
 */
export function sourceSize(source) {
  if (source instanceof HTMLVideoElement) {
    return { width: source.videoWidth || 640, height: source.videoHeight || 480 };
  }
  if (source instanceof HTMLImageElement) {
    return { width: source.naturalWidth || 640, height: source.naturalHeight || 480 };
  }
  return { width: source.width || 640, height: source.height || 480 };
}

/**
 * drawMirrored paints a drawable source onto ctx, optionally flipped
 * horizontally to match a user-facing webcam preview.
 */
export function drawMirrored(ctx, source, width, height, mirror) {
  if (mirror) {
    ctx.save();
    ctx.translate(width, 0);
    ctx.scale(-1, 1);
    ctx.drawImage(source, 0, 0, width, height);
    ctx.restore();
    return;
  }
  ctx.drawImage(source, 0, 0, width, height);
}

/**
 * compositeOverlay draws an already-loaded overlay image scaled to fill the
 * full canvas area on top of whatever was drawn first.
 */
export function compositeOverlay(ctx, overlayImg, width, height) {
  if (overlayImg) ctx.drawImage(overlayImg, 0, 0, width, height);
}

/**
 * newCanvas returns an offscreen canvas of the given pixel dimensions plus its
 * 2D context, the building block for still and per-frame composition.
 */
export function newCanvas(width, height) {
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  return { canvas, ctx: canvas.getContext('2d') };
}

/**
 * canvasToBlob promisifies canvas.toBlob so composition can `await` the encoded
 * image bytes, rejecting if the browser yields no blob.
 */
export function canvasToBlob(canvas, type) {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error('canvas.toBlob produced no blob'))), type);
  });
}
