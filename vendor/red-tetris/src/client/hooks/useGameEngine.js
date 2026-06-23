import { useEffect, useRef, useCallback } from 'react';
import { useSelector, useDispatch } from 'react-redux';
import {
  setBoard,
  setCurrentPiece,
  setPieceQueue,
  addScore,
  setScore,
  setLines,
  sendSpectrum,
  sendBoardState,
  sendLinesCleared,
  sendGameOver,
} from '../actions';
import { generate } from '../../common/pieceBag';
import {
  createEmptyBoard,
  isValidPosition,
  placePiece,
  clearLines,
  addPenaltyLines,
  getHardDropY,
  movePiece,
  rotatePiece,
  getSpawnPosition,
  getPieceCells,
  isGameOver,
  computeSpectrum,
  calculateScore,
  applyGravityMode,
} from '../../common/gameLogic';
import { TICK_SPEED_MS, GAME_MODES, PIECES, BOARD_WIDTH, BOARD_HEIGHT } from '../../common/constants';

/**
 * mergePieceIntoBoard returns a copy of the locked board with the live falling
 * piece painted in its colour — the exact picture an opponent should watch, so
 * they see your pieces move and land in real time (not just a height silhouette).
 */
function mergePieceIntoBoard(board, piece) {
  const grid = board.map((row) => [...row]);
  if (piece) {
    const color = (PIECES[piece.type] || {}).color || 1;
    getPieceCells(piece.type, piece.rotation, piece.x, piece.y).forEach(([cx, cy]) => {
      if (cy >= 0 && cy < BOARD_HEIGHT && cx >= 0 && cx < BOARD_WIDTH) grid[cy][cx] = color;
    });
  }
  return grid;
}

/**
 * Custom hook: core Tetris game loop.
 * Pure functions handle game math; this hook manages the tick loop and input.
 */
