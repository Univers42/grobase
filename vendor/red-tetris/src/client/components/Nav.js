import { Link, useNavigate, useLocation } from 'react-router-dom';
import { signOut } from '../baas/auth';
import { loadSession, jwtClaims } from '../baas/session';

const bar = { display: 'flex', alignItems: 'center', gap: 18, padding: '12px 22px', background: '#0e0e16', borderBottom: '1px solid #20203a', position: 'sticky', top: 0, zIndex: 20 };
const brand = { color: '#ff3b6b', fontWeight: 800, letterSpacing: 2, textDecoration: 'none', fontSize: 18 };
const link = (on) => ({ color: on ? '#fff' : '#8a8aa6', textDecoration: 'none', fontWeight: 600, fontSize: 14 });

/** Nav: persistent top bar with the section links + the signed-in user + sign-out. */
const Nav = () => {
  const nav = useNavigate();
  const { pathname } = useLocation();
  const session = loadSession();
  const name = session ? (jwtClaims(session.accessToken).user_metadata || {}).username || 'player' : '';
  const out = async () => { await signOut(); nav('/login'); };
  return (
    <div style={bar}>
      <Link to="/" style={brand}>RED TETRIS</Link>
      <Link to="/" style={link(pathname === '/')}>Play</Link>
      <Link to="/leaderboard" style={link(pathname === '/leaderboard')}>Leaderboard</Link>
      <Link to="/leagues" style={link(pathname === '/leagues')}>Leagues</Link>
      <div style={{ flex: 1 }} />
      {session && <Link to="/profile" style={link(pathname === '/profile')}>@{name}</Link>}
      {session && <span onClick={out} style={{ color: '#ff6a6a', cursor: 'pointer', fontSize: 13 }}>sign out</span>}
    </div>
  );
};

export default Nav;
