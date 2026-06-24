import { useSelector } from 'react-redux';

/**
 * ScorePanel: displays score and lines cleared.
 * Pure functional component - no `this`.
 */
const ScorePanel = () => {
  const score = useSelector(state => state.board.score);
  const lines = useSelector(state => state.board.lines);

  return (
    <div className="score-panel">
      <h4>Score</h4>
      <div className="score-value">{score.toLocaleString()}</div>
      <div className="score-lines">Lines: {lines}</div>
    </div>
  );
};

export default ScorePanel;
