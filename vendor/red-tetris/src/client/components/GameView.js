import { useSelector, useDispatch } from 'react-redux';
import useGameEngine from '../hooks/useGameEngine';
import Board from './Board';
import NextPiece from './NextPiece';
import ScorePanel from './ScorePanel';
import OpponentList from './OpponentList';
import Leaderboard from './Leaderboard';
import ControlsInfo from './ControlsInfo';
import { resetGame, startGame } from '../actions';

/**
 * GameView: the main game screen with board, sidebar, and opponents.
 * Pure functional component - no `this`.
 */
const GameView = () => {
  const dispatch = useDispatch();
  const { gameModeRef, placedTimesRef } = useGameEngine();
  const isPlaying = useSelector(state => state.game.isPlaying);
  const gameOver = useSelector(state => state.game.gameOver);
  const gameState = useSelector(state => state.game.gameState);
  const playerName = useSelector(state => state.game.playerName);
  const leaderboard = useSelector(state => state.game.leaderboard);

  const currentPlayer = gameState?.players?.find(p => p.name === playerName);
  const isHost = currentPlayer?.isHost || false;

  const handleRestart = () => {
    dispatch(resetGame());
    setTimeout(() => dispatch(startGame()), 500);
  };

  return (
    <div className="game-container">
      <div className="game-sidebar">
        <OpponentList />
      </div>

      <div className="game-main">
        <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />

        {gameOver && (
          <div style={{ textAlign: 'center', marginTop: 10 }}>
            {isHost && (
              <button className="btn btn-primary" onClick={handleRestart}>
                Play Again
              </button>
            )}
            {!isHost && (
              <p style={{ color: '#888', fontSize: '0.9rem' }}>
                Waiting for host to restart...
              </p>
            )}
          </div>
        )}
      </div>

      <div className="game-sidebar">
        <NextPiece />
        <ScorePanel />
        <ControlsInfo />
        {gameOver && leaderboard.length > 0 && (
          <Leaderboard leaderboard={leaderboard} />
        )}
      </div>
    </div>
  );
};

export default GameView;
