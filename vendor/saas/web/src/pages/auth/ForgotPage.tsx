// ForgotPage.tsx — functional GoTrue password recovery. Sends the recover email
// and confirms with a toast; always shows a neutral success to avoid disclosing
// which addresses exist.

import { useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { AuthCard } from './AuthCard';
import { useAuthForm } from './useAuthForm';
import { useAuth } from '../../providers/useAuth';
import { useToast } from '../../providers/useToast';
import { Field } from '../../ds/Field';
import { Input } from '../../ds/Input';
import { Button } from '../../ds/Button';

/** ForgotPage renders the recovery-email request form. */
export function ForgotPage() {
  const { recover } = useAuth();
  const { error, loading, submit } = useAuthForm();
  const toast = useToast();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');

  const onSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    void submit(async () => {
      await recover(email);
      toast.success('Check your inbox', 'If that address exists, a reset link is on its way.');
      navigate('/login');
    });
  };

  return (
    <AuthCard
      title="Reset your password"
      subtitle="We’ll email you a secure reset link."
      footer={<><Link to="/login" className="text-accent hover:underline">Back to sign in</Link></>}
    >
      <form onSubmit={onSubmit} className="space-y-4" noValidate>
        <Field label="Email" error={error ?? undefined}>
          {({ id, describedBy, invalid }) => (
            <Input id={id} type="email" autoComplete="email" required value={email} invalid={invalid} aria-describedby={describedBy} onChange={(e) => setEmail(e.target.value)} placeholder="you@company.com" />
          )}
        </Field>
        <Button type="submit" loading={loading} className="w-full">Send reset link</Button>
      </form>
    </AuthCard>
  );
}
