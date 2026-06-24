/**
 * Leaderboard: shows top scores.
 * Pure functional component - no `this`.
 */
const Leaderboard = ({ leaderboard }) => {
  if (!leaderboard || leaderboard.length === 0) return null;

  return (
    <div className="leaderboard">
      <h3>Leaderboard</h3>
      {leaderboard.map((entry, idx) => (
        <div
          key={idx}
          className={`leaderboard-row ${entry.winner ? 'winner' : ''}`}
        >
          <span className="rank">#{idx + 1}</span>
          <span className="name">
            {entry.name} {entry.winner ? '★' : ''}
          </span>
          <span className="lb-score">{entry.score?.toLocaleString() || 0}</span>
        </div>
      ))}
    </div>
  );
};

export default Leaderboard;
