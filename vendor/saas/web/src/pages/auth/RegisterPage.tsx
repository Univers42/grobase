// RegisterPage.tsx — functional GoTrue sign-up. Creates the account (and its
// app_users row + customer account, via useAuth/provision); when the tenant returns
// a session it routes into the console, otherwise it points at sign-in. A
// shared-GoTrue email collision is recovered, not dead-ended (see useRegister).

import { useState } from 'react';
import { Link } from 'react-router-dom';
import { AuthCard } from './AuthCard';
import { useAuthForm } from './useAuthForm';
import { useRegister } from './useRegister';
import { Field } from '../../ds/Field';
import { Input } from '../../ds/Input';
import { Button } from '../../ds/Button';

/** RegisterPage renders the account-creation form. */
export function RegisterPage() {
  const register = useRegister();
  const { error, loading, submit } = useAuthForm();
  const [form, setForm] = useState({ username: '', email: '', password: '' });
  const set = (k: keyof typeof form) => (e: React.ChangeEvent<HTMLInputElement>) => setForm((f) => ({ ...f, [k]: e.target.value }));

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    void submit(() => register(form));
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
