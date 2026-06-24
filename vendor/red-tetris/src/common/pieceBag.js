import { PIECE_NAMES } from './constants';

/**
 * Deterministic 7-bag piece generator shared by every client in a room.
 *
 * Given the same `seed`, every browser produces the byte-identical sequence —
 * which is exactly what lets multiplayer work with NO server: the host
 * broadcasts a single seed and each peer regenerates the pieces locally.
 * Returns `count` pieces as `{ type, index }`, the same shape the old
 * Socket.IO server emitted, so the reducers/engine are unchanged.
 *
 * @param {number} count how many pieces to materialize (regenerated from 0)
 * @param {number} seed  the room seed broadcast by the host
 * @returns {{type:string,index:number}[]}
 */
export function generate(count, seed) {
  const rng = lcg(seed);
  const pieces = [];
  let bag = [];
  let bagIndex = 0;
  for (let i = 0; i < count; i += 1) {
    if (bagIndex >= bag.length) {
      bag = shuffle(PIECE_NAMES.slice(), rng);
      bagIndex = 0;
    }
    pieces.push({ type: bag[bagIndex], index: i });
    bagIndex += 1;
  }
  return pieces;
}

/**
 * Seeded linear-congruential generator — the exact recurrence the legacy
 * server used, kept byte-for-byte so existing replays stay reproducible.
 */
function lcg(seed) {
  let s = seed;
  return () => {
    s = (s * 1103515245 + 12345) & 0x7fffffff;
    return s / 0x7fffffff;
  };
}

/** In-place Fisher–Yates shuffle driven by the seeded rng. */
function shuffle(arr, rng) {
  for (let i = arr.length - 1; i > 0; i -= 1) {
    const j = Math.floor(rng() * (i + 1));
    [arr[i], arr[j]] = [arr[j], arr[i]];
  }
  return arr;
}
