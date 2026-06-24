/**
 * @jest-environment jsdom
 */
import { ACTIONS } from '../../src/client/actions/types';
import {
  connectionReducer,
  gameReducer,
  boardReducer,
  uiReducer,
} from '../../src/client/reducers';

describe('connectionReducer', () => {
  const initialState = { socket: null, connected: false, error: null };

  it('should return initial state', () => {
    expect(connectionReducer(undefined, { type: 'UNKNOWN' })).toEqual(initialState);
  });

  it('should handle SET_SOCKET', () => {
    const socket = { id: 'test' };
    const state = connectionReducer(initialState, {
      type: ACTIONS.SET_SOCKET,
      payload: socket,
    });
    expect(state.socket).toBe(socket);
  });

  it('should handle SET_CONNECTED', () => {
    const state = connectionReducer(initialState, {
      type: ACTIONS.SET_CONNECTED,
      payload: true,
    });
    expect(state.connected).toBe(true);
  });

  it('should handle SET_ERROR', () => {
    const state = connectionReducer(initialState, {
      type: ACTIONS.SET_ERROR,
      payload: 'Connection failed',
    });
    expect(state.error).toBe('Connection failed');
  });

  it('should handle CLEAR_ERROR', () => {
    const stateWithError = { ...initialState, error: 'some error' };
    const state = connectionReducer(stateWithError, {
      type: ACTIONS.CLEAR_ERROR,
    });
    expect(state.error).toBeNull();
  });
});

describe('gameReducer', () => {
  const initialState = {
    room: null,
    playerName: null,
    gameState: null,
    isPlaying: false,
    gameMode: 'classic',
    gameOver: false,
    leaderboard: [],
  };

  it('should return initial state', () => {
    expect(gameReducer(undefined, { type: 'UNKNOWN' })).toEqual(initialState);
  });

  it('should handle SET_ROOM', () => {
    const state = gameReducer(initialState, {
      type: ACTIONS.SET_ROOM,
      payload: 'myRoom',
    });
    expect(state.room).toBe('myRoom');
  });

  it('should handle SET_PLAYER_NAME', () => {
    const state = gameReducer(initialState, {
      type: ACTIONS.SET_PLAYER_NAME,
      payload: 'Alice',
    });
    expect(state.playerName).toBe('Alice');
  });

  it('should handle SET_GAME_STATE', () => {
    const gameState = { isStarted: true, players: [] };
    const state = gameReducer(initialState, {
      type: ACTIONS.SET_GAME_STATE,
      payload: gameState,
    });
    expect(state.gameState).toEqual(gameState);
  });

  it('should handle SET_GAME_MODE', () => {
    const state = gameReducer(initialState, {
      type: ACTIONS.SET_GAME_MODE,
      payload: 'invisible',
    });
    expect(state.gameMode).toBe('invisible');
  });

  it('should handle GAME_STARTED', () => {
    const state = gameReducer(initialState, {
      type: ACTIONS.GAME_STARTED,
      payload: { pieces: [], gameMode: 'gravity', players: [] },
    });
    expect(state.isPlaying).toBe(true);
    expect(state.gameOver).toBe(false);
    expect(state.gameMode).toBe('gravity');
  });

  it('should handle GAME_ENDED', () => {
    const playingState = { ...initialState, isPlaying: true };
    const state = gameReducer(playingState, {
      type: ACTIONS.GAME_ENDED,
      payload: { leaderboard: [{ name: 'A', score: 100 }] },
    });
    expect(state.isPlaying).toBe(false);
    expect(state.gameOver).toBe(true);
    expect(state.leaderboard.length).toBe(1);
  });

  it('should handle GAME_RESET', () => {
    const playingState = { ...initialState, isPlaying: true, gameOver: true };
    const state = gameReducer(playingState, { type: ACTIONS.GAME_RESET });
    expect(state.isPlaying).toBe(false);
    expect(state.gameOver).toBe(false);
    expect(state.leaderboard).toEqual([]);
  });
});

