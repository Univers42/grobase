/**
 * @jest-environment jsdom
 */
import { ACTIONS } from '../../src/client/actions/types';
import * as actions from '../../src/client/actions';

describe('Action creators', () => {
  describe('Connection actions', () => {
    it('setSocket should create SET_SOCKET action', () => {
      const socket = { id: 'test' };
      expect(actions.setSocket(socket)).toEqual({
        type: ACTIONS.SET_SOCKET,
        payload: socket,
      });
    });

    it('setConnected should create SET_CONNECTED action', () => {
      expect(actions.setConnected(true)).toEqual({
        type: ACTIONS.SET_CONNECTED,
        payload: true,
      });
    });

    it('setError should create SET_ERROR action', () => {
      expect(actions.setError('error')).toEqual({
        type: ACTIONS.SET_ERROR,
        payload: 'error',
      });
    });

    it('clearError should create CLEAR_ERROR action', () => {
      expect(actions.clearError()).toEqual({
        type: ACTIONS.CLEAR_ERROR,
      });
    });
  });

  describe('Game actions', () => {
    it('setRoom should create SET_ROOM action', () => {
      expect(actions.setRoom('room1')).toEqual({
        type: ACTIONS.SET_ROOM,
        payload: 'room1',
      });
    });

    it('setPlayerName should create SET_PLAYER_NAME action', () => {
      expect(actions.setPlayerName('Alice')).toEqual({
        type: ACTIONS.SET_PLAYER_NAME,
        payload: 'Alice',
      });
    });

    it('setGameState should create SET_GAME_STATE action', () => {
      const state = { isStarted: true };
      expect(actions.setGameState(state)).toEqual({
        type: ACTIONS.SET_GAME_STATE,
        payload: state,
      });
    });

    it('gameStarted should create GAME_STARTED action', () => {
      const payload = { pieces: [], gameMode: 'classic', players: [] };
      expect(actions.gameStarted(payload)).toEqual({
        type: ACTIONS.GAME_STARTED,
        payload,
      });
    });

    it('gameEnded should create GAME_ENDED action', () => {
      const payload = { leaderboard: [] };
      expect(actions.gameEnded(payload)).toEqual({
        type: ACTIONS.GAME_ENDED,
        payload,
      });
    });

    it('gameReset should create GAME_RESET action', () => {
      expect(actions.gameReset()).toEqual({
        type: ACTIONS.GAME_RESET,
      });
    });

    it('setGameMode should create SET_GAME_MODE action', () => {
      expect(actions.setGameMode('gravity')).toEqual({
        type: ACTIONS.SET_GAME_MODE,
        payload: 'gravity',
      });
    });
  });

  describe('Board actions', () => {
    it('setBoard should create SET_BOARD action', () => {
      const board = [[0]];
      expect(actions.setBoard(board)).toEqual({
        type: ACTIONS.SET_BOARD,
        payload: board,
      });
    });

    it('setCurrentPiece should create SET_CURRENT_PIECE action', () => {
      const piece = { type: 'T' };
      expect(actions.setCurrentPiece(piece)).toEqual({
        type: ACTIONS.SET_CURRENT_PIECE,
        payload: piece,
      });
    });

    it('setPieceQueue should create SET_PIECE_QUEUE action', () => {
      const queue = [{ type: 'I', index: 0 }];
      expect(actions.setPieceQueue(queue)).toEqual({
        type: ACTIONS.SET_PIECE_QUEUE,
        payload: queue,
      });
    });

    it('addScore should create ADD_SCORE action', () => {
      expect(actions.addScore(100)).toEqual({
        type: ACTIONS.ADD_SCORE,
        payload: 100,
      });
    });

    it('setScore should create SET_SCORE action', () => {
      expect(actions.setScore(500)).toEqual({
        type: ACTIONS.SET_SCORE,
        payload: 500,
      });
    });

    it('setLines should create SET_LINES action', () => {
      expect(actions.setLines(10)).toEqual({
        type: ACTIONS.SET_LINES,
        payload: 10,
      });
    });

    it('addPenaltyLines should create ADD_PENALTY_LINES action', () => {
      expect(actions.addPenaltyLines(3)).toEqual({
        type: ACTIONS.ADD_PENALTY_LINES,
        payload: 3,
      });
    });

    it('updateOpponentSpectrum should create UPDATE_OPPONENT_SPECTRUM action', () => {
      const data = { socketId: 's1', playerName: 'Bob', spectrum: [] };
      expect(actions.updateOpponentSpectrum(data)).toEqual({
        type: ACTIONS.UPDATE_OPPONENT_SPECTRUM,
        payload: data,
      });
    });
  });

  describe('UI actions', () => {
    it('setRoomsList should create SET_ROOMS_LIST action', () => {
      const rooms = [{ roomName: 'test' }];
      expect(actions.setRoomsList(rooms)).toEqual({
        type: ACTIONS.SET_ROOMS_LIST,
        payload: rooms,
      });
    });

    it('setLeaderboard should create SET_LEADERBOARD action', () => {
      const lb = [{ name: 'A', score: 100 }];
      expect(actions.setLeaderboard(lb)).toEqual({
        type: ACTIONS.SET_LEADERBOARD,
        payload: lb,
      });
    });
  });

  describe('Thunk actions', () => {
    const createMockStore = (state = {}) => {
      const dispatched = [];
      return {
        dispatch: (action) => {
          if (typeof action === 'function') {
            return action(
              (a) => dispatched.push(a),
              () => state
            );
          }
          dispatched.push(action);
        },
        getState: () => state,
        dispatched,
      };
    };

    it('joinRoom should emit join event', () => {
      const emitCalls = [];
      const mockSocket = {
        emit: (event, data, callback) => {
          emitCalls.push({ event, data });
          callback && callback({ success: true });
        },
      };
      const store = createMockStore({
        connection: { socket: mockSocket },
      });

      const thunk = actions.joinRoom('room1', 'Alice');
      thunk(store.dispatch, store.getState);
      expect(emitCalls[0].event).toBe('join');
      expect(emitCalls[0].data).toEqual({ room: 'room1', playerName: 'Alice' });
    });

    it('joinRoom should dispatch error on failure', () => {
      const dispatched = [];
      const mockSocket = {
        emit: (event, data, callback) => {
          callback({ error: 'Name taken' });
        },
      };
      const getState = () => ({ connection: { socket: mockSocket } });
      const dispatch = (a) => dispatched.push(a);

      const thunk = actions.joinRoom('room1', 'Alice');
      thunk(dispatch, getState);
      expect(dispatched.some(a => a.type === ACTIONS.SET_ERROR)).toBe(true);
    });

    it('joinRoom should do nothing without socket', () => {
      const dispatched = [];
      const getState = () => ({ connection: { socket: null } });
      const dispatch = (a) => dispatched.push(a);

      const thunk = actions.joinRoom('room1', 'Alice');
      thunk(dispatch, getState);
      expect(dispatched.length).toBe(0);
    });

    it('startGame should emit game:start', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e) => emitCalls.push(e) };
      const getState = () => ({ connection: { socket: mockSocket } });
      const dispatch = () => {};

      const thunk = actions.startGame();
      thunk(dispatch, getState);
      expect(emitCalls).toContain('game:start');
    });

    it('resetGame should emit game:reset', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e) => emitCalls.push(e) };
      const getState = () => ({ connection: { socket: mockSocket } });
      const dispatch = () => {};

      const thunk = actions.resetGame();
      thunk(dispatch, getState);
      expect(emitCalls).toContain('game:reset');
    });

    it('changeGameMode should emit game:mode', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e, d) => emitCalls.push({ event: e, data: d }) };
      const getState = () => ({ connection: { socket: mockSocket } });
      const dispatch = () => {};

      const thunk = actions.changeGameMode('invisible');
      thunk(dispatch, getState);
      expect(emitCalls[0].event).toBe('game:mode');
      expect(emitCalls[0].data.mode).toBe('invisible');
    });

    it('sendSpectrum should emit board:spectrum', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e, d) => emitCalls.push({ event: e, data: d }) };
      const getState = () => ({ connection: { socket: mockSocket } });

      const thunk = actions.sendSpectrum([1, 2, 3]);
      thunk(() => {}, getState);
      expect(emitCalls[0].event).toBe('board:spectrum');
    });

    it('sendLinesCleared should emit board:lines', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e, d) => emitCalls.push({ event: e, data: d }) };
      const getState = () => ({ connection: { socket: mockSocket } });

      const thunk = actions.sendLinesCleared(2, 300);
      thunk(() => {}, getState);
      expect(emitCalls[0].event).toBe('board:lines');
    });

    it('sendGameOver should emit game:over', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e) => emitCalls.push(e) };
      const getState = () => ({ connection: { socket: mockSocket } });

      const thunk = actions.sendGameOver();
      thunk(() => {}, getState);
      expect(emitCalls).toContain('game:over');
    });

    it('requestPieces should emit pieces:request', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e, d) => emitCalls.push({ event: e, data: d }) };
      const getState = () => ({ connection: { socket: mockSocket } });

      const thunk = actions.requestPieces(10);
      thunk(() => {}, getState);
      expect(emitCalls[0].event).toBe('pieces:request');
      expect(emitCalls[0].data.fromIndex).toBe(10);
    });

    it('fetchRoomsList should emit rooms:list', () => {
      const emitCalls = [];
      const mockSocket = { emit: (e, cb) => { emitCalls.push(e); cb([]); } };
      const getState = () => ({ connection: { socket: mockSocket } });
      const dispatched = [];
      const dispatch = (a) => dispatched.push(a);

      const thunk = actions.fetchRoomsList();
      thunk(dispatch, getState);
      expect(emitCalls).toContain('rooms:list');
    });
  });
});
