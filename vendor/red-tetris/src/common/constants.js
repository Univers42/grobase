// Shared constants between client and server

const BOARD_WIDTH = 10;
const BOARD_HEIGHT = 20;
const TICK_SPEED_MS = 1000;

// Tetrimino shapes with SRS rotation states
// Each piece has 4 rotation states
const PIECES = {
  I: {
    color: 1,
    rotations: [
      [[0,0],[1,0],[2,0],[3,0]],
      [[1,-1],[1,0],[1,1],[1,2]],
      [[0,1],[1,1],[2,1],[3,1]],
      [[2,-1],[2,0],[2,1],[2,2]],
    ],
  },
  O: {
    color: 2,
    rotations: [
      [[0,0],[1,0],[0,1],[1,1]],
      [[0,0],[1,0],[0,1],[1,1]],
      [[0,0],[1,0],[0,1],[1,1]],
      [[0,0],[1,0],[0,1],[1,1]],
    ],
  },
  T: {
    color: 3,
    rotations: [
      [[0,0],[1,0],[2,0],[1,1]],
      [[1,-1],[1,0],[1,1],[0,0]],
      [[0,1],[1,1],[2,1],[1,0]],
      [[1,-1],[1,0],[1,1],[2,0]],
    ],
  },
  S: {
    color: 4,
    rotations: [
      [[1,0],[2,0],[0,1],[1,1]],
      [[1,0],[1,1],[2,1],[2,2]],
      [[1,0],[2,0],[0,1],[1,1]],
      [[1,0],[1,1],[2,1],[2,2]],
    ],
  },
  Z: {
    color: 5,
    rotations: [
      [[0,0],[1,0],[1,1],[2,1]],
      [[2,0],[1,1],[2,1],[1,2]],
      [[0,0],[1,0],[1,1],[2,1]],
      [[2,0],[1,1],[2,1],[1,2]],
    ],
  },
  J: {
    color: 6,
    rotations: [
      [[0,0],[1,0],[2,0],[0,1]],
      [[0,-1],[1,-1],[1,0],[1,1]],
      [[2,0],[0,1],[1,1],[2,1]],
      [[1,-1],[1,0],[1,1],[2,1]],
    ],
  },
  L: {
    color: 7,
    rotations: [
      [[0,0],[1,0],[2,0],[2,1]],
      [[1,-1],[1,0],[1,1],[0,1]],
      [[0,0],[0,1],[1,1],[2,1]],
      [[1,-1],[2,-1],[1,0],[1,1]],
    ],
  },
};

const PIECE_NAMES = Object.keys(PIECES);

const COLORS = {
  0: 'transparent',
  1: '#00f0f0', // I - Cyan
  2: '#f0f000', // O - Yellow
  3: '#a000f0', // T - Purple
  4: '#00f000', // S - Green
  5: '#f00000', // Z - Red
  6: '#0000f0', // J - Blue
  7: '#f0a000', // L - Orange
  8: '#808080', // Penalty / indestructible
  9: '#333333', // Ghost piece
};

const GAME_MODES = {
  CLASSIC: 'classic',
  INVISIBLE: 'invisible',
  GRAVITY: 'gravity',
};

const SCORES = {
  SINGLE: 100,
  DOUBLE: 300,
  TRIPLE: 500,
  TETRIS: 800,
  SOFT_DROP: 1,
  HARD_DROP: 2,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BOARD_WIDTH,
    BOARD_HEIGHT,
    TICK_SPEED_MS,
    PIECES,
    PIECE_NAMES,
    COLORS,
    GAME_MODES,
    SCORES,
  };
}