const useGameEngine = () => {
  const dispatch = useDispatch();
  const isPlaying = useSelector(state => state.game.isPlaying);
  const gameMode = useSelector(state => state.game.gameMode);
  const pieceQueue = useSelector(state => state.board.pieceQueue);
  const seed = useSelector(state => state.board.seed);
  const pendingPenalty = useSelector(state => state.board.pendingPenalty);

  // Mutable refs for game state (avoid stale closure issues in interval)
  const boardRef = useRef(createEmptyBoard());
  const pieceRef = useRef(null); // { type, rotation, x, y }
  const pieceIndexRef = useRef(0);
  const queueRef = useRef([]);
  const scoreRef = useRef(0);
  const linesRef = useRef(0);
  const lockDelayRef = useRef(false);
  const gameOverRef = useRef(false);
  const penaltyRef = useRef(0);
  const placedTimesRef = useRef([]); // For invisible mode
  const tickRef = useRef(null);
  const gameModeRef = useRef('classic');
  const seedRef = useRef(0);
  const lastSpectrumRef = useRef('');
  const lastSpectrumAtRef = useRef(0);

  // Sync refs with redux
  useEffect(() => { queueRef.current = pieceQueue; }, [pieceQueue]);
  useEffect(() => { penaltyRef.current = pendingPenalty; }, [pendingPenalty]);
  useEffect(() => { gameModeRef.current = gameMode; }, [gameMode]);
  useEffect(() => { seedRef.current = seed; }, [seed]);

  const getTickSpeed = useCallback(() => {
    if (gameModeRef.current === GAME_MODES.GRAVITY) {
      return Math.max(100, TICK_SPEED_MS - linesRef.current * 20);
    }
    return Math.max(200, TICK_SPEED_MS - linesRef.current * 15);
  }, []);

  const pushSpectrum = useCallback((board) => {
    const spectrum = computeSpectrum(board);
    const key = spectrum.join(',');
    const now = Date.now();
    if (key === lastSpectrumRef.current || now - lastSpectrumAtRef.current < 120) return;
    lastSpectrumRef.current = key;
    lastSpectrumAtRef.current = now;
    dispatch(sendSpectrum(spectrum));
  }, [dispatch]);

  const updateBoard = useCallback((board) => {
    boardRef.current = board;
    dispatch(setBoard(board));
    pushSpectrum(board);
  }, [dispatch, pushSpectrum]);

  const spawnNextPiece = useCallback(() => {
    const index = pieceIndexRef.current;
    let queue = queueRef.current;

    if (index >= queue.length - 5 && seedRef.current) {
      queue = generate(queue.length + 600, seedRef.current);
      queueRef.current = queue;
      dispatch(setPieceQueue(queue));
    }

    if (index >= queue.length) return false;

    const pieceData = queue[index];
    const spawn = getSpawnPosition(pieceData.type);

    if (isGameOver(boardRef.current, pieceData.type)) {
      gameOverRef.current = true;
      dispatch(sendGameOver());
      return false;
    }

    pieceIndexRef.current = index + 1;
    pieceRef.current = {
      type: pieceData.type,
      ...spawn,
    };
    lockDelayRef.current = false;
    dispatch(setCurrentPiece(pieceRef.current));
    return true;
  }, [dispatch]);

  const lockPiece = useCallback(() => {
    const piece = pieceRef.current;
    if (!piece) return;

    let board = placePiece(
      boardRef.current,
      piece.type,
      piece.rotation,
      piece.x,
      piece.y
    );

    // Track placement time for invisible mode
    if (gameModeRef.current === GAME_MODES.INVISIBLE) {
      placedTimesRef.current.push({
        time: Date.now(),
        cells: board,
      });
    }

    // Apply gravity mode if enabled
    if (gameModeRef.current === GAME_MODES.GRAVITY) {
      board = applyGravityMode(board);
    }

    // Clear completed lines
    const { board: clearedBoard, linesCleared } = clearLines(board);
    board = clearedBoard;

    // Apply pending penalties
    if (penaltyRef.current > 0) {
      board = addPenaltyLines(board, penaltyRef.current);
      dispatch({ type: 'ADD_PENALTY_LINES', payload: -penaltyRef.current });
      penaltyRef.current = 0;
    }

    // Update score
    if (linesCleared > 0) {
      const points = calculateScore(linesCleared, 0, false);
      scoreRef.current += points;
      linesRef.current += linesCleared;
      dispatch(addScore(points));
      dispatch(setLines(linesRef.current));
      dispatch(sendLinesCleared(linesCleared, points));
    }

    updateBoard(board);
    pieceRef.current = null;
    dispatch(setCurrentPiece(null));

    // Spawn next piece
    spawnNextPiece();
  }, [dispatch, updateBoard, spawnNextPiece]);

  const tick = useCallback(() => {
    if (gameOverRef.current) return;

    const piece = pieceRef.current;
    if (!piece) return;

    const moved = movePiece(
      boardRef.current,
      piece.type,
      piece.rotation,
      piece.x,
      piece.y,
      0,
      1
    );

    if (moved) {
      pieceRef.current = { ...piece, ...moved };
      dispatch(setCurrentPiece(pieceRef.current));
      lockDelayRef.current = false;
    } else {
      // Piece can't move down
      if (lockDelayRef.current) {
        // Already had one frame of lock delay; lock it
        lockPiece();
      } else {
        // Give one frame of lock delay for last-moment adjustments
        lockDelayRef.current = true;
      }
    }
  }, [dispatch, lockPiece]);

  // Handle keyboard input
  const handleKeyDown = useCallback((e) => {
    if (gameOverRef.current || !pieceRef.current) return;

    const piece = pieceRef.current;
    let result;

    switch (e.key) {
      case 'ArrowLeft':
        e.preventDefault();
        result = movePiece(boardRef.current, piece.type, piece.rotation, piece.x, piece.y, -1, 0);
        if (result) {
          pieceRef.current = { ...piece, ...result };
          dispatch(setCurrentPiece(pieceRef.current));
        }
        break;

      case 'ArrowRight':
        e.preventDefault();
        result = movePiece(boardRef.current, piece.type, piece.rotation, piece.x, piece.y, 1, 0);
        if (result) {
          pieceRef.current = { ...piece, ...result };
          dispatch(setCurrentPiece(pieceRef.current));
        }
        break;

      case 'ArrowUp':
        e.preventDefault();
        result = rotatePiece(boardRef.current, piece.type, piece.rotation, piece.x, piece.y);
        if (result) {
          pieceRef.current = { ...piece, ...result };
          dispatch(setCurrentPiece(pieceRef.current));
        }
        break;

      case 'ArrowDown':
        e.preventDefault();
        result = movePiece(boardRef.current, piece.type, piece.rotation, piece.x, piece.y, 0, 1);
        if (result) {
          const points = calculateScore(0, 1, false);
          scoreRef.current += points;
          dispatch(addScore(points));
          pieceRef.current = { ...piece, ...result };
          dispatch(setCurrentPiece(pieceRef.current));
        }
        break;

      case ' ':
        e.preventDefault();
        {
          const dropY = getHardDropY(boardRef.current, piece.type, piece.rotation, piece.x, piece.y);
          const distance = dropY - piece.y;
          const points = calculateScore(0, distance, true);
          scoreRef.current += points;
          dispatch(addScore(points));
          pieceRef.current = { ...piece, y: dropY };
          dispatch(setCurrentPiece(pieceRef.current));
          lockPiece();
        }
        break;

      default:
        break;
    }
  }, [dispatch, lockPiece]);

  // Start/stop game loop
  useEffect(() => {
    if (isPlaying) {
      // Reset state
      boardRef.current = createEmptyBoard();
      pieceRef.current = null;
      pieceIndexRef.current = 0;
      scoreRef.current = 0;
      linesRef.current = 0;
      lockDelayRef.current = false;
      gameOverRef.current = false;
      penaltyRef.current = 0;
      placedTimesRef.current = [];

      dispatch(setScore(0));
      dispatch(setLines(0));
      updateBoard(createEmptyBoard());

      // Small delay to let pieces arrive
      const startTimeout = setTimeout(() => {
        spawnNextPiece();
      }, 100);

      // Start tick loop
      const runTick = () => {
        tick();
        tickRef.current = setTimeout(runTick, getTickSpeed());
      };
      tickRef.current = setTimeout(runTick, getTickSpeed());

      // Keyboard listener
      window.addEventListener('keydown', handleKeyDown);

      // Stream the live board (with the falling piece) so opponents watch you play.
      const boardStream = setInterval(() => {
        if (!gameOverRef.current) dispatch(sendBoardState(mergePieceIntoBoard(boardRef.current, pieceRef.current)));
      }, 90);

      return () => {
        clearTimeout(startTimeout);
        clearTimeout(tickRef.current);
        clearInterval(boardStream);
        window.removeEventListener('keydown', handleKeyDown);
      };
    }
    return () => {
      clearTimeout(tickRef.current);
      window.removeEventListener('keydown', handleKeyDown);
    };
  }, [isPlaying, dispatch, tick, handleKeyDown, spawnNextPiece, updateBoard, getTickSpeed]);

  return {
    boardRef,
    pieceRef,
    gameModeRef,
    placedTimesRef,
  };
};

export default useGameEngine;
