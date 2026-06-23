import { useState, useEffect } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { joinRoom, fetchRoomsList, startSolo } from '../actions';
import { accessToken, jwtClaims } from '../baas/session';

/** defaultName derives a display name from the signed-in user's email local-part. */
function defaultName() {
  const email = jwtClaims(accessToken()).email || '';
  return email.split('@')[0] || '';
}

/**
 * Lobby: pick single-player (solo) or join a multiplayer room.
 * Pure functional component - no `this`.
 */
const Lobby = ({ initialRoom, initialPlayer }) => {
  const dispatch = useDispatch();
  const error = useSelector(state => state.connection.error);
  const roomsList = useSelector(state => state.ui.roomsList);
  const connected = useSelector(state => state.connection.connected);

  const [room, setRoom] = useState(initialRoom || '');
  const [playerName, setPlayerName] = useState(initialPlayer || defaultName());

  useEffect(() => {
    if (connected) {
      dispatch(fetchRoomsList());
      const interval = setInterval(() => dispatch(fetchRoomsList()), 5000);
      return () => clearInterval(interval);
    }
    return undefined;
  }, [connected, dispatch]);

  // Auto-join if URL params provided
  useEffect(() => {
    if (initialRoom && initialPlayer && connected) {
      dispatch(joinRoom(initialRoom, initialPlayer));
    }
  }, [initialRoom, initialPlayer, connected, dispatch]);

  const handleSubmit = (e) => {
    e.preventDefault();
    if (room.trim() && playerName.trim()) {
      dispatch(joinRoom(room.trim(), playerName.trim()));
      // Update URL
      window.history.pushState({}, '', `/${room.trim()}/${playerName.trim()}`);
    }
  };

  const handleRoomClick = (roomName) => {
    setRoom(roomName);
  };

  const handleSolo = () => dispatch(startSolo(playerName.trim() || 'you', 'classic'));

  return (
    <div className="lobby">
      <div className="lobby-mode" style={{ textAlign: 'center', marginBottom: 20 }}>
        <button type="button" className="btn btn-primary" onClick={handleSolo} style={{ fontSize: '1.1rem', padding: '12px 28px' }}>
          ▶ Play Solo
        </button>
        <p style={{ color: '#888', margin: '8px 0 0', fontSize: '0.85rem' }}>single-player — your score is saved to the leaderboard</p>
      </div>

      <div style={{ textAlign: 'center', color: '#555', margin: '4px 0 14px', fontSize: '0.8rem', letterSpacing: 2 }}>— OR PLAY ONLINE —</div>

      <form className="lobby-form" onSubmit={handleSubmit}>
        <input
          type="text"
          placeholder="Room name"
          value={room}
          onChange={(e) => setRoom(e.target.value)}
          autoFocus
        />
        <input
          type="text"
          placeholder="Your name"
          value={playerName}
          onChange={(e) => setPlayerName(e.target.value)}
        />
        <button
          type="submit"
          className="btn btn-primary"
          disabled={!room.trim() || !playerName.trim() || !connected}
        >
          Join Game
        </button>
        {error && <div className="error-message">{error}</div>}
        {!connected && <div className="error-message">Connecting to server...</div>}
      </form>

      {roomsList.length > 0 && (
        <div className="rooms-list">
          <h3>Active Rooms</h3>
          {roomsList.map(r => (
            <div
              key={r.roomName}
              className="room-item"
              onClick={() => handleRoomClick(r.roomName)}
            >
              <span className="room-name">{r.roomName}</span>
              <span className="room-status">
                {r.playerCount} player{r.playerCount !== 1 ? 's' : ''}
                {r.isStarted ? ' (in progress)' : ''}
                {' · '}{r.gameMode}
              </span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
};

export default Lobby;
