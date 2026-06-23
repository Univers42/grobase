// Pure functions for Tetris game logic
// No side effects, no `this` keyword - fully functional approach

const { BOARD_WIDTH, BOARD_HEIGHT, PIECES, PIECE_NAMES, SCORES } = require('./constants');

// Create an empty board (2D array of 0s)
const createEmptyBoard = () =>
  Array.from({ length: BOARD_HEIGHT }, () => Array(BOARD_WIDTH).fill(0));

// Get the cells a piece occupies given its type, rotation, and position
const getPieceCells = (pieceType, rotation, x, y) => {
  const shape = PIECES[pieceType];
  if (!shape) return [];
  const rotationState = shape.rotations[rotation % shape.rotations.length];
  return rotationState.map(([dx, dy]) => [x + dx, y + dy]);
};

// Check if a piece position is valid (within bounds and no collisions)
const isValidPosition = (board, pieceType, rotation, x, y) => {
  const cells = getPieceCells(pieceType, rotation, x, y);
  return cells.every(([cx, cy]) => {
    if (cx < 0 || cx >= BOARD_WIDTH) return false;
    if (cy >= BOARD_HEIGHT) return false;
    // Allow cells above the board (negative y)
    if (cy < 0) return true;
    return board[cy][cx] === 0;
  });
};

// Place a piece on the board, returning a new board
const placePiece = (board, pieceType, rotation, x, y) => {
  const cells = getPieceCells(pieceType, rotation, x, y);
  const color = PIECES[pieceType].color;
  const newBoard = board.map(row => [...row]);
  cells.forEach(([cx, cy]) => {
    if (cy >= 0 && cy < BOARD_HEIGHT && cx >= 0 && cx < BOARD_WIDTH) {
      newBoard[cy][cx] = color;
    }
  });
  return newBoard;
};

// Clear completed lines, returning { board, linesCleared }
const clearLines = (board) => {
  const remainingRows = board.filter(row => row.some(cell => cell === 0));
  const linesCleared = BOARD_HEIGHT - remainingRows.length;
  const emptyRows = Array.from({ length: linesCleared }, () =>
    Array(BOARD_WIDTH).fill(0)
  );
  return {
    board: [...emptyRows, ...remainingRows],
    linesCleared,
  };
};

// Add penalty (indestructible) lines at the bottom
const addPenaltyLines = (board, count) => {
  if (count <= 0) return board;
  const penaltyRow = Array(BOARD_WIDTH).fill(8); // 8 = penalty color
  const penaltyRows = Array.from({ length: count }, () => [...penaltyRow]);
  // Remove top rows to make room
  const trimmedBoard = board.slice(count);
  return [...trimmedBoard, ...penaltyRows];
};

// Calculate the hard drop position (lowest valid Y)
const getHardDropY = (board, pieceType, rotation, x, y) => {
  let dropY = y;
  while (isValidPosition(board, pieceType, rotation, x, dropY + 1)) {
    dropY += 1;
  }
  return dropY;
};

// Move piece in a direction, returns new position or null if invalid
const movePiece = (board, pieceType, rotation, x, y, dx, dy) => {
  const newX = x + dx;
  const newY = y + dy;
  if (isValidPosition(board, pieceType, rotation, newX, newY)) {
    return { x: newX, y: newY, rotation };
  }
  return null;
};

// Rotate piece with wall kick attempts
const rotatePiece = (board, pieceType, rotation, x, y) => {
  const newRotation = (rotation + 1) % 4;
  // Try basic rotation
  if (isValidPosition(board, pieceType, newRotation, x, y)) {
    return { x, y, rotation: newRotation };
  }
  // Wall kick attempts
  const kicks = [-1, 1, -2, 2];
  for (const kick of kicks) {
    if (isValidPosition(board, pieceType, newRotation, x + kick, y)) {
      return { x: x + kick, y, rotation: newRotation };
    }
  }
  // Try shifting up
  if (isValidPosition(board, pieceType, newRotation, x, y - 1)) {
    return { x, y: y - 1, rotation: newRotation };
  }
  return null;
};

// Get the initial spawn position for a piece
const getSpawnPosition = (pieceType) => {
  return { x: Math.floor((BOARD_WIDTH - 3) / 2), y: 0, rotation: 0 };
};

// Check if the game is over (piece can't spawn)
const isGameOver = (board, pieceType) => {
  const { x, y, rotation } = getSpawnPosition(pieceType);
  return !isValidPosition(board, pieceType, rotation, x, y);
};

// Compute spectrum: height of highest block in each column
const computeSpectrum = (board) => {
  const spectrum = Array(BOARD_WIDTH).fill(0);
  for (let col = 0; col < BOARD_WIDTH; col++) {
    for (let row = 0; row < BOARD_HEIGHT; row++) {
      if (board[row][col] !== 0) {
        spectrum[col] = BOARD_HEIGHT - row;
        break;
      }
    }
  }
  return spectrum;
};

// Calculate score for lines cleared
const calculateScore = (linesCleared, dropDistance, isHardDrop) => {
  let lineScore = 0;
  switch (linesCleared) {
    case 1: lineScore = SCORES.SINGLE; break;
    case 2: lineScore = SCORES.DOUBLE; break;
    case 3: lineScore = SCORES.TRIPLE; break;
    case 4: lineScore = SCORES.TETRIS; break;
    default: lineScore = 0;
  }
  const dropScore = isHardDrop
    ? dropDistance * SCORES.HARD_DROP
    : dropDistance * SCORES.SOFT_DROP;
  return lineScore + dropScore;
};

// Apply "invisible" mode: after placing, cells older than 2 seconds become invisible
// We handle this via rendering, not board mutation
const applyGravityMode = (board) => {
  // In gravity mode, floating blocks should fall down
  const newBoard = createEmptyBoard();
  for (let col = 0; col < BOARD_WIDTH; col++) {
    let writeRow = BOARD_HEIGHT - 1;
    for (let row = BOARD_HEIGHT - 1; row >= 0; row--) {
      if (board[row][col] !== 0) {
        newBoard[writeRow][col] = board[row][col];
        writeRow--;
      }
    }
  }
  return newBoard;
};

module.exports = {
  createEmptyBoard,
  getPieceCells,
  isValidPosition,
  placePiece,
  clearLines,
  addPenaltyLines,
  getHardDropY,
  movePiece,
  rotatePiece,
  getSpawnPosition,
  isGameOver,
  computeSpectrum,
  calculateScore,
  applyGravityMode,
};
