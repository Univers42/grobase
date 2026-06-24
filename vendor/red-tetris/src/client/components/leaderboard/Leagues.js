import { useEffect, useState } from 'react';
import Nav from '../Nav';
import { classement, leagueTiers } from '../../baas/profile';
import { subscribeTable } from '../../baas/realtime';

const TIER_COLOR = { Bronze: '#cd7f32', Silver: '#c0c0c0', Gold: '#ffd700', Platinum: '#5fd0e0', Diamond: '#7af0ff' };
const page = { minHeight: '100vh', background: 'radial-gradient(circle at 50% -10%, #14142b, #0a0a0a)' };
const wrap = { maxWidth: 760, margin: '0 auto', padding: 24 };

/** Leagues: the classement grouped by tier (Bronze..Diamond). LIVE — the table is
 *  derived from current ratings and re-derived on every games CDC event, so a
 *  finished game (which shifts a rating across a tier band) moves players live. */
const Leagues = () => {
  const [tiers, setTiers] = useState([]);
  const [byTier, setByTier] = useState({});
  const refresh = () => classement(200).then((rows) => {
    const g = {};
    rows.forEach((r) => { (g[r.league_tier] = g[r.league_tier] || []).push(r); });
    setByTier(g);
  }).catch(() => {});
  useEffect(() => {
    leagueTiers().then(setTiers).catch(() => {});
    refresh();
    const h = subscribeTable('games', () => refresh());
    return () => h && h.close();
  }, []);
  return (
    <div style={page}>
      <Nav />
      <div style={wrap}>
        <h1 style={{ color: '#fff' }}>Leagues <span style={{ fontSize: 12, color: '#5fd0e0' }}>● live</span></h1>
        {tiers.slice().reverse().map((t) => (
          <div key={t.tier} style={{ marginBottom: 22 }}>
            <h2 style={{ color: TIER_COLOR[t.tier] || '#fff', borderBottom: `2px solid ${TIER_COLOR[t.tier] || '#444'}`, paddingBottom: 6 }}>
              {t.tier} <span style={{ fontSize: 12, color: '#6a6a86' }}>({t.min_rating}–{t.max_rating === 100000 ? '∞' : t.max_rating} ELO)</span>
            </h2>
            {(byTier[t.tier] || []).sort((a, b) => a.rank - b.rank).map((r) => (
              <div key={r.player_id} style={{ display: 'flex', padding: '7px 10px', color: '#c7c7e0', fontSize: 14, borderBottom: '1px solid #1a1a2a' }}>
                <span style={{ width: 40, color: '#7a7a96' }}>#{r.rank}</span>
                <span style={{ flex: 1 }}>{r.rating} ELO</span>
                <span style={{ width: 80, textAlign: 'right', color: '#9a9ab6' }}>{r.points} pts</span>
              </div>
            ))}
            {(byTier[t.tier] || []).length === 0 && <p style={{ color: '#5a5a72', fontSize: 13 }}>— empty —</p>}
          </div>
        ))}
      </div>
    </div>
  );
};

export default Leagues;
