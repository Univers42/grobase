// LoginPage.tsx — functional GoTrue sign-in. On success it routes to the console
// (or the page the guard bounced from). Wired for real: works once baas-config
// carries live values.

import { useState } from 'react';
import { Link, useLocation, useNavigate } from 'react-router-dom';
import { AuthCard } from './AuthCard';
import { useAuthForm } from './useAuthForm';
import { useAuth } from '../../providers/useAuth';
import { Field } from '../../ds/Field';
import { Input } from '../../ds/Input';
import { Button } from '../../ds/Button';
import { asString } from '../../lib/guards';
import { isRecord } from '../../lib/guards';

/** LoginPage renders the email/password sign-in form. */
export function LoginPage() {
  const { signIn } = useAuth();
  const { error, loading, submit } = useAuthForm();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const navigate = useNavigate();
  const location = useLocation();
  const from = isRecord(location.state) ? asString(location.state.from, '/app') : '/app';

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    void submit(async () => {
      await signIn(email, password);
      navigate(from, { replace: true });
    });
  };

  return (
    <AuthCard
      title="Welcome back"
      subtitle="Sign in to your Nimbus console."
      footer={<>No account? <Link to="/register" className="text-accent hover:underline">Create one</Link></>}
    >
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <Field label="Email">
          {({ id, invalid }) => (
            <Input id={id} type="email" autoComplete="email" required value={email} invalid={invalid} onChange={(e) => setEmail(e.target.value)} placeholder="you@company.com" />
          )}
        </Field>
        <Field label="Password" error={error ?? undefined}>
          {({ id, describedBy, invalid }) => (
            <Input id={id} type="password" autoComplete="current-password" required value={password} invalid={invalid} aria-describedby={describedBy} onChange={(e) => setPassword(e.target.value)} placeholder="••••••••" />
          )}
        </Field>
        <div className="flex justify-end">
          <Link to="/forgot" className="text-xs text-muted hover:text-ink">Forgot password?</Link>
        </div>
        <Button type="submit" loading={loading} className="w-full">Sign in</Button>
      </form>
    </AuthCard>
  );
}
