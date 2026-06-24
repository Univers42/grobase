import { ACTIONS } from '../actions/types';

const initialConnectionState = {
  socket: null,
  connected: false,
  error: null,
};

export const connectionReducer = (state = initialConnectionState, action) => {
  switch (action.type) {
    case ACTIONS.SET_SOCKET:
      return { ...state, socket: action.payload };
    case ACTIONS.SET_CONNECTED:
      return { ...state, connected: action.payload };
    case ACTIONS.SET_ERROR:
      return { ...state, error: action.payload };
    case ACTIONS.CLEAR_ERROR:
      return { ...state, error: null };
    default:
      return state;
  }
};

const initialGameState = {
  room: null,
  playerName: null,
  gameState: null, // Server game state (players, isStarted, etc.)
  isPlaying: false,
  gameMode: 'classic',
  gameOver: false,
  leaderboard: [],
};

export const gameReducer = (state = initialGameState, action) => {
  switch (action.type) {
    case ACTIONS.SET_ROOM:
      return { ...state, room: action.payload };
    case ACTIONS.SET_PLAYER_NAME:
      return { ...state, playerName: action.payload };
    case ACTIONS.SET_GAME_STATE:
      return { ...state, gameState: action.payload };
    case ACTIONS.SET_GAME_MODE:
      return { ...state, gameMode: action.payload };
    case ACTIONS.GAME_STARTED:
      return {
        ...state,
        isPlaying: true,
        gameOver: false,
        gameMode: action.payload.gameMode,
      };
    case ACTIONS.GAME_ENDED:
      return {
        ...state,
        isPlaying: false,
        gameOver: true,
        leaderboard: action.payload.leaderboard,
      };
    case ACTIONS.GAME_RESET:
      return {
        ...state,
        isPlaying: false,
        gameOver: false,
        leaderboard: [],
      };
    default:
      return state;
  }
};

const initialBoardState = {
  board: Array.from({ length: 20 }, () => Array(10).fill(0)),
  currentPiece: null,
  pieceQueue: [],
  seed: 0, // room seed — lets the engine regenerate the shared bag locally
  score: 0,
  lines: 0,
  pendingPenalty: 0,
  opponents: {}, // socketId -> { playerName, spectrum }
};

export const boardReducer = (state = initialBoardState, action) => {
  switch (action.type) {
    case ACTIONS.SET_BOARD:
      return { ...state, board: action.payload };
    case ACTIONS.SET_CURRENT_PIECE:
      return { ...state, currentPiece: action.payload };
    case ACTIONS.SET_PIECE_QUEUE:
      return { ...state, pieceQueue: action.payload };
    case ACTIONS.ADD_SCORE:
      return { ...state, score: state.score + action.payload };
    case ACTIONS.SET_SCORE:
      return { ...state, score: action.payload };
    case ACTIONS.SET_LINES:
      return { ...state, lines: action.payload };
    case ACTIONS.ADD_PENALTY_LINES:
      return { ...state, pendingPenalty: state.pendingPenalty + action.payload };
    case ACTIONS.UPDATE_OPPONENT_SPECTRUM:
      return {
        ...state,
        opponents: {
          ...state.opponents,
          [action.payload.socketId]: {
            playerName: action.payload.playerName,
            spectrum: action.payload.spectrum,
          },
        },
      };
    case ACTIONS.GAME_STARTED:
      return {
        ...initialBoardState,
        pieceQueue: action.payload.pieces,
        seed: action.payload.seed || 0,
      };
    case ACTIONS.GAME_RESET:
      return initialBoardState;
    default:
      return state;
  }
};

const initialUIState = {
  roomsList: [],
};

export const uiReducer = (state = initialUIState, action) => {
  switch (action.type) {
    case ACTIONS.SET_ROOMS_LIST:
      return { ...state, roomsList: action.payload };
    default:
      return state;
  }
};
