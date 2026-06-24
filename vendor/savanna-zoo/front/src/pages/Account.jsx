import { useState } from 'react';
import { useNavigate, Navigate, useLocation, Link } from 'react-router-dom';
import { motion } from 'framer-motion';
import { TreePine, LogIn, UserPlus, AlertCircle } from 'lucide-react';
import useBaasAuth from '@/hooks/useBaasAuth';

/**
 * Visitor account page — self-signup (role=visitor) or sign-in. Distinct from
 * the staff portal at /admin/login. On success a visitor lands on their tickets.
 */
export default function Account() {
  const { user, loading, signIn, signUp } = useBaasAuth();
  const nav = useNavigate();
  const loc = useLocation();
  const dest = loc.state?.from || '/my-tickets';

  const [mode, setMode] = useState('signin'); // 'signin' | 'signup'
  const [fullName, setFullName] = useState('');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [busy, setBusy] = useState(false);

  if (!loading && user) return <Navigate to={dest} replace />;

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      if (mode === 'signup') await signUp(email, password, fullName);
      else await signIn(email, password);
      nav(dest, { replace: true });
    } catch (err) {
      setError(err.message || 'Something went wrong. Please try again.');
    } finally {
      setBusy(false);
    }
  };

  const isSignup = mode === 'signup';

  return (
    <div className="flex min-h-screen items-center justify-center bg-sand-light px-4 pt-16">
      <motion.div
        initial={{ opacity: 0, scale: 0.96 }}
        animate={{ opacity: 1, scale: 1 }}
        className="w-full max-w-md"
      >
        <div className="card p-8">
          <div className="flex flex-col items-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-forest/10">
              <TreePine className="h-8 w-8 text-forest" />
            </div>
            <h1 className="mt-4 font-display text-2xl font-bold text-forest">
              {isSignup ? 'Create your visitor account' : 'Welcome back'}
            </h1>
            <p className="mt-1 text-sm text-charcoal/50">
              {isSignup
                ? 'Book tickets and keep a private visit journal.'
                : 'Sign in to book and view your tickets.'}
            </p>
          </div>

          {error && (
            <div className="mt-5 flex items-center gap-2 rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
              <AlertCircle className="h-4 w-4 flex-shrink-0" />
              {error}
            </div>
          )}

          <form onSubmit={handleSubmit} className="mt-6 space-y-4">
            {isSignup && (
              <input
                type="text"
                placeholder="Full name"
                value={fullName}
                onChange={(e) => setFullName(e.target.value)}
                className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
              />
            )}
            <input
              type="email"
              autoComplete="email"
              required
              placeholder="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
            />
            <input
              type="password"
              autoComplete={isSignup ? 'new-password' : 'current-password'}
              required
              minLength={6}
              placeholder="Password"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
            />

            <button type="submit" disabled={busy} className="btn-primary w-full disabled:opacity-50">
              {isSignup ? <UserPlus className="h-4 w-4" /> : <LogIn className="h-4 w-4" />}
              {busy ? 'Please wait…' : isSignup ? 'Create account' : 'Sign in'}
            </button>
          </form>

          <p className="mt-5 text-center text-sm text-charcoal/50">
            {isSignup ? 'Already have an account?' : 'New to Savanna Park?'}{' '}
            <button
              type="button"
              onClick={() => { setMode(isSignup ? 'signin' : 'signup'); setError(''); }}
              className="font-medium text-forest hover:underline"
            >
              {isSignup ? 'Sign in' : 'Create an account'}
            </button>
          </p>

          <p className="mt-4 text-center text-xs text-charcoal/40">
            Zoo staff? <Link to="/admin" className="text-forest hover:underline">Staff portal</Link>
          </p>
        </div>
      </motion.div>
    </div>
  );
}
