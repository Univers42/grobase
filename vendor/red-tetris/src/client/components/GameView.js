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
 * GameView: a versus split screen — YOUR board on the left, your rival's live
 * board on the right (both full size), the next-piece/score/controls between.
 * You watch each other play in real time. Pure functional component - no `this`.
 */
const GameView = () => {
  const dispatch = useDispatch();
  const { gameModeRef, placedTimesRef } = useGameEngine();
  const gameOver = useSelector((state) => state.game.gameOver);
  const gameState = useSelector((state) => state.game.gameState);
  const playerName = useSelector((state) => state.game.playerName);
  const leaderboard = useSelector((state) => state.game.leaderboard);

  const currentPlayer = gameState?.players?.find((p) => p.name === playerName);
  const isHost = currentPlayer?.isHost || false;

  const handleRestart = () => {
    dispatch(resetGame());
    setTimeout(() => dispatch(startGame()), 500);
  };

  return (
    <div className="versus">
      <div className="vs-side">
        <div className="vs-label">{playerName || 'you'} <span className="vs-tag">YOU</span></div>
        <Board gameModeRef={gameModeRef} placedTimesRef={placedTimesRef} />
        {gameOver && (
          <div style={{ textAlign: 'center', marginTop: 6 }}>
            {isHost
              ? <button className="btn btn-primary" onClick={handleRestart}>Play Again</button>
              : <p style={{ color: '#888', fontSize: '0.9rem' }}>Waiting for host to restart...</p>}
          </div>
        )}
      </div>

      <div className="vs-center">
        <NextPiece />
        <ScorePanel />
        <ControlsInfo />
        {gameOver && leaderboard.length > 0 && <Leaderboard leaderboard={leaderboard} />}
      </div>

      <div className="vs-side">
        <OpponentList />
      </div>
    </div>
  );
};

export default GameView;
