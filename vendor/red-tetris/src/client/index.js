import { createRoot } from 'react-dom/client';
import { Provider } from 'react-redux';
import { BrowserRouter, Routes, Route } from 'react-router-dom';
import store from './store';
import initGrobaseNet from './middleware/grobase';
import App from './components/App';
import LoginPage from './components/auth/LoginPage';
import RequireAuth from './components/auth/RequireAuth';
import ProfilePage from './components/profile/ProfilePage';
import GlobalLeaderboard from './components/leaderboard/GlobalLeaderboard';
import Leagues from './components/leaderboard/Leagues';

// Realtime game wiring (presence + BROADCAST) — bound to the store. Replaces the
// legacy socket.io middleware: rooms are presence topics, game events are
// broadcasts, scores persist to Grobase. No game server.
initGrobaseNet(store);

const root = createRoot(document.getElementById('root'));

root.render(
  <Provider store={store}>
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<LoginPage />} />
        <Route path="/profile" element={<RequireAuth><ProfilePage /></RequireAuth>} />
        <Route path="/leaderboard" element={<RequireAuth><GlobalLeaderboard /></RequireAuth>} />
        <Route path="/leagues" element={<RequireAuth><Leagues /></RequireAuth>} />
        <Route path="/:room/:playerName" element={<RequireAuth><App /></RequireAuth>} />
        <Route path="/*" element={<RequireAuth><App /></RequireAuth>} />
      </Routes>
    </BrowserRouter>
  </Provider>
);
