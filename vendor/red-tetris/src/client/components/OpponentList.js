import { useSelector } from 'react-redux';
import { BOARD_HEIGHT, BOARD_WIDTH, COLORS } from '../../common/constants';

/**
 * OpponentList: a live mini-view of every opponent's board. When an opponent is
 * streaming their board (the normal case during play) you watch their pieces
 * fall and land in real time; before the first frame arrives it falls back to
 * the lightweight height spectrum. Pure functional component - no `this`.
 */
const OpponentList = () => {
  const opponents = useSelector((state) => state.board.opponents);
  const gameState = useSelector((state) => state.game.gameState);
  const playerName = useSelector((state) => state.game.playerName);

  const others = (gameState?.players || []).filter((p) => p.name !== playerName);

  const cell = (value, key) => (
    <div
      key={key}
      className="spectrum-cell"
      style={{ background: value ? (COLORS[value] || '#888') : 'rgba(255,255,255,0.04)' }}
    />
  );

  const renderLiveBoard = (board, name, isEliminated) => (
    <div className="opponent-card" key={name} style={isEliminated ? { opacity: 0.4 } : {}}>
      <div className="name">{name} {isEliminated ? '(OUT)' : ''}</div>
      <div className="spectrum-grid">
        {board.map((row, y) => row.map((v, x) => cell(v, `${y}-${x}`)))}
      </div>
    </div>
  );

  const renderSpectrum = (spectrum, name, isEliminated) => {
    const cells = [];
    for (let row = 0; row < BOARD_HEIGHT; row += 1) {
      for (let col = 0; col < BOARD_WIDTH; col += 1) {
        const filled = (BOARD_HEIGHT - row) <= (spectrum[col] || 0);
        cells.push(cell(filled ? 8 : 0, `${row}-${col}`));
      }
    }
    return (
      <div className="opponent-card" key={name} style={isEliminated ? { opacity: 0.4 } : {}}>
        <div className="name">{name} {isEliminated ? '(OUT)' : ''}</div>
        <div className="spectrum-grid">{cells}</div>
      </div>
    );
  };

  return (
    <div className="opponents-panel">
      {others.map((player) => {
        const data = opponents[player.socketId] || {};
        if (Array.isArray(data.board)) return renderLiveBoard(data.board, player.name, player.isEliminated);
        return renderSpectrum(data.spectrum || Array(BOARD_WIDTH).fill(0), player.name, player.isEliminated);
      })}
    </div>
  );
};

export default OpponentList;
