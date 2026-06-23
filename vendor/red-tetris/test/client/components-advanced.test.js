/**
 * @jest-environment jsdom
 */
import React from 'react';
import { render, screen, fireEvent } from '@testing-library/react';
import { Provider } from 'react-redux';
import { MemoryRouter, Routes, Route } from 'react-router-dom';
import { combineReducers, createStore, applyMiddleware } from 'redux';
import { thunk } from 'redux-thunk';
import {
  connectionReducer,
  gameReducer,
  boardReducer,
  uiReducer,
} from '../../src/client/reducers';
import Board from '../../src/client/components/Board';
import GameView from '../../src/client/components/GameView';
import Lobby from '../../src/client/components/Lobby';

const createTestStore = (overrides = {}) => {
  const rootReducer = combineReducers({
    connection: connectionReducer,
    game: gameReducer,
    board: boardReducer,
    ui: uiReducer,
  });
  return createStore(rootReducer, overrides, applyMiddleware(thunk));
};

const renderWithProviders = (ui, { store, route = '/' } = {}) => {
  const testStore = store || createTestStore();
  return render(
    <Provider store={testStore}>
      <MemoryRouter initialEntries={[route]}>
        <Routes>
          <Route path="/*" element={ui} />
        </Routes>
      </MemoryRouter>
    </Provider>
  );
};

const makeFullState = (overrides = {}) => ({
  connection: { socket: { emit: jest.fn() }, connected: true, error: null },
  game: {
    room: 'test',
    playerName: 'Alice',
    gameState: {
      roomName: 'test',
      isStarted: true,
      gameMode: 'classic',
      players: [
        { socketId: 's1', name: 'Alice', isHost: true, isPlaying: true, isEliminated: false, spectrum: Array(10).fill(0), score: 0, linesCleared: 0 },
      ],
      leaderboard: [],
    },
    isPlaying: true,
    gameMode: 'classic',
    gameOver: false,
    leaderboard: [],
  },
  board: {
    board: Array.from({ length: 20 }, () => Array(10).fill(0)),
    currentPiece: { type: 'T', x: 3, y: 5, rotation: 0 },
    pieceQueue: [
      { type: 'T', index: 0 },
      { type: 'I', index: 1 },
      { type: 'O', index: 2 },
      { type: 'S', index: 3 },
    ],
    score: 500,
    lines: 5,
    pendingPenalty: 0,
    opponents: {},
  },
  ui: { roomsList: [] },
  ...overrides,
});

describe('Board with active piece', () => {
  it('should render board with current piece visible', () => {
    const store = createTestStore(makeFullState());
    const gameModeRef = { current: 'classic' };
    const placedTimesRef = { current: [] };
    const { container } = renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    const cells = container.querySelectorAll('.cell');
    expect(cells.length).toBe(200);
    // Some cells should be colored (the T piece)
    const coloredCells = Array.from(cells).filter(c => {
      const bg = c.style.background;
      return bg && bg !== 'rgba(255,255,255,0.02)' && bg !== 'rgba(255, 255, 255, 0.02)';
    });
    expect(coloredCells.length).toBeGreaterThan(0);
  });

  it('should render ghost piece', () => {
    const store = createTestStore(makeFullState());
    const gameModeRef = { current: 'classic' };
    const placedTimesRef = { current: [] };
    const { container } = renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    // Ghost cells have specific style
    const cells = container.querySelectorAll('.cell');
    const ghostCells = Array.from(cells).filter(c => {
      const border = c.style.border;
      return border && border.includes('dashed');
    });
    expect(ghostCells.length).toBeGreaterThan(0);
  });

  it('should render in invisible mode', () => {
    const state = makeFullState();
    state.game.gameMode = 'invisible';
    // Place some blocks on the board
    state.board.board = state.board.board.map((row, i) => {
      if (i === 19) return Array(10).fill(1);
      return [...row];
    });
    const store = createTestStore(state);
    const gameModeRef = { current: 'invisible' };
    const placedTimesRef = { current: [] };
    const { container } = renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    expect(container.querySelectorAll('.cell').length).toBe(200);
  });

  it('should render board with penalty lines', () => {
    const state = makeFullState();
    // Fill bottom 2 rows with penalty blocks
    state.board.board = state.board.board.map((row, i) => {
      if (i >= 18) return Array(10).fill(8);
      return [...row];
    });
    const store = createTestStore(state);
    const gameModeRef = { current: 'classic' };
    const placedTimesRef = { current: [] };
    const { container } = renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    expect(container.querySelectorAll('.cell').length).toBe(200);
  });
});

