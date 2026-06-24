import { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { signIn, signUp } from '../../baas/auth';

const wrap = { minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center', background: 'radial-gradient(circle at 50% 0%, #14142b, #0a0a0a)' };
const card = { width: 360, maxWidth: '90vw', background: '#15151f', border: '1px solid #2a2a40', borderRadius: 14, padding: 28, boxShadow: '0 18px 60px rgba(0,0,0,0.6)' };
const input = { width: '100%', padding: '11px 12px', marginTop: 8, background: '#0e0e16', border: '1px solid #2c2c44', borderRadius: 8, color: '#fff', fontSize: 14, fontFamily: 'inherit' };
const btn = { width: '100%', padding: '12px', marginTop: 16, background: 'linear-gradient(90deg,#ff3b6b,#ff6a3d)', border: 'none', borderRadius: 8, color: '#fff', fontWeight: 700, fontSize: 15, cursor: 'pointer', letterSpacing: 1 };
const tab = (on) => ({ flex: 1, padding: 8, textAlign: 'center', cursor: 'pointer', color: on ? '#fff' : '#7a7a96', borderBottom: on ? '2px solid #ff3b6b' : '2px solid transparent', fontWeight: 600 });

/**
 * LoginPage: GoTrue email/password sign-in + sign-up. On success it lands on the
 * profile page. Demo accounts (seeded) are shown for quick access.
 */
const LoginPage = () => {
  const nav = useNavigate();
  const [mode, setMode] = useState('signin');
  const [form, setForm] = useState({ email: '', password: '', username: '', firstName: '', lastName: '' });
  const [err, setErr] = useState('');
  const [busy, setBusy] = useState(false);
  const set = (k) => (e) => setForm({ ...form, [k]: e.target.value });

  const submit = async (e) => {
    e.preventDefault();
    setErr(''); setBusy(true);
    try {
      if (mode === 'signin') await signIn(form.email.trim(), form.password);
      else await signUp({ ...form, email: form.email.trim() });
      nav('/profile');
    } catch (e2) {
      setErr(e2 && e2.message ? e2.message : 'failed');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div style={wrap}>
      <div style={card}>
        <h1 style={{ textAlign: 'center', color: '#ff3b6b', letterSpacing: 3, marginBottom: 4 }}>RED TETRIS</h1>
        <p style={{ textAlign: 'center', color: '#7a7a96', fontSize: 12, marginBottom: 18 }}>powered by Grobase</p>
        <div style={{ display: 'flex', marginBottom: 14 }}>
          <div style={tab(mode === 'signin')} onClick={() => setMode('signin')}>Sign in</div>
          <div style={tab(mode === 'signup')} onClick={() => setMode('signup')}>Sign up</div>
        </div>
        <form onSubmit={submit}>
          <input style={input} type="email" placeholder="email" value={form.email} onChange={set('email')} required />
          <input style={input} type="password" placeholder="password" value={form.password} onChange={set('password')} required />
          {mode === 'signup' && (
            <>
              <input style={input} placeholder="username" value={form.username} onChange={set('username')} required />
              <input style={input} placeholder="first name" value={form.firstName} onChange={set('firstName')} />
              <input style={input} placeholder="last name" value={form.lastName} onChange={set('lastName')} />
            </>
          )}
          {err && <p style={{ color: '#ff6a6a', fontSize: 13, marginTop: 10 }}>{err}</p>}
          <button style={btn} type="submit" disabled={busy}>{busy ? '…' : mode === 'signin' ? 'PLAY' : 'CREATE ACCOUNT'}</button>
        </form>
        <p style={{ color: '#5a5a72', fontSize: 11, marginTop: 16, textAlign: 'center' }}>
          demo: alice@tetris.local … heidi@tetris.local · <b>Tetris#2026</b>
        </p>
      </div>
    </div>
  );
};

export default LoginPage;
