import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { signUp, oauthUrl, type RegisterInput } from '../baas/auth.ts';
import { saveProfile } from '../baas/content.ts';
import { isHttpError } from '../baas/http.ts';

const EMPTY: RegisterInput = { email: '', username: '', firstName: '', lastName: '', password: '' };

/** Register renders the new-account form and seeds the user's profile row. */
export function Register() {
  const { cfg, setSession } = useAuth();
  const { t, lang } = useI18n();
  const navigate = useNavigate();
  const [form, setForm] = useState<RegisterInput>(EMPTY);
  const [error, setError] = useState('');

  const set = (k: keyof RegisterInput) => (e: { target: { value: string } }) =>
    setForm((f) => ({ ...f, [k]: e.target.value }));

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    try {
      const session = await signUp(cfg, form);
      setSession(session);
      await saveProfile(cfg, {
        user_id: session.userId,
        username: form.username,
        first_name: form.firstName,
        last_name: form.lastName,
        language: lang,
      }).catch(() => undefined);
      navigate('/library', { replace: true });
    } catch (err) {
      setError(isHttpError(err) ? err.message : t('common.error'));
    }
  };

  return (
    <section className="auth-card">
      <h1>{t('auth.register')}</h1>
      {error && <p className="form-error" role="alert">{error}</p>}
      <form onSubmit={onSubmit} noValidate>
        <label>{t('auth.email')}<input type="email" required value={form.email} onChange={set('email')} /></label>
        <label>{t('auth.username')}<input type="text" required minLength={3} value={form.username} onChange={set('username')} /></label>
        <label>{t('auth.firstName')}<input type="text" required value={form.firstName} onChange={set('firstName')} /></label>
        <label>{t('auth.lastName')}<input type="text" required value={form.lastName} onChange={set('lastName')} /></label>
        <label>{t('auth.password')}<input type="password" required minLength={6} value={form.password} onChange={set('password')} /></label>
        <button type="submit">{t('auth.register')}</button>
      </form>
      <div className="oauth-row">
        <a className="oauth-button" href={oauthUrl('fortytwo')}>{t('auth.oauth42')}</a>
        <a className="oauth-button" href={oauthUrl('google')}>{t('auth.oauthGoogle')}</a>
      </div>
      <Link to="/login">{t('auth.haveAccount')}</Link>
    </section>
  );
}