describe('boardReducer', () => {
  const emptyBoard = Array.from({ length: 20 }, () => Array(10).fill(0));
  const initialState = {
    board: emptyBoard,
    currentPiece: null,
    pieceQueue: [],
    score: 0,
    lines: 0,
    pendingPenalty: 0,
    opponents: {},
  };

  it('should return initial state', () => {
    const state = boardReducer(undefined, { type: 'UNKNOWN' });
    expect(state.board.length).toBe(20);
    expect(state.score).toBe(0);
  });

  it('should handle SET_BOARD', () => {
    const newBoard = emptyBoard.map(r => [...r]);
    newBoard[19][0] = 1;
    const state = boardReducer(initialState, {
      type: ACTIONS.SET_BOARD,
      payload: newBoard,
    });
    expect(state.board[19][0]).toBe(1);
  });

  it('should handle SET_CURRENT_PIECE', () => {
    const piece = { type: 'T', x: 3, y: 0, rotation: 0 };
    const state = boardReducer(initialState, {
      type: ACTIONS.SET_CURRENT_PIECE,
      payload: piece,
    });
    expect(state.currentPiece).toEqual(piece);
  });

  it('should handle SET_PIECE_QUEUE', () => {
    const queue = [{ type: 'I', index: 0 }, { type: 'T', index: 1 }];
    const state = boardReducer(initialState, {
      type: ACTIONS.SET_PIECE_QUEUE,
      payload: queue,
    });
    expect(state.pieceQueue.length).toBe(2);
  });

  it('should handle ADD_SCORE', () => {
    const state = boardReducer(initialState, {
      type: ACTIONS.ADD_SCORE,
      payload: 100,
    });
    expect(state.score).toBe(100);
    const state2 = boardReducer(state, {
      type: ACTIONS.ADD_SCORE,
      payload: 50,
    });
    expect(state2.score).toBe(150);
  });

  it('should handle SET_SCORE', () => {
    const state = boardReducer({ ...initialState, score: 500 }, {
      type: ACTIONS.SET_SCORE,
      payload: 0,
    });
    expect(state.score).toBe(0);
  });

  it('should handle SET_LINES', () => {
    const state = boardReducer(initialState, {
      type: ACTIONS.SET_LINES,
      payload: 42,
    });
    expect(state.lines).toBe(42);
  });

  it('should handle ADD_PENALTY_LINES', () => {
    const state = boardReducer(initialState, {
      type: ACTIONS.ADD_PENALTY_LINES,
      payload: 3,
    });
    expect(state.pendingPenalty).toBe(3);
  });

  it('should handle UPDATE_OPPONENT_SPECTRUM', () => {
    const state = boardReducer(initialState, {
      type: ACTIONS.UPDATE_OPPONENT_SPECTRUM,
      payload: { socketId: 's1', playerName: 'Bob', spectrum: [1, 2, 3] },
    });
    expect(state.opponents.s1).toEqual({
      playerName: 'Bob',
      spectrum: [1, 2, 3],
    });
  });

  it('should handle GAME_STARTED (resets board)', () => {
    const state = boardReducer({ ...initialState, score: 500 }, {
      type: ACTIONS.GAME_STARTED,
      payload: { pieces: [{ type: 'I', index: 0 }], gameMode: 'classic', players: [] },
    });
    expect(state.score).toBe(0);
    expect(state.pieceQueue.length).toBe(1);
  });

  it('should handle GAME_RESET', () => {
    const state = boardReducer({ ...initialState, score: 500, lines: 10 }, {
      type: ACTIONS.GAME_RESET,
    });
    expect(state.score).toBe(0);
    expect(state.lines).toBe(0);
  });
});

describe('uiReducer', () => {
  const initialState = { roomsList: [] };

  it('should return initial state', () => {
    expect(uiReducer(undefined, { type: 'UNKNOWN' })).toEqual(initialState);
  });

  it('should handle SET_ROOMS_LIST', () => {
    const rooms = [{ roomName: 'test', playerCount: 2 }];
    const state = uiReducer(initialState, {
      type: ACTIONS.SET_ROOMS_LIST,
      payload: rooms,
    });
    expect(state.roomsList).toEqual(rooms);
  });
});
