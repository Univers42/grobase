import { useEffect, useState } from 'react';
import Nav from '../Nav';
import { leaderboard } from '../../baas/profile';
import { subscribeTable } from '../../baas/realtime';

const TIER_COLOR = { Bronze: '#cd7f32', Silver: '#c0c0c0', Gold: '#ffd700', Platinum: '#5fd0e0', Diamond: '#7af0ff' };
const page = { minHeight: '100vh', background: 'radial-gradient(circle at 50% -10%, #14142b, #0a0a0a)' };
const wrap = { maxWidth: 760, margin: '0 auto', padding: 24 };
const row = (i) => ({ display: 'flex', alignItems: 'center', padding: '11px 14px', background: i % 2 ? '#13131d' : '#15151f', borderRadius: 8, marginBottom: 6, color: '#d6d6ee' });

/** GlobalLeaderboard: top players by max score, LIVE — re-fetches whenever a game
 *  row is inserted (realtime CDC on the games table). */
const GlobalLeaderboard = () => {
  const [rows, setRows] = useState([]);
  const refresh = () => leaderboard(50).then(setRows).catch(() => {});
  useEffect(() => {
    refresh();
    const h = subscribeTable('games', () => refresh());
    return () => h && h.close();
  }, []);
  return (
    <div style={page}>
      <Nav />
      <div style={wrap}>
        <h1 style={{ color: '#fff' }}>🏆 Leaderboard <span style={{ fontSize: 12, color: '#5fd0e0' }}>● live</span></h1>
        {rows.map((r, i) => (
          <div key={r.player_id} style={row(i)}>
            <span style={{ width: 36, fontWeight: 800, color: i < 3 ? '#ffd700' : '#7a7a96' }}>#{i + 1}</span>
            <span style={{ flex: 1, fontWeight: 600 }}>@{r.username} <span style={{ color: '#6a6a86', fontWeight: 400 }}>{r.country}</span></span>
            <span style={{ width: 90, color: TIER_COLOR[r.league_tier] || '#aaa', fontSize: 13 }}>{r.league_tier}</span>
            <span style={{ width: 70, textAlign: 'right', color: '#9a9ab6' }}>{r.rating} ELO</span>
            <span style={{ width: 90, textAlign: 'right', fontWeight: 700, color: '#fff' }}>{r.max_score}</span>
          </div>
        ))}
        {rows.length === 0 && <p style={{ color: '#7a7a96' }}>No scores yet.</p>}
      </div>
    </div>
  );
};

export default GlobalLeaderboard;
