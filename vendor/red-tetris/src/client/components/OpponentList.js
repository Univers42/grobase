import { useSelector } from 'react-redux';
import { BOARD_HEIGHT, BOARD_WIDTH, COLORS } from '../../common/constants';

/**
 * OpponentList: each rival's board rendered LARGE, side-by-side with yours, so
 * it reads like a real versus match — you watch their pieces fall and land in
 * real time (streamed over the realtime gateway). Falls back to the height
 * spectrum until the first board frame arrives. Pure functional - no `this`.
 */
const OpponentList = () => {
  const opponents = useSelector((state) => state.board.opponents);
  const gameState = useSelector((state) => state.game.gameState);
  const playerName = useSelector((state) => state.game.playerName);

  const others = (gameState?.players || []).filter((p) => p.name !== playerName);

  const cell = (value, key) => (
    <div key={key} className="cell" style={{ background: value ? (COLORS[value] || '#888') : 'rgba(255,255,255,0.03)' }} />
  );

  const liveBoard = (grid) => <div className="vs-board-grid">{grid.map((row, y) => row.map((v, x) => cell(v, `${y}-${x}`)))}</div>;

  const spectrumBoard = (spectrum) => {
    const cells = [];
    for (let row = 0; row < BOARD_HEIGHT; row += 1) {
      for (let col = 0; col < BOARD_WIDTH; col += 1) {
        cells.push(cell((BOARD_HEIGHT - row) <= (spectrum[col] || 0) ? 8 : 0, `${row}-${col}`));
      }
    }
    return <div className="vs-board-grid">{cells}</div>;
  };

  if (others.length === 0) {
    const room = gameState?.roomName || '';
    const host = typeof window !== 'undefined' ? window.location.host : '';
    const isLocal = /^(localhost|127\.|0\.0\.0\.0)/.test(host);
    return (
      <div className="vs-card">
        <div className="vs-label">rival</div>
        <div className="vs-waiting">
          <div style={{ color: '#ffd45e', fontWeight: 700 }}>No rival in room “{room}” yet.</div>
          {isLocal
            ? <div style={{ marginTop: 10, fontSize: 12, color: '#ff8a8a' }}>You are on <b>localhost</b> — the other PC can’t reach it. Re-open on your Wi-Fi address (run <code>make red-tetris-lan</code>) and share THAT.</div>
            : <div style={{ marginTop: 10, fontSize: 12, color: '#9a9ab6' }}>The other player must open<br /><b style={{ color: '#5fd0e0' }}>http://{host}</b><br />and join the SAME room: <b>{room}</b></div>}
        </div>
      </div>
    );
  }

  return (
    <div className="vs-opp-list">
      {others.map((player) => {
        const data = opponents[player.socketId] || {};
        return (
          <div className="vs-card" key={player.socketId} style={player.isEliminated ? { opacity: 0.4 } : {}}>
            <div className="vs-label">{player.name} {player.isEliminated ? '· OUT' : ''}</div>
            {Array.isArray(data.board) ? liveBoard(data.board) : spectrumBoard(data.spectrum || Array(BOARD_WIDTH).fill(0))}
          </div>
        );
      })}
    </div>
  );
};

export default OpponentList;
