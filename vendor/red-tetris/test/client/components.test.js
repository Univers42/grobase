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
import App from '../../src/client/components/App';
import Board from '../../src/client/components/Board';
import Lobby from '../../src/client/components/Lobby';
import WaitingRoom from '../../src/client/components/WaitingRoom';
import ScorePanel from '../../src/client/components/ScorePanel';
import Leaderboard from '../../src/client/components/Leaderboard';
import ControlsInfo from '../../src/client/components/ControlsInfo';
import NextPiece from '../../src/client/components/NextPiece';
import OpponentList from '../../src/client/components/OpponentList';

const createTestStore = (overrides = {}) => {
  const rootReducer = combineReducers({
    connection: connectionReducer,
    game: gameReducer,
    board: boardReducer,
    ui: uiReducer,
  });

  const store = createStore(rootReducer, overrides, applyMiddleware(thunk));
  return store;
};

const renderWithProviders = (ui, { store, route = '/' } = {}) => {
  const testStore = store || createTestStore();
  return render(
    <Provider store={testStore}>
      <MemoryRouter initialEntries={[route]}>
        <Routes>
          <Route path="/:room/:playerName" element={ui} />
          <Route path="/*" element={ui} />
        </Routes>
      </MemoryRouter>
    </Provider>
  );
};

describe('App Component', () => {
  it('should render app title', () => {
    renderWithProviders(<App />);
    expect(screen.getByText('RED TETRIS')).toBeTruthy();
  });

  it('should render subtitle', () => {
    renderWithProviders(<App />);
    expect(screen.getByText(/Multiplayer Tetris/)).toBeTruthy();
  });

  it('should show lobby when no room is set', () => {
    renderWithProviders(<App />);
    expect(screen.getByPlaceholderText('Room name')).toBeTruthy();
  });
});

