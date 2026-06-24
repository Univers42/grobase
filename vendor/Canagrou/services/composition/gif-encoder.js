// gif-encoder.js — a dependency-free animated GIF89a encoder. Takes RGBA frames
// (Uint8ClampedArray from a canvas) and produces a single multi-frame GIF Blob a
// browser renders natively: per-frame palette (median cut) + LZW image data +
// Netscape 2.0 loop extension + per-frame Graphic Control Extension. Ports the
// byte-structure concept from app/Core/GifEncoder.php, replacing GD's imagegif
// with real client-side quantization + LZW.

/** ByteWriter accumulates GIF bytes in a growable buffer. */
class ByteWriter {
  constructor() {
    this.buf = new Uint8Array(1024);
    this.len = 0;
  }

  /** byte appends one 8-bit value, growing the buffer as needed. */
  byte(v) {
    if (this.len >= this.buf.length) {
      const next = new Uint8Array(this.buf.length * 2);
      next.set(this.buf);
      this.buf = next;
    }
    this.buf[this.len++] = v & 0xff;
  }

  /** bytes appends every value of an array-like of 8-bit values. */
  bytes(arr) {
    for (let i = 0; i < arr.length; i++) this.byte(arr[i]);
  }

  /** word appends a 16-bit little-endian value (GIF byte order). */
  word(v) {
    this.byte(v & 0xff);
    this.byte((v >> 8) & 0xff);
  }

  /** ascii appends each character of a string as a byte. */
  ascii(s) {
    for (let i = 0; i < s.length; i++) this.byte(s.charCodeAt(i));
  }

  /** done returns the written bytes as a tightly-sized view. */
  done() {
    return this.buf.subarray(0, this.len);
  }
}

/**
 * quantize reduces RGBA pixels to at most 256 colors via median-cut, returning
 * the palette (flat RGB triples) and a per-pixel palette-index array.
 */
function quantize(rgba) {
  const samples = collectSamples(rgba);
  const palette = medianCut(samples, 256);
  const indices = mapToPalette(rgba, palette);
  return { palette, indices };
}

/** collectSamples extracts opaque-ish RGB samples (skipping near-transparent). */
function collectSamples(rgba) {
  const out = [];
  for (let i = 0; i < rgba.length; i += 4) {
    if (rgba[i + 3] < 8) continue;
    out.push([rgba[i], rgba[i + 1], rgba[i + 2]]);
  }
  return out.length ? out : [[0, 0, 0]];
}

/** medianCut splits the color cube until it holds up to `max` average colors. */
function medianCut(samples, max) {
  let boxes = [samples];
  while (boxes.length < max) {
    const idx = widestBox(boxes);
    if (idx < 0) break;
    const [a, b] = splitBox(boxes[idx]);
    boxes.splice(idx, 1, a, b);
  }
  const palette = [];
  for (const box of boxes) palette.push(averageColor(box));
  while (palette.length < 2) palette.push([0, 0, 0]);
  return palette;
}

/** widestBox returns the index of the splittable box with the largest spread. */
function widestBox(boxes) {
  let best = -1;
  let bestRange = 0;
  for (let i = 0; i < boxes.length; i++) {
    if (boxes[i].length < 2) continue;
    const r = boxRange(boxes[i]).range;
    if (r > bestRange) {
      bestRange = r;
      best = i;
    }
  }
  return best;
}

/** boxRange computes the dominant channel and its min-max spread for a box. */
function boxRange(box) {
  const min = [255, 255, 255];
  const max = [0, 0, 0];
  for (const c of box) {
    for (let k = 0; k < 3; k++) {
      if (c[k] < min[k]) min[k] = c[k];
      if (c[k] > max[k]) max[k] = c[k];
    }
  }
  const spread = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
  const channel = spread.indexOf(Math.max(spread[0], spread[1], spread[2]));
  return { channel, range: spread[channel] };
}

/** splitBox sorts a box on its widest channel and halves it at the median. */
function splitBox(box) {
  const { channel } = boxRange(box);
  const sorted = box.slice().sort((x, y) => x[channel] - y[channel]);
  const mid = sorted.length >> 1;
  return [sorted.slice(0, mid), sorted.slice(mid)];
}

/** averageColor returns the mean RGB of a box, rounded to integers. */
function averageColor(box) {
  let r = 0;
  let g = 0;
  let b = 0;
  for (const c of box) {
    r += c[0];
    g += c[1];
    b += c[2];
  }
  const n = box.length || 1;
  return [Math.round(r / n), Math.round(g / n), Math.round(b / n)];
}

/** mapToPalette assigns each pixel the nearest palette color by squared distance. */
function mapToPalette(rgba, palette) {
  const pixels = rgba.length / 4;
  const indices = new Uint8Array(pixels);
  for (let p = 0; p < pixels; p++) {
    indices[p] = nearestColor(rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2], palette);
  }
  return indices;
}

/** nearestColor finds the palette index closest to (r,g,b) in RGB space. */
function nearestColor(r, g, b, palette) {
  let best = 0;
  let bestD = Infinity;
  for (let i = 0; i < palette.length; i++) {
    const dr = r - palette[i][0];
    const dg = g - palette[i][1];
    const db = b - palette[i][2];
    const d = dr * dr + dg * dg + db * db;
    if (d < bestD) {
      bestD = d;
      best = i;
    }
  }
  return best;
}

