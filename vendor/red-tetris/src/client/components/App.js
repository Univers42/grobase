import { useEffect, useMemo } from 'react';
import { useSelector } from 'react-redux';
import { useParams } from 'react-router-dom';
import Lobby from './Lobby';
import WaitingRoom from './WaitingRoom';
import GameView from './GameView';
import '../styles/App.css';

/**
 * App: root component. Routes between lobby, waiting room, and game.
 * URL format: /<room>/<playerName>
 * Pure functional component - no `this`.
 */
const App = () => {
  const { room: urlRoom, playerName: urlPlayer } = useParams();
  const room = useSelector(state => state.game.room);
  const isPlaying = useSelector(state => state.game.isPlaying);
  const gameOver = useSelector(state => state.game.gameOver);
  const gameState = useSelector(state => state.game.gameState);

  // Determine which view to show
  const view = useMemo(() => {
    if (!room) return 'lobby';
    if (isPlaying || gameOver) return 'game';
    if (gameState && !gameState.isStarted) return 'waiting';
    return 'waiting';
  }, [room, isPlaying, gameOver, gameState]);

  return (
    <div className="app-container">
      <h1 className="app-title">RED TETRIS</h1>
      <p className="app-subtitle">Multiplayer Tetris with Red Pelicans Sauce</p>

      {view === 'lobby' && (
        <Lobby initialRoom={urlRoom} initialPlayer={urlPlayer} />
      )}
      {view === 'waiting' && <WaitingRoom />}
      {view === 'game' && <GameView />}
    </div>
  );
};

export default App;
