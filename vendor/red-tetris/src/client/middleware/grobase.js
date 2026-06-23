// Grobase realtime game wiring — the replacement for the deleted Socket.IO
// middleware. It owns one RealtimeClient and a GameNet controller that maps
// presence → roster, broadcasts → Redux actions, and runs the (symmetric,
// host-light) game logic: shared-seed start, per-peer garbage penalties, and
// last-standing detection. The controller is stored in `connection.socket` so
// the existing thunks reach it exactly like the old socket.
import { getClient } from '../baas/realtime';
import { currentUserId } from '../baas/session';
import { postGame } from '../baas/game';
import { generate } from '../../common/pieceBag';
import {
  setSocket, setConnected, setRoom, setPlayerName, setGameState, setGameMode,
  gameStarted, gameEnded, gameReset, updateOpponentSpectrum, updateOpponentBoard,
  addPenaltyLines, setRoomsList,
} from '../actions';

const LOBBY = 'tetris/lobby';
const PIECE_BATCH = 1400;
const roomTopic = (slug) => `tetris/room/${slug}`;

/**
 * GameNet is the per-tab multiplayer controller. One instance is created at
 * boot, exposes the socket-shaped API the thunks call (joinRoom, startGame,
 * sendSpectrum…), and translates realtime traffic into store dispatches.
 */
class GameNet {
  constructor(client, store) {
    this.client = client;
    this.store = store;
    this.room = null;
    this.solo = false;
    this.name = null;
    this.mode = 'classic';
    this.started = false;
    this.posted = false;
    this.joinedAt = 0;
    this.eliminated = new Set();
    this.scores = new Map();
    this.members = [];
    client.subscribe(LOBBY, (m) => m.kind === 'presence' && this._onLobby(m.members));
  }

  /** joinRoom enters a multiplayer room: presence + room subscription + lobby ad. */
  joinRoom(room, playerName) {
    this.room = room;
    this.solo = false;
    this.name = playerName;
    this.joinedAt = Date.now();
    this.eliminated.clear();
    this.scores.clear();
    this.client.subscribe(roomTopic(room), (m) => this._onRoom(m));
    this.client.track(roomTopic(room), { name: playerName, joinedAt: this.joinedAt });
    this.client.track(LOBBY, { room, name: playerName, started: false });
    this.store.dispatch(setRoom(room));
    this.store.dispatch(setPlayerName(playerName));
  }

  /** startSolo begins a local single-player game — own seed, no room, no peers. */
  startSolo(playerName, mode = 'classic') {
    this.room = null;
    this.solo = true;
    this.name = playerName;
    this.mode = mode;
    this.started = true;
    this.posted = false;
    const seed = (Date.now() & 0x7fffffff) || 1;
    this.store.dispatch(setRoom('solo'));
    this.store.dispatch(setPlayerName(playerName));
    this.store.dispatch(setGameState({ roomName: 'solo', isStarted: true, gameMode: mode, players: [{ socketId: 'me', name: playerName, isHost: true }] }));
    this.store.dispatch(gameStarted({ pieces: generate(PIECE_BATCH, seed), gameMode: mode, seed }));
  }

  /** startGame starts solo locally, else (host) broadcasts the shared seed. */
  startGame() {
    if (this.solo) return this.startSolo(this.name, this.mode);
    if (!this.room || !this._isHost()) return;
    const seed = (Date.now() & 0x7fffffff) || 1;
    this.client.broadcast(roomTopic(this.room), 'start', { seed, gameMode: this.mode, players: this._roster() });
  }

  setMode(mode) {
    if (this.solo) { this.mode = mode; this.store.dispatch(setGameMode(mode)); return; }
    if (!this.room || !this._isHost()) return;
    this.client.broadcast(roomTopic(this.room), 'mode', { mode });
  }

  reset() {
    if (this.solo) { this.started = false; this.posted = false; this.store.dispatch(gameReset()); return; }
    if (!this.room || !this._isHost()) return;
    this.client.broadcast(roomTopic(this.room), 'reset', {});
  }

  sendSpectrum(spectrum) {
    if (!this.room || !this.started) return;
    this.client.broadcast(roomTopic(this.room), 'spectrum', { from: this._id(), name: this.name, spectrum });
  }

  sendBoard(board) {
    if (!this.room || !this.started) return;
    this.client.broadcast(roomTopic(this.room), 'board', { from: this._id(), name: this.name, board });
  }

  sendLines(linesCleared, score) {
    if (!this.room || !this.started) return;
    this.client.broadcast(roomTopic(this.room), 'lines', { from: this._id(), name: this.name, linesCleared, score });
  }

  /** localGameOver is called by the engine when THIS board tops out. */
  localGameOver(score, lines) {
    if (this.solo) { this._post({ mode: 'solo', score, lines, won: false }); this.store.dispatch(gameEnded({ leaderboard: [{ name: this.name, score, lines, winner: false }] })); return; }
    if (!this.room) return;
    this.scores.set(this._id(), { name: this.name, score });
    this.eliminated.add(this._id());
    this.client.broadcast(roomTopic(this.room), 'over', { from: this._id(), name: this.name, score, lines });
    this._post({ mode: 'multi', score, lines, won: false });
    this._checkEnd();
  }