/** colorBits returns the GIF size code so 2^(code+1) covers the palette length. */
function colorBits(len) {
  let bits = 1;
  while (1 << (bits + 1) < len) bits++;
  return Math.min(bits, 7);
}

/** writeColorTable emits a power-of-two-padded RGB table for `bits` size. */
function writeColorTable(w, palette, bits) {
  const entries = 1 << (bits + 1);
  for (let i = 0; i < entries; i++) {
    const c = palette[i] || [0, 0, 0];
    w.byte(c[0]);
    w.byte(c[1]);
    w.byte(c[2]);
  }
}

/**
 * lzwEncode compresses palette indices with variable-width GIF LZW, returning
 * the packed code stream (without the leading min-code-size byte).
 */
function lzwEncode(indices, minCode) {
  const clear = 1 << minCode;
  const eoi = clear + 1;
  const out = new ByteWriter();
  const bits = new BitPacker(out);
  let codeSize = minCode + 1;
  let dict = newDict(clear);
  let next = eoi + 1;
  bits.write(clear, codeSize);
  let prefix = String(indices[0]);
  for (let i = 1; i < indices.length; i++) {
    const k = indices[i];
    const combined = `${prefix},${k}`;
    if (dict.has(combined)) {
      prefix = combined;
      continue;
    }
    bits.write(dict.get(prefix), codeSize);
    dict.set(combined, next++);
    if (next > 1 << codeSize && codeSize < 12) codeSize++;
    if (next > 4096) {
      bits.write(clear, codeSize);
      dict = newDict(clear);
      next = eoi + 1;
      codeSize = minCode + 1;
    }
    prefix = String(k);
  }
  bits.write(dict.get(prefix), codeSize);
  bits.write(eoi, codeSize);
  bits.flush();
  return out.done();
}

/** newDict seeds the LZW dictionary with every root code 0..clear-1. */
function newDict(clear) {
  const dict = new Map();
  for (let i = 0; i < clear; i++) dict.set(String(i), i);
  return dict;
}

/** BitPacker writes variable-width codes LSB-first into a byte stream. */
class BitPacker {
  constructor(writer) {
    this.w = writer;
    this.acc = 0;
    this.nbits = 0;
  }

  /** write pushes `size` low bits of `code` into the accumulator. */
  write(code, size) {
    this.acc |= code << this.nbits;
    this.nbits += size;
    while (this.nbits >= 8) {
      this.w.byte(this.acc & 0xff);
      this.acc >>= 8;
      this.nbits -= 8;
    }
  }

  /** flush emits any remaining buffered bits as a final byte. */
  flush() {
    if (this.nbits > 0) {
      this.w.byte(this.acc & 0xff);
      this.acc = 0;
      this.nbits = 0;
    }
  }
}

/** writeSubBlocks splits LZW data into ≤255-byte sub-blocks terminated by 0x00. */
function writeSubBlocks(w, data) {
  let off = 0;
  while (off < data.length) {
    const n = Math.min(255, data.length - off);
    w.byte(n);
    for (let i = 0; i < n; i++) w.byte(data[off + i]);
    off += n;
  }
  w.byte(0x00);
}

/** writeFrame emits one frame: GCE + image descriptor + local table + LZW data. */
function writeFrame(w, frame, width, height, delayCs) {
  const { palette, indices } = quantize(frame);
  const bits = colorBits(palette.length);
  w.bytes([0x21, 0xf9, 0x04, 0x00]);
  w.word(delayCs);
  w.bytes([0x00, 0x00]);
  w.byte(0x2c);
  w.word(0);
  w.word(0);
  w.word(width);
  w.word(height);
  w.byte(0x80 | bits);
  writeColorTable(w, palette, bits);
  const minCode = Math.max(2, bits + 1);
  w.byte(minCode);
  writeSubBlocks(w, lzwEncode(indices, minCode));
}

/**
 * encodeGif builds a complete animated GIF89a Blob from RGBA frames.
 * @param frames  array of {data:Uint8ClampedArray (RGBA)} same width/height
 * @param width   frame width in pixels
 * @param height  frame height in pixels
 * @param delayMs per-frame delay in milliseconds (stored as centiseconds)
 * @param loop    loop count (0 = infinite)
 * @returns Blob of type image/gif
 */
export function encodeGif({ frames, width, height, delayMs = 200, loop = 0 }) {
  if (!frames || !frames.length) throw new Error('encodeGif: no frames');
  const w = new ByteWriter();
  w.ascii('GIF89a');
  w.word(width);
  w.word(height);
  w.bytes([0x70, 0x00, 0x00]);
  w.bytes([0x21, 0xff, 0x0b]);
  w.ascii('NETSCAPE2.0');
  w.bytes([0x03, 0x01]);
  w.word(loop);
  w.byte(0x00);
  const delayCs = Math.max(2, Math.round(delayMs / 10));
  for (const frame of frames) writeFrame(w, frame.data, width, height, delayCs);
  w.byte(0x3b);
  return new Blob([w.done()], { type: 'image/gif' });
}