describe('GameView component', () => {
  it('should render game layout', () => {
    const state = makeFullState();
    const store = createTestStore(state);
    const { container } = renderWithProviders(<GameView />, { store });
    expect(container.querySelector('.game-container')).toBeTruthy();
  });

  it('should show score panel', () => {
    const state = makeFullState();
    // useGameEngine resets score/lines to 0 when isPlaying, so test the stopped state
    state.game.isPlaying = false;
    const store = createTestStore(state);
    renderWithProviders(<GameView />, { store });
    expect(screen.getByText('Score')).toBeTruthy();
    expect(screen.getByText('Lines: 5')).toBeTruthy();
  });

  it('should show next piece', () => {
    const state = makeFullState();
    const store = createTestStore(state);
    renderWithProviders(<GameView />, { store });
    expect(screen.getByText('Next')).toBeTruthy();
  });

  it('should show play again button when game over as host', () => {
    const state = makeFullState();
    state.game.isPlaying = false;
    state.game.gameOver = true;
    state.game.leaderboard = [{ name: 'Alice', score: 500, winner: true }];
    const store = createTestStore(state);
    renderWithProviders(<GameView />, { store });
    expect(screen.getByText('Play Again')).toBeTruthy();
  });

  it('should show waiting message when game over as non-host', () => {
    const state = makeFullState();
    state.game.isPlaying = false;
    state.game.gameOver = true;
    state.game.playerName = 'Bob';
    state.game.gameState.players.push(
      { socketId: 's2', name: 'Bob', isHost: false, isPlaying: false, isEliminated: true, spectrum: Array(10).fill(0), score: 0, linesCleared: 0 }
    );
    const store = createTestStore(state);
    renderWithProviders(<GameView />, { store });
    expect(screen.getByText(/Waiting for host to restart/)).toBeTruthy();
  });
});

describe('Lobby advanced', () => {
  it('should render rooms list', () => {
    const rooms = [{ roomName: 'arena', playerCount: 2, isStarted: false, gameMode: 'classic' }];
    const state = {
      connection: { socket: { emit: jest.fn((e, cb) => { if (e === 'rooms:list' && cb) cb(rooms); }) }, connected: true, error: null },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: { board: Array.from({ length: 20 }, () => Array(10).fill(0)), currentPiece: null, pieceQueue: [], score: 0, lines: 0, pendingPenalty: 0, opponents: {} },
      ui: { roomsList: rooms },
    };
    const store = createTestStore(state);
    renderWithProviders(<Lobby />, { store });
    expect(screen.getByText('arena')).toBeTruthy();
  });

  it('should show error message', () => {
    const state = {
      connection: { socket: null, connected: true, error: 'Name taken' },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: { board: Array.from({ length: 20 }, () => Array(10).fill(0)), currentPiece: null, pieceQueue: [], score: 0, lines: 0, pendingPenalty: 0, opponents: {} },
      ui: { roomsList: [] },
    };
    const store = createTestStore(state);
    renderWithProviders(<Lobby />, { store });
    expect(screen.getByText('Name taken')).toBeTruthy();
  });

  it('should handle room click in list', () => {
    const rooms = [{ roomName: 'clickRoom', playerCount: 1, isStarted: false, gameMode: 'classic' }];
    const state = {
      connection: { socket: { emit: jest.fn((e, cb) => { if (e === 'rooms:list' && cb) cb(rooms); }) }, connected: true, error: null },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: { board: Array.from({ length: 20 }, () => Array(10).fill(0)), currentPiece: null, pieceQueue: [], score: 0, lines: 0, pendingPenalty: 0, opponents: {} },
      ui: { roomsList: rooms },
    };
    const store = createTestStore(state);
    renderWithProviders(<Lobby />, { store });
    const roomItem = screen.getByText('clickRoom');
    fireEvent.click(roomItem.closest('.room-item'));
    expect(screen.getByDisplayValue('clickRoom')).toBeTruthy();
  });

  it('should handle form submission', () => {
    const emitFn = jest.fn((event, data, callback) => {
      if (callback) callback({ success: true });
    });
    const state = {
      connection: { socket: { emit: emitFn }, connected: true, error: null },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: { board: Array.from({ length: 20 }, () => Array(10).fill(0)), currentPiece: null, pieceQueue: [], score: 0, lines: 0, pendingPenalty: 0, opponents: {} },
      ui: { roomsList: [] },
    };
    const store = createTestStore(state);
    renderWithProviders(<Lobby />, { store });
    
    const roomInput = screen.getByPlaceholderText('Room name');
    const nameInput = screen.getByPlaceholderText('Your name');
    fireEvent.change(roomInput, { target: { value: 'myRoom' } });
    fireEvent.change(nameInput, { target: { value: 'myName' } });
    
    const form = roomInput.closest('form');
    fireEvent.submit(form);
    
    expect(emitFn).toHaveBeenCalledWith('join', { room: 'myRoom', playerName: 'myName' }, expect.any(Function));
  });
});
