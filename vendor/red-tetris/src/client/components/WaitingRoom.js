import { useDispatch, useSelector } from 'react-redux';
import { startGame, resetGame, changeGameMode } from '../actions';
import { GAME_MODES } from '../../common/constants';

/**
 * WaitingRoom: shown after joining a room, before the game starts. Surfaces the
 * LIVE online roster + connection status + the exact URL the other computer must
 * open — so the #1 LAN mistake (each computer opening its own localhost, landing
 * on a different backend) is impossible to miss.
 */
const WaitingRoom = () => {
  const dispatch = useDispatch();
  const gameState = useSelector((state) => state.game.gameState);
  const playerName = useSelector((state) => state.game.playerName);
  const connected = useSelector((state) => state.connection.connected);

  if (!gameState) return null;

  const players = gameState.players || [];
  const currentPlayer = players.find((p) => p.name === playerName);
  const isHost = currentPlayer?.isHost || false;
  const alone = players.length <= 1;

  const host = typeof window !== 'undefined' ? window.location.host : '';
  const isLocal = /^(localhost|127\.|0\.0\.0\.0)/.test(host);
  const shareUrl = `http://${host}`;

  const handleStart = () => dispatch(startGame());
  const handleReset = () => dispatch(resetGame());
  const handleModeChange = (mode) => dispatch(changeGameMode(mode));

  return (
    <div className="waiting-room">
      <h2>Room: {gameState.roomName}</h2>

      <p style={{ margin: '6px 0', fontSize: 14 }}>
        <span style={{ color: connected ? '#39d98a' : '#ffb74d' }}>● </span>
        <b style={{ color: '#fff' }}>{players.length}</b> player{players.length === 1 ? '' : 's'} online
        <span style={{ color: '#8a8aa6' }}> · {connected ? 'connected' : 'connecting…'}</span>
      </p>

      <div className="player-list">
        {players.map((p) => (
          <div key={p.socketId} className="player-item">
            <span>{p.name}</span>
            {p.isHost && <span className="host-badge">HOST</span>}
          </div>
        ))}
      </div>

      {alone && (
        <div style={{ margin: '14px 0', padding: '12px 14px', border: '1px solid #3a3a5c', borderRadius: 10, background: '#15151f', fontSize: 13, lineHeight: 1.5 }}>
          <p style={{ margin: 0, color: '#ffd45e', fontWeight: 700 }}>Waiting for another player to join “{gameState.roomName}”.</p>
          {isLocal ? (
            <p style={{ margin: '6px 0 0', color: '#ff8a8a' }}>
              ⚠ You opened this on <b>{host}</b>. The other computer <b>cannot</b> reach “localhost”.
              Re-open the game on <b>this</b> computer using its Wi-Fi address (e.g. <code>http://192.168.x.x:{(host.split(':')[1]) || '5178'}</code>)
              and share that same address — run <code>make red-tetris-lan</code> to print it.
            </p>
          ) : (
            <p style={{ margin: '6px 0 0', color: '#c7c7e0' }}>
              On the <b>other</b> computer (same Wi-Fi), open this exact URL — the same one, not its own localhost:
              <br /><b style={{ color: '#5fd0e0' }}>{shareUrl}</b>, then join room <b>{gameState.roomName}</b>.
              Only this computer runs the server.
            </p>
          )}
        </div>
      )}

      <div className="mode-selector">
        {Object.entries(GAME_MODES).map(([key, value]) => (
          <button
            key={key}
            className={`mode-btn ${gameState.gameMode === value ? 'active' : ''}`}
            onClick={() => handleModeChange(value)}
          >
            {key.toLowerCase()}
          </button>
        ))}
      </div>
      <button className="btn btn-primary" onClick={handleStart}>
        {alone ? 'Start (solo until someone joins)' : 'Start Game'}
      </button>
      {!isHost && <p style={{ color: '#666', fontSize: '0.8rem', marginTop: 6 }}>{currentPlayer ? 'Any player can start.' : ''}</p>}
    </div>
  );
};

export default WaitingRoom;
