import { useEffect, useState } from 'react';
import Nav from '../Nav';
import { myProfile } from '../../baas/profile';

const TIER_COLOR = { Bronze: '#cd7f32', Silver: '#c0c0c0', Gold: '#ffd700', Platinum: '#5fd0e0', Diamond: '#7af0ff' };
const page = { minHeight: '100vh', background: 'radial-gradient(circle at 50% -10%, #14142b, #0a0a0a)' };
const wrap = { maxWidth: 880, margin: '0 auto', padding: 24 };
const card = { background: '#15151f', border: '1px solid #2a2a40', borderRadius: 14, padding: 22, marginBottom: 18 };
const stat = { textAlign: 'center', flex: 1 };
const big = { fontSize: 30, fontWeight: 800, color: '#fff' };
const lbl = { fontSize: 11, color: '#7a7a96', textTransform: 'uppercase', letterSpacing: 1 };

/** ProfilePage: the signed-in player's card — max score, name, country, league
 *  tier + rating, aggregate stats, and recent games. */
const ProfilePage = () => {
  const [data, setData] = useState(null);
  const [err, setErr] = useState('');
  useEffect(() => { myProfile().then(setData).catch((e) => setErr(e.message || 'failed')); }, []);

  if (err) return (<div style={page}><Nav /><div style={wrap}><p style={{ color: '#ff6a6a' }}>{err}</p></div></div>);
  if (!data) return (<div style={page}><Nav /><div style={wrap}><p style={{ color: '#7a7a96' }}>loading…</p></div></div>);

  const p = data.profile || {};
  const s = data.stats || {};
  const r = data.rating || {};
  const tier = r.league_tier || 'Bronze';
  const wins = s.wins || 0;
  const games = s.total_games || 0;
  const winRate = games ? Math.round((wins / games) * 100) : 0;
  const initial = (p.username || '?').slice(0, 1).toUpperCase();

  return (
    <div style={page}>
      <Nav />
      <div style={wrap}>
        <div style={{ ...card, display: 'flex', alignItems: 'center', gap: 20 }}>
          <div style={{ width: 84, height: 84, borderRadius: 16, background: 'linear-gradient(135deg,#ff3b6b,#ff6a3d)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 40, fontWeight: 800 }}>{initial}</div>
          <div style={{ flex: 1 }}>
            <h1 style={{ color: '#fff', margin: 0 }}>@{p.username || 'player'}</h1>
            <p style={{ color: '#9a9ab6', margin: '4px 0' }}>{[p.first_name, p.last_name].filter(Boolean).join(' ')} {p.country ? `· ${p.country}` : ''}</p>
            <span style={{ display: 'inline-block', marginTop: 6, padding: '4px 12px', borderRadius: 20, background: '#0e0e16', border: `1px solid ${TIER_COLOR[tier] || '#888'}`, color: TIER_COLOR[tier] || '#fff', fontWeight: 700, fontSize: 13 }}>
              {tier} · {r.rating || 1000} ELO
            </span>
          </div>
        </div>

        <div style={{ ...card, display: 'flex' }}>
          <div style={stat}><div style={big}>{s.max_score || 0}</div><div style={lbl}>Max Score</div></div>
          <div style={stat}><div style={big}>{games}</div><div style={lbl}>Games</div></div>
          <div style={stat}><div style={big}>{wins}</div><div style={lbl}>Wins</div></div>
          <div style={stat}><div style={big}>{winRate}%</div><div style={lbl}>Win Rate</div></div>
          <div style={stat}><div style={big}>{s.total_lines || 0}</div><div style={lbl}>Lines</div></div>
        </div>

        <div style={card}>
          <h3 style={{ color: '#fff', marginTop: 0 }}>Recent games</h3>
          {data.games.length === 0 && <p style={{ color: '#7a7a96' }}>No games yet — go Play!</p>}
          {data.games.map((g) => (
            <div key={g.id} style={{ display: 'flex', padding: '8px 0', borderTop: '1px solid #20203a', color: '#c7c7e0', fontSize: 14 }}>
              <span style={{ flex: 1 }}>{g.mode}{g.won ? ' · 🏆' : ''}</span>
              <span style={{ width: 90, textAlign: 'right' }}>{g.score} pts</span>
              <span style={{ width: 70, textAlign: 'right', color: '#7a7a96' }}>{g.lines} lines</span>
              <span style={{ width: 140, textAlign: 'right', color: '#5a5a72' }}>{new Date(g.ended_at).toLocaleDateString()}</span>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
};

export default ProfilePage;
