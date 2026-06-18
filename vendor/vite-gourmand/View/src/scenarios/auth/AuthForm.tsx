/**
 * AuthForm - Unified login/register/forgot password form
 */

import type { AuthMode, FormState, FormErrors } from './types';
import { TextInput } from '../../components/ui/inputs';
import './AuthForm.css';

interface AuthFormProps {
  mode: AuthMode;
  form: FormState;
  errors: FormErrors;
  loading: boolean;
  success: string | null;
  onFieldChange: <K extends keyof FormState>(field: K, value: FormState[K]) => void;
  onSubmit: () => void;
  onModeSwitch: (mode: AuthMode) => void;
  onGoogleLogin?: () => void;
}

const titles: Record<AuthMode, string> = {
  login: 'Connexion',
  register: 'Créer un compte',
  forgot: 'Mot de passe oublié',
  reset: 'Nouveau mot de passe',
};

const submitLabels: Record<AuthMode, string> = {
  login: 'Se connecter',
  register: "S'inscrire",
  forgot: 'Envoyer le lien',
  reset: 'Réinitialiser',
};

export function AuthForm({
  mode,
  form,
  errors,
  loading,
  success,
  onFieldChange,
  onSubmit,
  onModeSwitch,
  onGoogleLogin,
}: AuthFormProps) {
  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    onSubmit();
  };

  return (
    <form className="auth-form" onSubmit={handleSubmit}>
      <h2 className="auth-form__title">{titles[mode]}</h2>

      {errors.general && (
        <div className="auth-form__error" role="alert">
          {errors.general}
        </div>
      )}

      {success && (
        <div className="auth-form__success" role="status">
          {success}
        </div>
      )}

      {mode === 'register' && (
        <TextInput
          id="name"
          name="name"
          label="Nom complet"
          value={form.name}
          onChange={(v) => onFieldChange('name', v)}
          error={errors.name}
          required
          placeholder="Jean Dupont"
        />
      )}

      <TextInput
        id="email"
        name="email"
        type="email"
        label="Email"
        value={form.email}
        onChange={(v) => onFieldChange('email', v)}
        error={errors.email}
        required
        placeholder="email@exemple.com"
      />

      {mode !== 'forgot' && (
        <TextInput
          id="password"
          name="password"
          type="password"
          label="Mot de passe"
          value={form.password}
          onChange={(v) => onFieldChange('password', v)}
          error={errors.password}
          required
          placeholder="••••••••"
        />
      )}

      {mode === 'register' && (
        <>
          <TextInput
            id="confirmPassword"
            name="confirmPassword"
            type="password"
            label="Confirmer le mot de passe"
            value={form.confirmPassword}
            onChange={(v) => onFieldChange('confirmPassword', v)}
            error={errors.confirmPassword}
            required
            placeholder="••••••••"
          />
          <TextInput
            id="phone"
            name="phone"
            label="Téléphone (optionnel)"
            value={form.phone}
            onChange={(v) => onFieldChange('phone', v)}
            placeholder="06 12 34 56 78"
          />
          <label className="auth-form__consent">
            <input
              type="checkbox"
              checked={form.gdprConsent}
              onChange={(event) => onFieldChange('gdprConsent', event.target.checked)}
              required
            />
            <span>J'accepte le traitement de mes données personnelles.</span>
          </label>
          {errors.gdprConsent && (
            <div className="auth-form__error" role="alert">
              {errors.gdprConsent}
            </div>
          )}
        </>
      )}

      <button type="submit" className="auth-form__submit" disabled={loading}>
        {loading ? 'Chargement...' : submitLabels[mode]}
      </button>

      {(mode === 'login' || mode === 'register') && onGoogleLogin && (
        <>
          <div className="auth-form__divider">
            <span>ou</span>
          </div>
          <button
            type="button"
            className="auth-form__google"
            onClick={onGoogleLogin}
            disabled={loading}
          >
            <GoogleIcon />
            Continuer avec Google
          </button>
        </>
      )}

      <AuthLinks mode={mode} onSwitch={onModeSwitch} />
    </form>
  );
}

function AuthLinks({ mode, onSwitch }: { mode: AuthMode; onSwitch: (m: AuthMode) => void }) {
  return (
    <div className="auth-form__links">
      {mode === 'login' && (
        <>
          <button type="button" onClick={() => onSwitch('forgot')}>
            Mot de passe oublié ?
          </button>
          <button type="button" onClick={() => onSwitch('register')}>
            Créer un compte
          </button>
        </>
      )}
      {mode === 'register' && (
        <button type="button" onClick={() => onSwitch('login')}>
          Déjà un compte ? Se connecter
        </button>
      )}
      {mode === 'forgot' && (
        <button type="button" onClick={() => onSwitch('login')}>
          Retour à la connexion
        </button>
      )}
    </div>
  );
}

function GoogleIcon() {
  return (
    <svg viewBox="0 0 24 24" width="20" height="20" className="google-icon">
      <path
        fill="#4285F4"
        d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"
      />
      <path
        fill="#34A853"
        d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"
      />
      <path
        fill="#FBBC05"
        d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"
      />
      <path
        fill="#EA4335"
        d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"
      />
    </svg>
  );
}
