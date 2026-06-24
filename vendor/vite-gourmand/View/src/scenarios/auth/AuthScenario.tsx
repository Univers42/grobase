/**
 * AuthScenario - Main authentication page
 */

import { GradientBackground } from '../../components/DevBoard';
import { useAuth } from './useAuth';
import { AuthForm } from './AuthForm';
import './AuthScenario.css';

export function AuthScenario() {
  const {
    mode,
    form,
    errors,
    loading,
    success,
    updateField,
    handleSubmit,
    handleGoogleLogin,
    switchMode,
  } = useAuth();

  // Simple mock for demo - in production, use Google Identity Services
  const triggerGoogleLogin = () => {
    // This would trigger Google OAuth popup
    handleGoogleLogin('mock-credential');
  };

  return (
    <div className="auth-scenario">
      <GradientBackground />

      <header className="auth-header">
        <a href="/" className="auth-back-link">
          ← Retour
        </a>
        <div className="auth-logo">
          <span className="auth-logo-icon">🍷</span>
          <span className="auth-logo-text">Vite Gourmand</span>
        </div>
      </header>

      <main className="auth-content">
        <div className="auth-card">
          <AuthForm
            mode={mode}
            form={form}
            errors={errors}
            loading={loading}
            success={success}
            onFieldChange={updateField}
            onSubmit={handleSubmit}
            onModeSwitch={switchMode}
            onGoogleLogin={triggerGoogleLogin}
          />
        </div>
      </main>

      <footer className="auth-footer">
        <p>© 2024 Vite Gourmand - Tous droits réservés</p>
      </footer>
    </div>
  );
}