describe('Board Component', () => {
  it('should render 200 cells (20x10)', () => {
    const store = createTestStore();
    const gameModeRef = { current: 'classic' };
    const placedTimesRef = { current: [] };
    const { container } = renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    const cells = container.querySelectorAll('.cell');
    expect(cells.length).toBe(200);
  });

  it('should show game over overlay when game is over', () => {
    const store = createTestStore({
      connection: { socket: null, connected: false, error: null },
      game: {
        room: 'test',
        playerName: 'Alice',
        gameState: null,
        isPlaying: false,
        gameMode: 'classic',
        gameOver: true,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    const gameModeRef = { current: 'classic' };
    const placedTimesRef = { current: [] };
    renderWithProviders(
      <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />,
      { store }
    );
    expect(screen.getByText('GAME OVER')).toBeTruthy();
  });
});

describe('Lobby Component', () => {
  it('should render input fields', () => {
    renderWithProviders(<Lobby />);
    expect(screen.getByPlaceholderText('Room name')).toBeTruthy();
    expect(screen.getByPlaceholderText('Your name')).toBeTruthy();
  });

  it('should render join button', () => {
    renderWithProviders(<Lobby />);
    expect(screen.getByText('Join Game')).toBeTruthy();
  });

  it('should show connecting message when not connected', () => {
    renderWithProviders(<Lobby />);
    expect(screen.getByText('Connecting to server...')).toBeTruthy();
  });

  it('should disable join button when fields are empty', () => {
    renderWithProviders(<Lobby />);
    const btn = screen.getByText('Join Game');
    expect(btn.disabled).toBe(true);
  });

  it('should render with initial values from URL', () => {
    renderWithProviders(
      <Lobby initialRoom="testRoom" initialPlayer="Alice" />,
      { route: '/testRoom/Alice' }
    );
    expect(screen.getByDisplayValue('testRoom')).toBeTruthy();
    expect(screen.getByDisplayValue('Alice')).toBeTruthy();
  });
});

describe('WaitingRoom Component', () => {
  it('should render room name when game state exists', () => {
    const store = createTestStore({
      connection: { socket: null, connected: true, error: null },
      game: {
        room: 'testRoom',
        playerName: 'Alice',
        gameState: {
          roomName: 'testRoom',
          isStarted: false,
          gameMode: 'classic',
          players: [
            { socketId: 's1', name: 'Alice', isHost: true, isPlaying: false },
          ],
          leaderboard: [],
        },
        isPlaying: false,
        gameMode: 'classic',
        gameOver: false,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<WaitingRoom />, { store });
    expect(screen.getByText('Room: testRoom')).toBeTruthy();
  });

  it('should show start button for host', () => {
    const store = createTestStore({
      connection: { socket: null, connected: true, error: null },
      game: {
        room: 'testRoom',
        playerName: 'Alice',
        gameState: {
          roomName: 'testRoom',
          isStarted: false,
          gameMode: 'classic',
          players: [
            { socketId: 's1', name: 'Alice', isHost: true, isPlaying: false },
          ],
          leaderboard: [],
        },
        isPlaying: false,
        gameMode: 'classic',
        gameOver: false,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<WaitingRoom />, { store });
    expect(screen.getByText('Start Game')).toBeTruthy();
  });

  it('should show waiting message for non-host', () => {
    const store = createTestStore({
      connection: { socket: null, connected: true, error: null },
      game: {
        room: 'testRoom',
        playerName: 'Bob',
        gameState: {
          roomName: 'testRoom',
          isStarted: false,
          gameMode: 'classic',
          players: [
            { socketId: 's1', name: 'Alice', isHost: true, isPlaying: false },
            { socketId: 's2', name: 'Bob', isHost: false, isPlaying: false },
          ],
          leaderboard: [],
        },
        isPlaying: false,
        gameMode: 'classic',
        gameOver: false,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<WaitingRoom />, { store });
    expect(screen.getByText(/Waiting for host/)).toBeTruthy();
  });

  it('should return null when no game state', () => {
    const { container } = renderWithProviders(<WaitingRoom />);
    expect(container.querySelector('.waiting-room')).toBeNull();
  });
});

describe('ScorePanel Component', () => {
  it('should display score and lines', () => {
    const store = createTestStore({
      connection: { socket: null, connected: false, error: null },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 1500,
        lines: 12,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<ScorePanel />, { store });
    expect(screen.getByText('1,500')).toBeTruthy();
    expect(screen.getByText('Lines: 12')).toBeTruthy();
  });
});

describe('Leaderboard Component', () => {
  it('should render leaderboard entries', () => {
    const lb = [
      { name: 'Alice', score: 1000, winner: true },
      { name: 'Bob', score: 500 },
    ];
    renderWithProviders(<Leaderboard leaderboard={lb} />);
    expect(screen.getByText(/Alice/)).toBeTruthy();
    expect(screen.getByText(/Bob/)).toBeTruthy();
  });

  it('should return null for empty leaderboard', () => {
    const { container } = renderWithProviders(<Leaderboard leaderboard={[]} />);
    expect(container.querySelector('.leaderboard')).toBeNull();
  });

  it('should return null for null leaderboard', () => {
    const { container } = renderWithProviders(<Leaderboard leaderboard={null} />);
    expect(container.querySelector('.leaderboard')).toBeNull();
  });
});

describe('ControlsInfo Component', () => {
  it('should render control descriptions', () => {
    renderWithProviders(<ControlsInfo />);
    expect(screen.getByText('Move')).toBeTruthy();
    expect(screen.getByText('Rotate')).toBeTruthy();
    expect(screen.getByText('Soft drop')).toBeTruthy();
    expect(screen.getByText('Hard drop')).toBeTruthy();
  });
});

describe('NextPiece Component', () => {
  it('should render without pieces', () => {
    const { container } = renderWithProviders(<NextPiece />);
    expect(container).toBeTruthy();
  });

  it('should render with piece queue', () => {
    const store = createTestStore({
      connection: { socket: null, connected: false, error: null },
      game: { room: null, playerName: null, gameState: null, isPlaying: false, gameMode: 'classic', gameOver: false, leaderboard: [] },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [
          { type: 'T', index: 0 },
          { type: 'I', index: 1 },
          { type: 'O', index: 2 },
        ],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<NextPiece />, { store });
    expect(screen.getByText('Next')).toBeTruthy();
  });
});

describe('OpponentList Component', () => {
  it('should render opponents', () => {
    const store = createTestStore({
      connection: { socket: null, connected: false, error: null },
      game: {
        room: 'test',
        playerName: 'Alice',
        gameState: {
          roomName: 'test',
          players: [
            { socketId: 's1', name: 'Alice', isHost: true, spectrum: Array(10).fill(0), isEliminated: false },
            { socketId: 's2', name: 'Bob', isHost: false, spectrum: [5, 3, 0, 0, 0, 0, 0, 0, 2, 1], isEliminated: false },
          ],
        },
        isPlaying: true,
        gameMode: 'classic',
        gameOver: false,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<OpponentList />, { store });
    expect(screen.getByText('Bob')).toBeTruthy();
  });

  it('should show eliminated status', () => {
    const store = createTestStore({
      connection: { socket: null, connected: false, error: null },
      game: {
        room: 'test',
        playerName: 'Alice',
        gameState: {
          roomName: 'test',
          players: [
            { socketId: 's1', name: 'Alice', isHost: true, spectrum: Array(10).fill(0), isEliminated: false },
            { socketId: 's2', name: 'Bob', isHost: false, spectrum: Array(10).fill(0), isEliminated: true },
          ],
        },
        isPlaying: true,
        gameMode: 'classic',
        gameOver: false,
        leaderboard: [],
      },
      board: {
        board: Array.from({ length: 20 }, () => Array(10).fill(0)),
        currentPiece: null,
        pieceQueue: [],
        score: 0,
        lines: 0,
        pendingPenalty: 0,
        opponents: {},
      },
      ui: { roomsList: [] },
    });
    renderWithProviders(<OpponentList />, { store });
    expect(screen.getByText(/OUT/)).toBeTruthy();
  });
});
