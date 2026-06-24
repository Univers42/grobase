import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import useBaasAuth from '@/hooks/useBaasAuth';

/**
 * Shared email/password auth card. mode = 'login' | 'register'.
 * Register also collects a name and calls signUp (data {full_name, role:'user'}).
 */
export default function AuthForm({ mode }) {
  const isRegister = mode === 'register';
  const { signIn, signUp } = useBaasAuth();
  const navigate = useNavigate();
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState(null);

  async function submit(e) {
    e.preventDefault();
    if (busy) return;
    setBusy(true);
    setError(null);
    try {
      if (isRegister) await signUp(email, password, name);
      else await signIn(email, password);
      navigate('/');
    } catch (err) {
      setError(err.message || 'No se pudo completar la operación');
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="mx-auto flex min-h-[70vh] max-w-md flex-col justify-center px-5 py-12">
      <div className="panel p-8">
        <p className="text-sm font-bold uppercase tracking-[0.28em] text-ocean-teal">Surfind Spain</p>
        <h1 className="mt-2 text-3xl font-black tracking-tight text-ocean">
          {isRegister ? 'Crear cuenta' : 'Acceder'}
        </h1>

        <form onSubmit={submit} className="mt-6 space-y-4">
          {isRegister && (
            <div>
              <label htmlFor="name" className="mb-2 block text-sm font-semibold text-ocean-deep">Nombre</label>
              <input id="name" value={name} onChange={(e) => setName(e.target.value)} className="field" placeholder="Tu nombre" />
            </div>
          )}
          <div>
            <label htmlFor="email" className="mb-2 block text-sm font-semibold text-ocean-deep">Email</label>
            <input
              id="email"
              type="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="field"
              placeholder="tu@email.com"
            />
          </div>
          <div>
            <label htmlFor="password" className="mb-2 block text-sm font-semibold text-ocean-deep">Contraseña</label>
            <input
              id="password"
              type="password"
              required
              minLength={6}
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="field"
              placeholder="••••••••"
            />
          </div>

          {error && <p className="text-sm font-semibold text-rose-700">{error}</p>}

          <button type="submit" disabled={busy} className="btn-primary w-full disabled:opacity-60">
            {busy ? 'Procesando…' : isRegister ? 'Crear cuenta' : 'Entrar'}
          </button>
        </form>

        <p className="mt-6 text-center text-sm font-semibold text-ocean-mid">
          {isRegister ? (
            <>¿Ya tienes cuenta? <Link to="/acceder" className="font-black text-ocean hover:text-ocean-mid">Acceder</Link></>
          ) : (
            <>¿No tienes cuenta? <Link to="/registro" className="font-black text-ocean hover:text-ocean-mid">Crear cuenta</Link></>
          )}
        </p>
      </div>
    </section>
  );
}
