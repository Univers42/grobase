// useRegister.ts — owns the sign-up submit, including the shared-GoTrue collision
// path. GoTrue is platform-wide (global email uniqueness), so a "create account"
// for an email that already exists is expected, not a dead end: on that collision
// we try to sign the user in with the same credentials (self-healing their
// app_users row via useAuth.signIn), and only surface "already registered, please
// sign in" when the password does not match.

import { useNavigate } from 'react-router-dom';
import { isEmailTaken } from '../../lib/auth';
import { useAuth } from '../../providers/useAuth';
import { useBaas } from '../../providers/useBaas';
import { useToast } from '../../providers/useToast';

/** RegisterForm is the account-creation form payload. */
export type RegisterForm = { username: string; email: string; password: string };

/** EMAIL_TAKEN_MESSAGE is the form-level error shown when a collision can't auto-resolve. */
const EMAIL_TAKEN_MESSAGE = 'That email is already registered. Sign in below with your password.';

/** useRegister returns a submit(form) that signs up, falling back to sign-in on a
 *  shared-GoTrue email collision; it routes to the console on success. */
export function useRegister(): (form: RegisterForm) => Promise<void> {
  const { signUp, signIn } = useAuth();
  const { auth } = useBaas();
  const toast = useToast();
  const navigate = useNavigate();

  async function recoverExisting({ email, password }: RegisterForm): Promise<void> {
    try {
      await signIn(email, password);
    } catch {
      throw new Error(EMAIL_TAKEN_MESSAGE);
    }
    toast.success('Welcome back', 'That email was already registered — you are signed in.');
    navigate('/app', { replace: true });
  }

  return async (form: RegisterForm) => {
    try {
      await signUp(form.email, form.password, form.username);
    } catch (e: unknown) {
      if (isEmailTaken(e)) return recoverExisting(form);
      throw e;
    }
    if (auth.isAuthed()) return navigate('/app', { replace: true });
    toast.success('Account created', 'Check your inbox, then sign in.');
    navigate('/login');
  };
}
