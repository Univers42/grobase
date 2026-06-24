import { Link, useNavigate } from 'react-router-dom';
import { useAuth } from '../auth/AuthContext.tsx';
import { useI18n } from '../i18n/I18nContext.tsx';
import { LanguageSelector } from './LanguageSelector.tsx';

/** NavBar renders the top bar with brand, nav links, language and logout. */
export function NavBar() {
  const { session, logout } = useAuth();
  const { t } = useI18n();
  const navigate = useNavigate();
  const onLogout = async () => {
    await logout();
    navigate('/login', { replace: true });
  };
  return (
    <header className="navbar">
      <Link to={session ? '/library' : '/login'} className="brand">
        {t('app.title')}
      </Link>
      <nav className="nav-links">
        {session && <Link to="/library">{t('nav.library')}</Link>}
        {session && (
          <Link to={`/profile/${session.userId}`}>{t('nav.profile')}</Link>
        )}
        <LanguageSelector />
        {session && (
          <button type="button" className="link-button" onClick={onLogout}>
            {t('nav.logout')}
          </button>
        )}
      </nav>
    </header>
  );
}
