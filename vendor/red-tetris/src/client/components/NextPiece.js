import { useMemo } from 'react';
import { useSelector } from 'react-redux';
import { PIECES, COLORS } from '../../common/constants';

/**
 * NextPiece: shows the next piece in the queue.
 * Pure functional component - no `this`.
 */
const NextPiece = () => {
  const pieceQueue = useSelector(state => state.board.pieceQueue);
  const currentPiece = useSelector(state => state.board.currentPiece);

  // Find next piece index
  const nextPieces = useMemo(() => {
    if (!pieceQueue || pieceQueue.length === 0) return [];
    // Get the next 3 pieces after current
    const currentIndex = currentPiece
      ? pieceQueue.findIndex(p => p.type === currentPiece.type && p.index >= (currentPiece.index || 0))
      : 0;
    const startIdx = Math.max(0, currentIndex);
    return pieceQueue.slice(startIdx, startIdx + 3);
  }, [pieceQueue, currentPiece]);

  const renderMiniPiece = (pieceData, idx) => {
    if (!pieceData) return null;
    const piece = PIECES[pieceData.type];
    if (!piece) return null;

    const cells = piece.rotations[0];
    const color = COLORS[piece.color];

    // Create a 4x4 grid
    const grid = Array.from({ length: 4 }, () => Array(4).fill(false));
    cells.forEach(([x, y]) => {
      if (y >= 0 && y < 4 && x >= 0 && x < 4) {
        grid[y][x] = true;
      }
    });

    return (
      <div key={idx} className="next-piece-box">
        {idx === 0 && <h4>Next</h4>}
        <div className="next-piece-grid">
          {grid.map((row, ry) =>
            row.map((filled, rx) => (
              <div
                key={`${ry}-${rx}`}
                className="next-piece-cell"
                style={{
                  background: filled ? color : 'transparent',
                  boxShadow: filled ? `0 0 4px ${color}` : 'none',
                  borderRadius: '2px',
                }}
              />
            ))
          )}
        </div>
      </div>
    );
  };

  return (
    <div>
      {nextPieces.map((piece, idx) => renderMiniPiece(piece, idx))}
    </div>
  );
};

export default NextPiece;
