/**
 * Reset Password Page
 * Allows users to reset their password using a token from email
 */

import { useState, useMemo, useEffect } from 'react';
import { useSearchParams, Link, useNavigate } from 'react-router-dom';
import { resetPassword, verifyResetToken } from '../services/auth';
import { useToast } from '../contexts/ToastContext';
import {
  Lock,
  Eye,
  EyeOff,
  CheckCircle,
  AlertCircle,
  ArrowRight,
  ChefHat,
  Loader2,
} from 'lucide-react';
import './PortalLogin.css';

/* ── Password validation (10 chars, 1 special, 1 upper, 1 lower, 1 digit) ── */
function validatePassword(pw: string) {
  return {
    minLength: pw.length >= 10,
    hasUpper: /[A-Z]/.test(pw),
    hasLower: /[a-z]/.test(pw),
    hasDigit: /\d/.test(pw),
    hasSpecial: /[^A-Za-z0-9]/.test(pw),
  };
}

function isPasswordValid(pw: string): boolean {
  const v = validatePassword(pw);
  return v.minLength && v.hasUpper && v.hasLower && v.hasDigit && v.hasSpecial;
}

export function ResetPasswordPage() {
  const [searchParams] = useSearchParams();
  const navigate = useNavigate();
  const { addToast } = useToast();
  const [token] = useState(() => searchParams.get('token'));

  useEffect(() => {
    if (searchParams.has('token')) {
      navigate('/reset-password', { replace: true });
    }
  }, [navigate, searchParams]);

  // Token verification state
  const [verifying, setVerifying] = useState(true);
  const [tokenValid, setTokenValid] = useState(false);
  const [tokenError, setTokenError] = useState('');

  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState(false);

  const pwChecks = useMemo(() => validatePassword(password), [password]);

  // Verify token on mount
  useEffect(() => {
    async function checkToken() {
      if (!token) {
        setTokenError('Lien invalide. Aucun token de réinitialisation fourni.');
        setVerifying(false);
        return;
      }

      try {
        const result = await verifyResetToken(token);
        if (result.valid) {
          setTokenValid(true);
        } else {
          setTokenError(result.message || 'Ce lien de réinitialisation est invalide ou a expiré.');
        }
      } catch {
        setTokenError('Ce lien de réinitialisation est invalide ou a expiré.');
      } finally {
        setVerifying(false);
      }
    }

    checkToken();
  }, [token]);

  const handleSubmit = async (e: React.SubmitEvent) => {
    e.preventDefault();
    setError('');

    if (!token) {
      setError('Token de réinitialisation manquant ou invalide.');
      return;
    }

    if (!isPasswordValid(password)) {
      setError('Le mot de passe ne respecte pas les critères de sécurité.');
      return;
    }

    if (password !== confirmPassword) {
      setError('Les mots de passe ne correspondent pas.');
      return;
    }

    setIsLoading(true);
    try {
      await resetPassword(token, password);
      setSuccess(true);
      addToast('Mot de passe modifié avec succès !', 'success', 7000);
      // Redirect to portal after 3 seconds
      setTimeout(() => navigate('/portal'), 3000);
    } catch (err) {
      const msg =
        err instanceof Error
          ? err.message
          : 'Échec de la réinitialisation. Le lien a peut-être expiré.';
      setError(msg);
      addToast(msg, 'error');
    } finally {
      setIsLoading(false);
    }
  };

  // Show loading while verifying token
  if (verifying) {
    return (
      <div className="portal-page">
        <div className="portal-bg" aria-hidden="true">
          <div className="portal-bg-gradient" />
          <div className="portal-bg-pattern" />
        </div>
        <div className="portal-container">
          <div className="portal-brand">
            <div className="portal-brand-icon">
              <ChefHat size={28} />
            </div>
            <h1 className="portal-brand-name">Vite & Gourmand</h1>
          </div>
          <div className="pf-card">
            <div className="pf-body" style={{ textAlign: 'center', padding: '3rem' }}>
              <Loader2
                size={32}
                className="pf-spinner"
                style={{ animation: 'spin 1s linear infinite', color: '#8B4557' }}
              />
              <p style={{ marginTop: '1rem', color: '#555' }}>Vérification du lien...</p>
            </div>
          </div>
        </div>
        <style>{`@keyframes spin { from { transform: rotate(0deg); } to { transform: rotate(360deg); } }`}</style>
      </div>
    );
  }

  // Show error if token is invalid
  if (!tokenValid) {
    return (
      <div className="portal-page">
        <div className="portal-bg" aria-hidden="true">
          <div className="portal-bg-gradient" />
          <div className="portal-bg-pattern" />
        </div>
        <div className="portal-container">
          <div className="portal-brand">
            <div className="portal-brand-icon">
              <ChefHat size={28} />
            </div>
            <h1 className="portal-brand-name">Vite & Gourmand</h1>
          </div>
          <div className="pf-card">
            <div className="pf-body">
              <div className="pf-alert pf-alert--error">
                <AlertCircle size={16} />
                <span>{tokenError}</span>
              </div>
              <p style={{ margin: '1rem 0', color: '#666', fontSize: '0.9rem' }}>
                Si vous avez besoin de réinitialiser votre mot de passe, veuillez faire une nouvelle
                demande.
              </p>
              <Link
                to="/portal"
                className="pf-submit"
                style={{
                  textDecoration: 'none',
                  display: 'flex',
                  alignItems: 'center',
                  justifyContent: 'center',
                  gap: '0.5rem',
                }}
              >
                Retour à la connexion
              </Link>
            </div>
          </div>
        </div>
      </div>
    );
  }

  if (success) {
    return (
      <div className="portal-page">
        <div className="portal-bg" aria-hidden="true">
          <div className="portal-bg-gradient" />
          <div className="portal-bg-pattern" />
        </div>
        <div className="portal-container">
          <div className="portal-brand">
            <div className="portal-brand-icon">
              <ChefHat size={28} />
            </div>
            <h1 className="portal-brand-name">Vite & Gourmand</h1>
          </div>
          <div className="pf-card">
            <div className="pf-body">
              <div className="pf-alert pf-alert--success">
                <CheckCircle size={16} />
                <span>Mot de passe modifié avec succès ! Redirection vers la connexion...</span>
              </div>
              <Link
                to="/portal"
                className="pf-submit"
                style={{ textDecoration: 'none', marginTop: '1rem' }}
              >
                Se connecter maintenant
              </Link>
            </div>
          </div>
        </div>
      </div>
    );
  }

  return (
    <div className="portal-page">
      <div className="portal-bg" aria-hidden="true">
        <div className="portal-bg-gradient" />
        <div className="portal-bg-pattern" />
        <div className="portal-bg-orb portal-bg-orb--1" />
        <div className="portal-bg-orb portal-bg-orb--2" />
      </div>

      <div className="portal-container">
        <div className="portal-brand">
          <div className="portal-brand-icon">
            <ChefHat size={28} />
          </div>
          <h1 className="portal-brand-name">Vite & Gourmand</h1>
          <p className="portal-brand-tagline">Réinitialisation du mot de passe</p>
        </div>

        <div className="pf-card">
          <div className="pf-body">
            {error && (
              <div className="pf-alert pf-alert--error">
                <AlertCircle size={16} />
                <span>{error}</span>
              </div>
            )}

            <form onSubmit={handleSubmit} className="pf-form" noValidate>
              <p className="pf-form-desc" style={{ marginBottom: '1rem' }}>
                Créez un nouveau mot de passe sécurisé pour votre compte.
              </p>

              <div className="pf-field">
                <label htmlFor="new-password" className="pf-label">
                  Nouveau mot de passe *
                </label>
                <div className="pf-input-wrap">
                  <Lock size={16} className="pf-input-icon" />
                  <input
                    id="new-password"
                    type={showPassword ? 'text' : 'password'}
                    value={password}
                    onChange={(e) => setPassword(e.target.value)}
                    placeholder="Min. 10 caractères"
                    required
                    autoComplete="new-password"
                    className="pf-input"
                  />
                  <button
                    type="button"
                    className="pf-input-toggle"
                    onClick={() => setShowPassword(!showPassword)}
                    aria-label={showPassword ? 'Masquer' : 'Afficher'}
                  >
                    {showPassword ? <EyeOff size={16} /> : <Eye size={16} />}
                  </button>
                </div>
                {password.length > 0 && (
                  <ul className="pf-pw-checks">
                    <PwCheck ok={pwChecks.minLength} label="10 caractères minimum" />
                    <PwCheck ok={pwChecks.hasUpper} label="1 majuscule" />
                    <PwCheck ok={pwChecks.hasLower} label="1 minuscule" />
                    <PwCheck ok={pwChecks.hasDigit} label="1 chiffre" />
                    <PwCheck ok={pwChecks.hasSpecial} label="1 caractère spécial" />
                  </ul>
                )}
              </div>

              <div className="pf-field">
                <label htmlFor="confirm-password" className="pf-label">
                  Confirmer le mot de passe *
                </label>
                <div className="pf-input-wrap">
                  <Lock size={16} className="pf-input-icon" />
                  <input
                    id="confirm-password"
                    type="password"
                    value={confirmPassword}
                    onChange={(e) => setConfirmPassword(e.target.value)}
                    placeholder="Retapez votre mot de passe"
                    required
                    autoComplete="new-password"
                    className="pf-input"
                  />
                </div>
                {confirmPassword.length > 0 && password !== confirmPassword && (
                  <p className="pf-field-error">Les mots de passe ne correspondent pas</p>
                )}
              </div>

              <button type="submit" className="pf-submit" disabled={isLoading}>
                {isLoading ? (
                  'Mise à jour…'
                ) : (
                  <>
                    Définir le mot de passe <ArrowRight size={16} />
                  </>
                )}
              </button>

              <p className="pf-hint" style={{ marginTop: '1rem' }}>
                <Link to="/portal" style={{ color: '#8B4557' }}>
                  ← Retour à la connexion
                </Link>
              </p>
            </form>
          </div>
        </div>
      </div>
    </div>
  );
}

/* ── Password check component ── */
function PwCheck({ ok, label }: Readonly<{ ok: boolean; label: string }>) {
  return (
    <li className={`pf-pw-check ${ok ? 'pf-pw-check--ok' : ''}`}>
      {ok ? <CheckCircle size={12} /> : <AlertCircle size={12} />}
      <span>{label}</span>
    </li>
  );
}
