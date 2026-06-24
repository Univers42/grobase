import { useSelector } from 'react-redux';
import { BOARD_HEIGHT, BOARD_WIDTH } from '../../common/constants';

/**
 * OpponentList: shows opponents' spectrum views.
 * A spectrum shows column heights as colored blocks.
 * Pure functional component - no `this`.
 */
const OpponentList = () => {
  const opponents = useSelector(state => state.board.opponents);
  const gameState = useSelector(state => state.game.gameState);
  const playerName = useSelector(state => state.game.playerName);

  const opponentEntries = Object.entries(opponents).filter(
    ([, data]) => data.playerName !== playerName
  );

  // Also show players from game state who haven't sent spectrum yet
  const gameStatePlayers = gameState?.players?.filter(
    p => p.name !== playerName
  ) || [];

  const renderSpectrum = (spectrum, name, isEliminated) => {
    // Build a 20x10 grid from spectrum heights
    const grid = [];
    for (let row = 0; row < BOARD_HEIGHT; row++) {
      for (let col = 0; col < BOARD_WIDTH; col++) {
        const height = spectrum[col] || 0;
        const filled = (BOARD_HEIGHT - row) <= height;
        grid.push(filled);
      }
    }

    return (
      <div className="opponent-card" key={name} style={isEliminated ? { opacity: 0.4 } : {}}>
        <div className="name">
          {name} {isEliminated ? '(OUT)' : ''}
        </div>
        <div className="spectrum-grid">
          {grid.map((filled, i) => (
            <div
              key={i}
              className={`spectrum-cell ${filled ? 'spectrum-cell-filled' : 'spectrum-cell-empty'}`}
            />
          ))}
        </div>
      </div>
    );
  };

  return (
    <div className="opponents-panel">
      {gameStatePlayers.map(player => {
        const opponentData = opponents[player.socketId];
        const spectrum = opponentData?.spectrum || player.spectrum || Array(BOARD_WIDTH).fill(0);
        return renderSpectrum(spectrum, player.name, player.isEliminated);
      })}
      {opponentEntries
        .filter(([socketId]) => !gameStatePlayers.some(p => p.socketId === socketId))
        .map(([socketId, data]) =>
          renderSpectrum(data.spectrum, data.playerName, false)
        )}
    </div>
  );
};

export default OpponentList;
