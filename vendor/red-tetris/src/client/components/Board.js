import { useMemo } from 'react';
import { useSelector } from 'react-redux';
import { COLORS, PIECES, BOARD_HEIGHT, BOARD_WIDTH, GAME_MODES } from '../../common/constants';
import { getPieceCells, getHardDropY } from '../../common/gameLogic';

/**
 * Board component: renders the Tetris playing field.
 * Uses CSS Grid (no tables, no canvas, no SVG).
 * Pure functional - no `this`.
 */
const Board = ({ gameModeRef, placedTimesRef }) => {
  const board = useSelector(state => state.board.board);
  const currentPiece = useSelector(state => state.board.currentPiece);
  const gameMode = useSelector(state => state.game.gameMode);
  const isPlaying = useSelector(state => state.game.isPlaying);
  const gameOver = useSelector(state => state.game.gameOver);

  // Build the display grid with current piece and ghost
  const displayGrid = useMemo(() => {
    const grid = board.map(row => [...row]);

    if (currentPiece && isPlaying) {
      // Draw ghost piece
      const ghostY = getHardDropY(
        board,
        currentPiece.type,
        currentPiece.rotation,
        currentPiece.x,
        currentPiece.y
      );
      const ghostCells = getPieceCells(
        currentPiece.type,
        currentPiece.rotation,
        currentPiece.x,
        ghostY
      );
      ghostCells.forEach(([cx, cy]) => {
        if (cy >= 0 && cy < BOARD_HEIGHT && cx >= 0 && cx < BOARD_WIDTH && grid[cy][cx] === 0) {
          grid[cy][cx] = 9; // Ghost color
        }
      });

      // Draw current piece
      const pieceCells = getPieceCells(
        currentPiece.type,
        currentPiece.rotation,
        currentPiece.x,
        currentPiece.y
      );
      const color = PIECES[currentPiece.type].color;
      pieceCells.forEach(([cx, cy]) => {
        if (cy >= 0 && cy < BOARD_HEIGHT && cx >= 0 && cx < BOARD_WIDTH) {
          grid[cy][cx] = color;
        }
      });
    }

    return grid;
  }, [board, currentPiece, isPlaying]);

  // In invisible mode, recently placed cells fade after 2 seconds
  const now = Date.now();

  const getCellStyle = (colorValue, row, col) => {
    if (colorValue === 0) return { background: 'rgba(255,255,255,0.02)' };
    if (colorValue === 9) return {
      background: 'rgba(255,255,255,0.08)',
      border: '1px dashed rgba(255,255,255,0.15)',
    };

    const baseColor = COLORS[colorValue] || COLORS[0];

    // Invisible mode: hide placed cells after 2 seconds
    if (gameMode === GAME_MODES.INVISIBLE && colorValue !== 8) {
      // Current piece cells are always visible (handled by checking if it's the active piece)
      // For placed cells, check if they're "old"
      if (currentPiece) {
        const pieceCells = getPieceCells(
          currentPiece.type,
          currentPiece.rotation,
          currentPiece.x,
          currentPiece.y
        );
        const isCurrentPieceCell = pieceCells.some(([cx, cy]) => cx === col && cy === row);
        if (isCurrentPieceCell) {
          return {
            background: baseColor,
            boxShadow: `0 0 4px ${baseColor}`,
            borderRadius: '2px',
          };
        }
      }
      // Placed cells: mostly invisible
      return { background: 'rgba(255,255,255,0.02)' };
    }

    return {
      background: baseColor,
      boxShadow: `inset 0 0 3px rgba(255,255,255,0.3), 0 0 4px ${baseColor}`,
      borderRadius: '2px',
    };
  };

  return (
    <div className="board-container">
      <div className="board-grid">
        {displayGrid.map((row, y) =>
          row.map((cell, x) => (
            <div
              key={`${y}-${x}`}
              className="cell"
              style={getCellStyle(cell, y, x)}
            />
          ))
        )}
      </div>
      {gameOver && (
        <div className="game-over-overlay">
          <h2>GAME OVER</h2>
          <p>Waiting for host...</p>
        </div>
      )}
    </div>
  );
};

export default Board;
