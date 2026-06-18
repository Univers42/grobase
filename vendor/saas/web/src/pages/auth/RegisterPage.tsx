// RegisterPage.tsx — functional GoTrue sign-up. Creates the account and, when the
// tenant returns a session, routes straight into the console; otherwise it points
// the user at sign-in (e.g. email-confirmation tenants).

import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { AuthCard } from './AuthCard';
import { useAuthForm } from './useAuthForm';
import { useAuth } from '../../providers/useAuth';
import { useToast } from '../../providers/useToast';
import { Field } from '../../ds/Field';
import { Input } from '../../ds/Input';
import { Button } from '../../ds/Button';

/** RegisterPage renders the account-creation form. */
export function RegisterPage() {
  const { signUp, isAuthed } = useAuth();
  const { error, loading, submit } = useAuthForm();
  const toast = useToast();
  const navigate = useNavigate();
  const [form, setForm] = useState({ username: '', email: '', password: '' });
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    void submit(async () => {
      await signUp(form.email, form.password, form.username);
      if (isAuthed) return navigate('/app', { replace: true });
      toast.success('Account created', 'Check your inbox, then sign in.');
      navigate('/login');
    });
  };

  return (
    <AuthCard
      title="Create your account"
      subtitle="Spin up your Nimbus console in seconds."
      footer={<>Already have one? <Link to="/login" className="text-accent hover:underline">Sign in</Link></>}
    >
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <Field label="Username">
          {({ id }) => <Input id={id} autoComplete="username" required value={form.username} onChange={set('username')} placeholder="ada" />}
        </Field>
        <Field label="Email">
          {({ id }) => <Input id={id} type="email" autoComplete="email" required value={form.email} onChange={set('email')} placeholder="you@company.com" />}
        </Field>
        <Field label="Password" error={error ?? undefined}>
          {({ id, describedBy, invalid }) => (
            <Input id={id} type="password" autoComplete="new-password" required minLength={8} value={form.password} invalid={invalid} aria-describedby={describedBy} onChange={set('password')} placeholder="At least 8 characters" />
          )}
        </Field>
        <Button type="submit" loading={loading} className="w-full">Create account</Button>
      </form>
    </AuthCard>
  );
}
