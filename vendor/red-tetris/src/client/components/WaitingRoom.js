import { useDispatch, useSelector } from 'react-redux';
import { startGame, resetGame, changeGameMode } from '../actions';
import { GAME_MODES } from '../../common/constants';

/**
 * WaitingRoom: shown after joining a room, before game starts.
 * Host can start game and change mode.
 * Pure functional component - no `this`.
 */
const WaitingRoom = () => {
  const dispatch = useDispatch();
  const gameState = useSelector(state => state.game.gameState);
  const playerName = useSelector(state => state.game.playerName);

  if (!gameState) return null;

  const currentPlayer = gameState.players.find(p => p.name === playerName);
  const isHost = currentPlayer?.isHost || false;

  const handleStart = () => dispatch(startGame());
  const handleReset = () => dispatch(resetGame());
  const handleModeChange = (mode) => dispatch(changeGameMode(mode));

  return (
    <div className="waiting-room">
      <h2>Room: {gameState.roomName}</h2>

      <div className="player-list">
        {gameState.players.map(p => (
          <div key={p.socketId} className="player-item">
            <span>{p.name}</span>
            {p.isHost && <span className="host-badge">HOST</span>}
          </div>
        ))}
      </div>

      {isHost && (
        <>
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
            Start Game
          </button>
        </>
      )}

      {!isHost && (
        <p style={{ color: '#888' }}>Waiting for host to start...</p>
      )}
    </div>
  );
};

export default WaitingRoom;