  fetchRooms() { /* rooms arrive via lobby presence; nothing to pull */ }

  _id() { return this.client.connId || 'me'; }

  _onRoom(m) {
    if (m.kind === 'presence') { this.members = m.members; this._pushState(); this._checkEnd(); return; }
    if (m.kind !== 'broadcast') return;
    const p = m.payload || {};
    if (m.event === 'start') return this._onStart(p);
    if (m.event === 'mode') { this.mode = p.mode; this.store.dispatch(setGameMode(p.mode)); this._pushState(); return; }
    if (m.event === 'reset') return this._onReset();
    if (m.event === 'spectrum') { if (p.from !== this._id()) this.store.dispatch(updateOpponentSpectrum({ socketId: p.from, playerName: p.name, spectrum: p.spectrum })); return; }
    if (m.event === 'board') { if (p.from !== this._id()) this.store.dispatch(updateOpponentBoard({ socketId: p.from, playerName: p.name, board: p.board })); return; }
    if (m.event === 'lines') return this._onLines(p);
    if (m.event === 'over') return this._onOver(p);
  }

  _onStart(p) {
    this.started = true;
    this.posted = false;
    this.mode = p.gameMode || 'classic';
    this.eliminated.clear();
    this.scores.clear();
    this.store.dispatch(gameStarted({ pieces: generate(PIECE_BATCH, p.seed), gameMode: this.mode, seed: p.seed }));
    this._pushState();
  }

  _onReset() {
    this.started = false;
    this.posted = false;
    this.eliminated.clear();
    this.scores.clear();
    this.store.dispatch(gameReset());
    this._pushState();
  }

  _onLines(p) {
    this.scores.set(p.from, { name: p.name, score: p.score });
    if (p.from !== this._id() && p.linesCleared >= 2) this.store.dispatch(addPenaltyLines(p.linesCleared - 1));
  }

  _onOver(p) {
    this.scores.set(p.from, { name: p.name, score: p.score });
    this.eliminated.add(p.from);
    this._pushState();
    this._checkEnd();
  }

  _onLobby(members) {
    const byRoom = new Map();
    members.filter((m) => m.meta && m.meta.room).forEach((m) => {
      const r = byRoom.get(m.meta.room) || { roomName: m.meta.room, playerCount: 0, isStarted: false, gameMode: 'classic' };
      r.playerCount += 1;
      r.isStarted = r.isStarted || !!m.meta.started;
      byRoom.set(m.meta.room, r);
    });
    this.store.dispatch(setRoomsList([...byRoom.values()]));
  }

  _presentIds() { return this.members.map((m) => m.conn_id); }

  _isHost() {
    const host = this._hostId();
    return host === null || host === this._id();
  }

  _hostId() {
    if (this.members.length === 0) return null;
    const sorted = [...this.members].sort((a, b) => (a.meta?.joinedAt || 0) - (b.meta?.joinedAt || 0) || String(a.conn_id).localeCompare(String(b.conn_id)));
    return sorted[0].conn_id;
  }

  _roster() {
    const host = this._hostId();
    return this.members.map((m) => ({
      socketId: m.conn_id,
      name: (m.meta && m.meta.name) || 'player',
      sub: m.user_id || null,
      isHost: m.conn_id === host,
      isEliminated: this.eliminated.has(m.conn_id),
      isPlaying: this.started && !this.eliminated.has(m.conn_id),
    }));
  }

  _pushState() {
    this.store.dispatch(setGameState({ roomName: this.room, isStarted: this.started, gameMode: this.mode, players: this._roster() }));
  }

  _checkEnd() {
    if (!this.started) return;
    const alive = this._presentIds().filter((id) => !this.eliminated.has(id));
    if (alive.length > 1) return;
    this.started = false;
    const winnerId = alive[0] || null;
    if (winnerId === this._id() && !this.posted) {
      const { score, lines } = this.store.getState().board;
      this.scores.set(this._id(), { name: this.name, score });
      this._post({ mode: 'multi', score, lines, won: true });
    }
    this.store.dispatch(gameEnded({ leaderboard: this._leaderboard(winnerId) }));
    this._pushState();
  }

  _leaderboard(winnerId) {
    return [...this.scores.entries()]
      .map(([id, v]) => ({ name: v.name, score: v.score, winner: id === winnerId }))
      .sort((a, b) => b.score - a.score)
      .slice(0, 10);
  }

  _post(r) {
    if (this.posted) return;
    this.posted = true;
    postGame({ ...r, room: this.room }).catch(() => {});
  }
}

/**
 * init wires the RealtimeClient lifecycle to the store and installs the GameNet
 * controller. Keeps the `init(store)` signature the old socket middleware had.
 */
const init = (store) => {
  const client = getClient();
  const net = new GameNet(client, store);
  store.dispatch(setSocket(net));
  client.onState((up) => store.dispatch(setConnected(up)));
  client.track(LOBBY, { room: null, name: currentUserId() ? 'player' : 'guest' });
  return net;
};

export default init;
