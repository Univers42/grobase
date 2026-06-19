import { useState, type FormEvent } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { signIn, recover, oauthUrl } from '../baas/auth.ts';
import { isHttpError } from '../baas/http.ts';

/** Login renders the email+password form, OAuth buttons, and reset request. */
export function Login() {
  const { cfg, setSession } = useAuth();
  const { t } = useI18n();
  const navigate = useNavigate();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [notice, setNotice] = useState('');
  const [error, setError] = useState('');

  const onSubmit = async (e: FormEvent) => {
    e.preventDefault();
    setError('');
    try {
      const session = await signIn(cfg, email, password);
      setSession(session);
      navigate('/library', { replace: true });
    } catch (err) {
      setError(isHttpError(err) ? err.message : t('common.error'));
    }
  };

  const onReset = async () => {
    setError('');
    if (!email) return setError(t('auth.email'));
    try {
      await recover(cfg, email);
      setNotice(t('auth.resetSent'));
    } catch {
      setNotice(t('auth.resetSent'));
    }
  };

  return (
    <section className="auth-card">
      <h1>{t('auth.login')}</h1>
      {error && <p className="form-error" role="alert">{error}</p>}
      {notice && <p className="form-notice" role="status">{notice}</p>}
      <form onSubmit={onSubmit} noValidate>
        <label>
          {t('auth.identifier')}
          <input type="email" required value={email} autoComplete="email" onChange={(e) => setEmail(e.target.value)} />
        </label>
        <label>
          {t('auth.password')}
          <input type="password" required minLength={6} value={password} autoComplete="current-password" onChange={(e) => setPassword(e.target.value)} />
        </label>
        <button type="submit">{t('auth.login')}</button>
      </form>
      <button type="button" className="link-button" onClick={onReset}>{t('auth.forgot')}</button>
      <div className="oauth-row">
        <a className="oauth-button" href={oauthUrl('fortytwo')}>{t('auth.oauth42')}</a>
        <a className="oauth-button" href={oauthUrl('google')}>{t('auth.oauthGoogle')}</a>
      </div>
      <Link to="/register">{t('auth.noAccount')}</Link>
    </section>
  );
}
