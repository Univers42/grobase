import { useState } from 'react';
import { useNavigate, Navigate } from 'react-router-dom';
import { motion } from 'framer-motion';
import { TreePine, LogIn, AlertCircle } from 'lucide-react';
import useBaasAuth from '@/hooks/useBaasAuth';

export default function Login() {
  const { user, loading, signIn } = useBaasAuth();
  const nav = useNavigate();

  const [email, setEmail]       = useState('');
  const [password, setPassword] = useState('');
  const [error, setError]       = useState('');
  const [busy, setBusy]         = useState(false);

  // Already authenticated → redirect to dashboard
  if (!loading && user) return <Navigate to="/admin" replace />;

  const handleSubmit = async (e) => {
    e.preventDefault();
    setError('');
    setBusy(true);
    try {
      await signIn(email, password);
      nav('/admin', { replace: true });
    } catch {
      setError('Invalid email or password. Please try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="flex min-h-screen items-center justify-center bg-forest p-4">
      {/* Background pattern */}
      <div
        className="pointer-events-none absolute inset-0 opacity-5"
        style={{
          backgroundImage:
            "url(\"data:image/svg+xml,%3Csvg width='60' height='60' viewBox='0 0 60 60' xmlns='http://www.w3.org/2000/svg'%3E%3Cg fill='none' fill-rule='evenodd'%3E%3Cg fill='%23ffffff' fill-opacity='0.4'%3E%3Cpath d='M36 34v-4h-2v4h-4v2h4v4h2v-4h4v-2h-4zm0-30V0h-2v4h-4v2h4v4h2V6h4V4h-4zM6 34v-4H4v4H0v2h4v4h2v-4h4v-2H6zM6 4V0H4v4H0v2h4v4h2V6h4V4H6z'/%3E%3C/g%3E%3C/g%3E%3C/svg%3E\")",
        }}
      />

      <motion.div
        initial={{ opacity: 0, scale: 0.95 }}
        animate={{ opacity: 1, scale: 1 }}
        className="relative w-full max-w-md"
      >
        <div className="card p-8">
          {/* Logo */}
          <div className="flex flex-col items-center">
            <div className="flex h-14 w-14 items-center justify-center rounded-2xl bg-forest/10">
              <TreePine className="h-8 w-8 text-forest" />
            </div>
            <h1 className="mt-4 font-display text-2xl font-bold text-forest">Staff Portal</h1>
            <p className="mt-1 text-sm text-charcoal/50">Sign in to Savanna Park Zoo admin</p>
          </div>

          {/* Error */}
          {error && (
            <div className="mt-5 flex items-center gap-2 rounded-xl bg-red-50 px-4 py-3 text-sm text-red-700">
              <AlertCircle className="h-4 w-4 flex-shrink-0" />
              {error}
            </div>
          )}

          {/* Form */}
          <form onSubmit={handleSubmit} className="mt-6 space-y-4">
            <div>
              <label className="mb-1 block text-sm font-medium text-charcoal/60">Email</label>
              <input
                type="email"
                autoComplete="email"
                required
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                placeholder="sophie.laurent@savanna-zoo.com"
                className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
              />
            </div>

            <div>
              <label className="mb-1 block text-sm font-medium text-charcoal/60">Password</label>
              <input
                type="password"
                autoComplete="current-password"
                required
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                placeholder="••••••••"
                className="w-full rounded-xl border border-sand bg-ivory px-4 py-2.5 text-sm outline-none focus:border-forest focus:ring-2 focus:ring-forest/20"
              />
            </div>

            <button
              type="submit"
              disabled={busy}
              className="btn-primary w-full disabled:opacity-50"
            >
              <LogIn className="h-4 w-4" />
              {busy ? 'Signing in…' : 'Sign In'}
            </button>
          </form>

          {/* Demo credentials hint */}
          <div className="mt-6 rounded-xl bg-sand-light p-4 text-xs text-charcoal/50">
            <p className="font-medium text-charcoal/70">Demo credentials:</p>
            <p className="mt-1">
              <span className="font-mono">sophie.laurent@savanna-zoo.com</span> — admin
            </p>
            <p>
              <span className="font-mono">marcus.osei@savanna-zoo.com</span> — zookeeper
            </p>
          </div>
        </div>
      </motion.div>
    </div>
  );
}
