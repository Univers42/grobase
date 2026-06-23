import { ACTIONS } from './types';

export const setSocket = (socket) => ({
  type: ACTIONS.SET_SOCKET,
  payload: socket,
});

export const setConnected = (connected) => ({
  type: ACTIONS.SET_CONNECTED,
  payload: connected,
});

export const setError = (error) => ({
  type: ACTIONS.SET_ERROR,
  payload: error,
});

export const clearError = () => ({
  type: ACTIONS.CLEAR_ERROR,
});

export const setRoom = (room) => ({
  type: ACTIONS.SET_ROOM,
  payload: room,
});

export const setPlayerName = (name) => ({
  type: ACTIONS.SET_PLAYER_NAME,
  payload: name,
});

export const setGameState = (state) => ({
  type: ACTIONS.SET_GAME_STATE,
  payload: state,
});

export const gameStarted = ({ pieces, gameMode, players }) => ({
  type: ACTIONS.GAME_STARTED,
  payload: { pieces, gameMode, players },
});

export const gameEnded = ({ leaderboard }) => ({
  type: ACTIONS.GAME_ENDED,
  payload: { leaderboard },
});

export const gameReset = () => ({
  type: ACTIONS.GAME_RESET,
});

export const setBoard = (board) => ({
  type: ACTIONS.SET_BOARD,
  payload: board,
});

export const setCurrentPiece = (piece) => ({
  type: ACTIONS.SET_CURRENT_PIECE,
  payload: piece,
});

export const setPieceQueue = (pieces) => ({
  type: ACTIONS.SET_PIECE_QUEUE,
  payload: pieces,
});

export const addScore = (points) => ({
  type: ACTIONS.ADD_SCORE,
  payload: points,
});

export const setScore = (score) => ({
  type: ACTIONS.SET_SCORE,
  payload: score,
});

export const setLines = (lines) => ({
  type: ACTIONS.SET_LINES,
  payload: lines,
});

export const updateOpponentSpectrum = ({ socketId, playerName, spectrum }) => ({
  type: ACTIONS.UPDATE_OPPONENT_SPECTRUM,
  payload: { socketId, playerName, spectrum },
});

export const updateOpponentBoard = ({ socketId, playerName, board }) => ({
  type: ACTIONS.UPDATE_OPPONENT_BOARD,
  payload: { socketId, playerName, board },
});

export const addPenaltyLines = (lines) => ({
  type: ACTIONS.ADD_PENALTY_LINES,
  payload: lines,
});

export const setRoomsList = (rooms) => ({
  type: ACTIONS.SET_ROOMS_LIST,
  payload: rooms,
});

export const setLeaderboard = (leaderboard) => ({
  type: ACTIONS.SET_LEADERBOARD,
  payload: leaderboard,
});

export const setGameMode = (mode) => ({
  type: ACTIONS.SET_GAME_MODE,
  payload: mode,
});

// Thunks — drive the GameNet realtime controller (stored in connection.socket).
export const joinRoom = (room, playerName) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (!socket) return;
  socket.joinRoom(room, playerName);
  dispatch(clearError());
};

export const startSolo = (playerName, mode) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (!socket) return;
  socket.startSolo(playerName, mode);
};

export const startGame = () => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.startGame();
};

export const resetGame = () => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.reset();
};

export const changeGameMode = (mode) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.setMode(mode);
};

export const sendSpectrum = (spectrum) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.sendSpectrum(spectrum);
};

export const sendBoardState = (board) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.sendBoard(board);
};

export const sendLinesCleared = (linesCleared, score) => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.sendLines(linesCleared, score);
};

export const sendGameOver = () => (dispatch, getState) => {
  const { socket } = getState().connection;
  const { score, lines } = getState().board;
  if (socket) socket.localGameOver(score, lines);
};

export const fetchRoomsList = () => (dispatch, getState) => {
  const { socket } = getState().connection;
  if (socket) socket.fetchRooms();
};
