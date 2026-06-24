import { useSelector } from 'react-redux';

/**
 * Scoreboard: a live ranked table of EVERY player in the session — name, online/
 * out status, score and lines — so a match of 2, 3 or N players is readable at a
 * glance. Your own score comes from the board slice; rivals' from their streamed
 * board frames. Pure functional component - no `this`.
 */
const Scoreboard = () => {
  const gameState = useSelector((state) => state.game.gameState);
  const playerName = useSelector((state) => state.game.playerName);
  const myScore = useSelector((state) => state.board.score);
  const myLines = useSelector((state) => state.board.lines);
  const opponents = useSelector((state) => state.board.opponents);

  const players = gameState?.players || [];
  if (players.length === 0) return null;

  const rows = players
    .map((p) => {
      const isMe = p.name === playerName;
      const opp = opponents[p.socketId] || {};
      return {
        key: p.socketId,
        name: p.name,
        isMe,
        isHost: p.isHost,
        out: p.isEliminated,
        score: isMe ? myScore : (opp.score || 0),
        lines: isMe ? myLines : (opp.lines || 0),
      };
    })
    .sort((a, b) => b.score - a.score);

  return (
    <div className="scoreboard">
      <h4>Players ({players.length})</h4>
      {rows.map((r, i) => (
        <div className="sb-row" key={r.key}>
          <span className="sb-rank">{i + 1}</span>
          <span className="sb-name">
            <span className={`sb-dot ${r.out ? 'out' : 'on'}`} title={r.out ? 'out' : 'online'} />
            {r.name}
            {r.isMe && <span className="sb-you">YOU</span>}
            {r.isHost && <span className="sb-host" title="host">H</span>}
          </span>
          <span className="sb-score">{r.score}</span>
          <span className="sb-lines">{r.lines}L</span>
        </div>
      ))}
    </div>
  );
};

export default Scoreboard;
