/**
 * Portal Login / Register / Forgot Password Form
 * Unified form with mode switching and password validation
 * Keeps all existing auth.ts & PortalAuthContext backend logic
 */

import { useState, useEffect, useMemo, useRef, useCallback } from 'react';
import { usePortalAuth } from './PortalAuthContext';
import { useConsent } from '../contexts/ConsentContext';
import { getGoogleConfig } from '../services/auth';
import {
  Eye,
  EyeOff,
  Mail,
  Lock,
  User,
  Phone,
  MapPin,
  ArrowRight,
  CheckCircle,
  AlertCircle,
  ChevronLeft,
} from 'lucide-react';
import './PortalLogin.css';

type Mode = 'login' | 'register' | 'forgot';

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

export function PortalLoginForm() {
  const { login, register, forgotPassword, loginWithGoogle, rememberMeData, isLoading, error } =
    usePortalAuth();

  const [mode, setMode] = useState<Mode>('login');

  // Login fields
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [showPassword, setShowPassword] = useState(false);
  const [remember, setRemember] = useState(false);

  // Register fields
  const [regNom, setRegNom] = useState('');
  const [regPrenom, setRegPrenom] = useState('');
  const [regEmail, setRegEmail] = useState('');
  const [regPhone, setRegPhone] = useState('');
  const [regAddress, setRegAddress] = useState('');
  const [regPassword, setRegPassword] = useState('');
  const [regConfirm, setRegConfirm] = useState('');
  const [showRegPassword, setShowRegPassword] = useState(false);
  const [gdprConsent, setGdprConsent] = useState(false);
  const [newsletterConsent, setNewsletterConsent] = useState(false);
  const [showRgpdModal, setShowRgpdModal] = useState(false);

  // Forgot fields
  const [forgotEmail, setForgotEmail] = useState('');

  // UI state
  const [successMsg, setSuccessMsg] = useState('');
  const [localError, setLocalError] = useState('');

  // Pre-fill remember me
  useEffect(() => {
    if (rememberMeData) {
      setEmail(rememberMeData.email);

      setRemember(true);
    }
  }, [rememberMeData]);

  // Clear messages on mode change
  useEffect(() => {
    setSuccessMsg('');

    setLocalError('');
  }, [mode]);

  // Password strength
  const pwChecks = useMemo(() => validatePassword(regPassword), [regPassword]);

  /* ── Handlers ── */

  const handleLogin = async (e: React.SubmitEvent) => {
    e.preventDefault();
    setLocalError('');
    try {
      await login(email, password, remember);
    } catch {
      // Error is in context
    }
  };

  const handleRegister = async (e: React.SubmitEvent) => {
    e.preventDefault();
    setLocalError('');

    if (!regNom.trim() || !regPrenom.trim()) {
      setLocalError('Le nom et le prénom sont obligatoires.');
      return;
    }
    if (!isPasswordValid(regPassword)) {
      setLocalError('Le mot de passe ne respecte pas les critères de sécurité.');
      return;
    }
    if (regPassword !== regConfirm) {
      setLocalError('Les mots de passe ne correspondent pas.');
      return;
    }
    if (!gdprConsent) {
      setLocalError(
        'Vous devez accepter la politique de confidentialité (RGPD) pour créer un compte.',
      );
      return;
    }

    try {
      await register({
        email: regEmail,
        password: regPassword,
        firstName: `${regPrenom.trim()} ${regNom.trim()}`,
        telephoneNumber: regPhone || undefined,
        city: regAddress || undefined,
        gdprConsent: true,
        newsletterConsent: newsletterConsent || undefined,
      });
      // On success, PortalAuthContext sets user → Portal.tsx will redirect
    } catch {
      // Error is in context
    }
  };

  const handleForgot = async (e: React.SubmitEvent) => {
    e.preventDefault();
    setLocalError('');
    if (!forgotEmail.trim()) {
      setLocalError('Veuillez entrer votre adresse email.');
      return;
    }
    try {
      await forgotPassword(forgotEmail);
      setSuccessMsg(`Un lien de réinitialisation a été envoyé avec succès à ${forgotEmail}`);
    } catch {
      setLocalError("Impossible d'envoyer l'email. Vérifiez votre adresse.");
    }
  };

  /* ── Google Identity Services (GSI) ── */
  const googleBtnRef = useRef<HTMLDivElement>(null);
  const [googleReady, setGoogleReady] = useState(false);
  // Tracks whether google.accounts.id.initialize() has already been called.
  // The GSI SDK warns when initialize() is invoked more than once, and the
  // React effect that hosts it can re-run (StrictMode, dep changes).
  const gsiInitialized = useRef(false);
  // CNIL: don't load Google's GSI script (which sets g_state cookie) until
  // the user has either accepted "functional" cookies OR explicitly clicked
  // "Activer la connexion Google" on this page.
  const { choice, openPreferences } = useConsent();
  const [googleOptIn, setGoogleOptIn] = useState(false);
  const googleScriptAllowed = choice?.functional === true || googleOptIn;

  const onGoogleCredential = useCallback(
    async (response: { credential: string }) => {
      try {
        await loginWithGoogle(response.credential);
      } catch {
        // Error handled by context
      }
    },
    [loginWithGoogle],
  );

  // Step 1: Load GSI script + initialize google.accounts.id
  // Gated on user consent — Google's GSI script sets the g_state cookie,
  // so loading it before consent would violate CNIL guidelines.
  useEffect(() => {
    if (!googleScriptAllowed) return;
    let cancelled = false;

    async function initGoogle() {
      try {
        const { clientId } = await getGoogleConfig();
        if (!clientId || cancelled) return;

        // Load GSI script if not already present
        if (!document.getElementById('google-gsi-script')) {
          const script = document.createElement('script');
          script.id = 'google-gsi-script';
          script.src = 'https://accounts.google.com/gsi/client';
          script.async = true;
          script.defer = true;
          script.onload = () => {
            if (!cancelled) initGsiClient(clientId);
          };
          document.head.appendChild(script);
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } else if ((globalThis as any).google?.accounts) {
          initGsiClient(clientId);
        }
      } catch {
        // Google config not available — hide button
      }
    }

    function initGsiClient(clientId: string) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const google = (globalThis as any).google;
      if (!google?.accounts) return;

      // Guard against double initialization (the SDK warns and only the
      // last init "wins", which silently breaks the callback).
      if (!gsiInitialized.current) {
        google.accounts.id.initialize({
          client_id: clientId,
          callback: onGoogleCredential,
          auto_select: false,
        });
        gsiInitialized.current = true;
      }
      if (!cancelled) setGoogleReady(true);
    }

    initGoogle();
    return () => {
      cancelled = true;
    };
  }, [onGoogleCredential, googleScriptAllowed]);

  // Step 2: Render the Google button once GSI is ready AND the ref div is mounted
  useEffect(() => {
    if (!googleReady || !googleBtnRef.current) return;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const google = (globalThis as any).google;
    if (!google?.accounts) return;

    googleBtnRef.current.replaceChildren();
    google.accounts.id.renderButton(googleBtnRef.current, {
      type: 'standard',
      theme: 'outline',
      size: 'large',
      text: 'continue_with',
      width: googleBtnRef.current.offsetWidth || 376,
      locale: 'fr',
    });
  }, [googleReady, mode]);

  const displayError = localError || error;

  /* ══════════════════════════════════════
     RENDER
     ══════════════════════════════════════ */

  return (
    <div className="pf-card">
      {/* ── Tab header ── */}
      <div className="pf-tabs">
        <button
          className={`pf-tab ${mode === 'login' ? 'pf-tab--active' : ''}`}
          onClick={() => setMode('login')}
          type="button"
        >
          Connexion
        </button>
        <button
          className={`pf-tab ${mode === 'register' ? 'pf-tab--active' : ''}`}
          onClick={() => setMode('register')}
          type="button"
        >
          Inscription
        </button>
      </div>

      <div className="pf-body">
        {/* Error */}
        {displayError && (
          <div className="pf-alert pf-alert--error">
            <AlertCircle size={16} />
            <span>{displayError}</span>
          </div>
        )}

        {/* Success */}
        {successMsg && (
          <div className="pf-alert pf-alert--success">
            <CheckCircle size={16} />
            <span>{successMsg}</span>
          </div>
        )}

        {/* ── LOGIN MODE ── */}
        {mode === 'login' && (
          <form onSubmit={handleLogin} className="pf-form" noValidate>
            {/* Remember me banner */}
            {email === rememberMeData?.email && (
              <div className="pf-remember-banner">
                <span>👋 Bon retour, {rememberMeData.name} !</span>
                <button
                  type="button"
                  onClick={() => {
                    setEmail('');
                    setRemember(false);
                  }}
                >
                  Changer de compte
                </button>
              </div>
            )}

            <div className="pf-field">
              <label htmlFor="login-email" className="pf-label">
                Adresse email
              </label>
              <div className="pf-input-wrap">
                <Mail size={16} className="pf-input-icon" />
                <input
                  id="login-email"
                  type="email"
                  value={email}
                  onChange={(e) => setEmail(e.target.value)}
                  placeholder="jean@exemple.fr"
                  required
                  autoComplete="email"
                  className="pf-input"
                />
              </div>
            </div>

            <div className="pf-field">
              <label htmlFor="login-pw" className="pf-label">
                Mot de passe
              </label>
              <div className="pf-input-wrap">
                <Lock size={16} className="pf-input-icon" />
                <input
                  id="login-pw"
                  type={showPassword ? 'text' : 'password'}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  placeholder="••••••••••"
                  required
                  autoComplete="current-password"
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
            </div>

            <div className="pf-row">
              <label className="pf-checkbox">
                <input
                  type="checkbox"
                  checked={remember}
                  onChange={(e) => setRemember(e.target.checked)}
                />
                <span>Se souvenir de moi</span>
              </label>
              <button type="button" className="pf-link" onClick={() => setMode('forgot')}>
                Mot de passe oublié ?
              </button>
            </div>

            <button type="submit" className="pf-submit" disabled={isLoading}>
              {isLoading ? (
                'Connexion…'
              ) : (
                <>
                  Se connecter <ArrowRight size={16} />
                </>
              )}
            </button>

            <div className="pf-divider">
              <span>ou</span>
            </div>
            {googleScriptAllowed ? (
              <div
                ref={googleBtnRef}
                className="pf-google-wrap"
                style={googleReady ? undefined : { display: 'none' }}
              />
            ) : (
              <div className="pf-google-placeholder">
                <p className="pf-google-placeholder__text">
                  La connexion via Google nécessite votre accord (un cookie sera déposé
                  par Google).
                </p>
                <div className="pf-google-placeholder__actions">
                  <button
                    type="button"
                    className="pf-google-placeholder__btn pf-google-placeholder__btn--primary"
                    onClick={() => setGoogleOptIn(true)}
                  >
                    Activer la connexion Google
                  </button>
                  <button
                    type="button"
                    className="pf-google-placeholder__btn pf-google-placeholder__btn--ghost"
                    onClick={openPreferences}
                  >
                    Gérer mes cookies
                  </button>
                </div>
              </div>
            )}
          </form>
        )}

        {/* ── REGISTER MODE ── */}
        {mode === 'register' && (
          <form onSubmit={handleRegister} className="pf-form" noValidate>
            {/* Nom + Prénom */}
            <div className="pf-row-2">
              <div className="pf-field">
                <label htmlFor="reg-prenom" className="pf-label">
                  Prénom *
                </label>
                <div className="pf-input-wrap">
                  <User size={16} className="pf-input-icon" />
                  <input
                    id="reg-prenom"
                    type="text"
                    value={regPrenom}
                    onChange={(e) => setRegPrenom(e.target.value)}
                    placeholder="Jean"
                    required
                    className="pf-input"
                    autoComplete="given-name"
                  />
                </div>
              </div>
              <div className="pf-field">
                <label htmlFor="reg-nom" className="pf-label">
                  Nom *
                </label>
                <div className="pf-input-wrap">
                  <User size={16} className="pf-input-icon" />
                  <input
                    id="reg-nom"
                    type="text"
                    value={regNom}
                    onChange={(e) => setRegNom(e.target.value)}
                    placeholder="Dupont"
                    required
                    className="pf-input"
                    autoComplete="family-name"
                  />
                </div>
              </div>
            </div>

            {/* Email */}
            <div className="pf-field">
              <label htmlFor="reg-email" className="pf-label">
                Adresse email *
              </label>
              <div className="pf-input-wrap">
                <Mail size={16} className="pf-input-icon" />
                <input
                  id="reg-email"
                  type="email"
                  value={regEmail}
                  onChange={(e) => setRegEmail(e.target.value)}
                  placeholder="jean@exemple.fr"
                  required
                  className="pf-input"
                  autoComplete="email"
                />
              </div>
            </div>

            {/* GSM */}
            <div className="pf-field">
              <label htmlFor="reg-phone" className="pf-label">
                Numéro de GSM
              </label>
              <div className="pf-input-wrap">
                <Phone size={16} className="pf-input-icon" />
                <input
                  id="reg-phone"
                  type="tel"
                  value={regPhone}
                  onChange={(e) => setRegPhone(e.target.value)}
                  placeholder="06 12 34 56 78"
                  className="pf-input"
                  autoComplete="tel"
                />
              </div>
            </div>

            {/* Adresse postale */}
            <div className="pf-field">
              <label htmlFor="reg-addr" className="pf-label">
                Adresse postale
              </label>
              <div className="pf-input-wrap">
                <MapPin size={16} className="pf-input-icon" />
                <input
                  id="reg-addr"
                  type="text"
                  value={regAddress}
                  onChange={(e) => setRegAddress(e.target.value)}
                  placeholder="15 Rue Sainte-Catherine, 33000 Bordeaux"
                  className="pf-input"
                  autoComplete="street-address"
                />
              </div>
            </div>

            {/* Password */}
            <div className="pf-field">
              <label htmlFor="reg-pw" className="pf-label">
                Mot de passe *
              </label>
              <div className="pf-input-wrap">
                <Lock size={16} className="pf-input-icon" />
                <input
                  id="reg-pw"
                  type={showRegPassword ? 'text' : 'password'}
                  value={regPassword}
                  onChange={(e) => setRegPassword(e.target.value)}
                  placeholder="Min. 10 caractères"
                  required
                  className="pf-input"
                  autoComplete="new-password"
                />
                <button
                  type="button"
                  className="pf-input-toggle"
                  onClick={() => setShowRegPassword(!showRegPassword)}
                  aria-label={showRegPassword ? 'Masquer' : 'Afficher'}
                >
                  {showRegPassword ? <EyeOff size={16} /> : <Eye size={16} />}
                </button>
              </div>
              {/* Password strength indicators */}
              {regPassword.length > 0 && (
                <ul className="pf-pw-checks">
                  <PwCheck ok={pwChecks.minLength} label="10 caractères minimum" />
                  <PwCheck ok={pwChecks.hasUpper} label="1 majuscule" />
                  <PwCheck ok={pwChecks.hasLower} label="1 minuscule" />
                  <PwCheck ok={pwChecks.hasDigit} label="1 chiffre" />
                  <PwCheck ok={pwChecks.hasSpecial} label="1 caractère spécial" />
                </ul>
              )}
            </div>

            {/* Confirm password */}
            <div className="pf-field">
              <label htmlFor="reg-confirm" className="pf-label">
                Confirmer le mot de passe *
              </label>
              <div className="pf-input-wrap">
                <Lock size={16} className="pf-input-icon" />
                <input
                  id="reg-confirm"
                  type="password"
                  value={regConfirm}
                  onChange={(e) => setRegConfirm(e.target.value)}
                  placeholder="Retapez votre mot de passe"
                  required
                  className="pf-input"
                  autoComplete="new-password"
                />
              </div>
              {regConfirm.length > 0 && regPassword !== regConfirm && (
                <p className="pf-field-error">Les mots de passe ne correspondent pas</p>
              )}
            </div>

            {/* ── RGPD Consent (required) ── */}
            <div className="pf-consent-section">
              <label className="pf-checkbox pf-checkbox--consent">
                <input
                  type="checkbox"
                  checked={gdprConsent}
                  onChange={(e) => setGdprConsent(e.target.checked)}
                  required
                />
                <span>
                  J'accepte la{' '}
                  <a
                    href="#legal-mentions"
                    className="pf-link pf-link--inline"
                    onClick={(e) => {
                      e.preventDefault();
                      // Open the RGPD modal overlay
                      setShowRgpdModal(true);
                    }}
                  >
                    politique de confidentialité
                  </a>{' '}
                  et le traitement de mes données personnelles conformément au RGPD. *
                </span>
              </label>

              {/* Newsletter opt-in (optional) */}
              <label className="pf-checkbox pf-checkbox--consent pf-checkbox--newsletter">
                <input
                  type="checkbox"
                  checked={newsletterConsent}
                  onChange={(e) => setNewsletterConsent(e.target.checked)}
                />
                <span>
                  📬 Je souhaite recevoir la newsletter avec les actualités, menus et promotions de
                  Vite & Gourmand.
                </span>
              </label>
            </div>

            <button type="submit" className="pf-submit" disabled={isLoading}>
              {isLoading ? (
                'Création…'
              ) : (
                <>
                  Créer mon compte <ArrowRight size={16} />
                </>
              )}
            </button>

            <p className="pf-hint">
              En vous inscrivant, vous acceptez notre politique de confidentialité. Le rôle «
              utilisateur » vous sera attribué.
            </p>
          </form>
        )}

        {/* ── FORGOT MODE ── */}
        {mode === 'forgot' && (
          <form onSubmit={handleForgot} className="pf-form" noValidate>
            <button type="button" className="pf-back" onClick={() => setMode('login')}>
              <ChevronLeft size={16} /> Retour à la connexion
            </button>

            <h2 className="pf-form-title">Mot de passe oublié ?</h2>
            <p className="pf-form-desc">
              Entrez votre adresse email. Vous recevrez un lien pour réinitialiser votre mot de
              passe.
            </p>

            <div className="pf-field">
              <label htmlFor="forgot-email" className="pf-label">
                Adresse email
              </label>
              <div className="pf-input-wrap">
                <Mail size={16} className="pf-input-icon" />
                <input
                  id="forgot-email"
                  type="email"
                  value={forgotEmail}
                  onChange={(e) => setForgotEmail(e.target.value)}
                  placeholder="jean@exemple.fr"
                  required
                  className="pf-input"
                  autoComplete="email"
                />
              </div>
            </div>

            <button type="submit" className="pf-submit" disabled={isLoading}>
              {isLoading ? (
                'Envoi…'
              ) : (
                <>
                  Envoyer le lien <ArrowRight size={16} />
                </>
              )}
            </button>
          </form>
        )}
      </div>

      {/* ── RGPD Modal Overlay ── */}
      {showRgpdModal && (
        <dialog
          className="pf-rgpd-overlay"
          aria-label="Politique de confidentialité RGPD"
          onCancel={() => setShowRgpdModal(false)}
          open
        >
          <div className="pf-rgpd-modal">
            <div className="pf-rgpd-header">
              <h2 className="pf-rgpd-title">🔒 Politique de Confidentialité &amp; RGPD</h2>
              <button
                type="button"
                className="pf-rgpd-close"
                onClick={() => setShowRgpdModal(false)}
                aria-label="Fermer"
              >
                ✕
              </button>
            </div>
            <div className="pf-rgpd-body">
              <p className="pf-rgpd-intro">
                Conformément au Règlement (UE) 2016/679 du Parlement européen et du Conseil du 27
                avril 2016 (Règlement Général sur la Protection des Données — RGPD) et à la loi
                n°78-17 du 6 janvier 1978 modifiée dite « Informatique et Libertés », la société
                Vite &amp; Gourmand s'engage à protéger vos données personnelles.
              </p>

              <section className="pf-rgpd-section">
                <h3>1. Responsable du traitement</h3>
                <p>
                  <strong>Vite &amp; Gourmand</strong> — Entreprise individuelle
                  <br />
                  15 Rue Sainte-Catherine, 33000 Bordeaux
                  <br />
                  Email : <em>rgpd@vite-gourmand.fr</em>
                  <br />
                  Tél. : +33 5 56 00 00 00
                  <br />
                  Directeurs de la publication : Julie et José Martinez
                </p>
              </section>

              <section className="pf-rgpd-section">
                <h3>2. Données personnelles collectées</h3>
                <p>Dans le cadre de l'utilisation du site et de nos services, nous collectons :</p>
                <ul>
                  <li>
                    <strong>Données d'identification :</strong> nom, prénom, adresse email, numéro
                    de téléphone, adresse postale
                  </li>
                  <li>
                    <strong>Données de connexion :</strong> adresse IP, logs de connexion,
                    horodatage, type de navigateur et système d'exploitation
                  </li>
                  <li>
                    <strong>Données de commande :</strong> historique des commandes, préférences
                    alimentaires, allergènes déclarés, montants des achats
                  </li>
                  <li>
                    <strong>Données de navigation :</strong> pages visitées, durée de visite,
                    interactions avec le site (cookies techniques)
                  </li>
                  <li>
                    <strong>Données de communication :</strong> messages envoyés via le formulaire
                    de contact, échanges avec le support ou l'assistant IA
                  </li>
                  <li>
                    <strong>Données de fidélité :</strong> points accumulés, historique des
                    récompenses, code d'affiliation
                  </li>
                  <li>
                    <strong>Données newsletter :</strong> consentement newsletter, adresse email
                    d'inscription, date d'inscription et préférences de communication
                  </li>
                </ul>
              </section>

              <section className="pf-rgpd-section">
                <h3>3. Bases légales et finalités du traitement</h3>
                <table className="pf-rgpd-table">
                  <thead>
                    <tr>
                      <th>Finalité</th>
                      <th>Base légale</th>
                      <th>Durée de conservation</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr>
                      <td>Gestion des comptes utilisateurs</td>
                      <td>Exécution du contrat (Art. 6.1.b)</td>
                      <td>Durée du compte + 3 ans</td>
                    </tr>
                    <tr>
                      <td>Traitement et suivi des commandes</td>
                      <td>Exécution du contrat (Art. 6.1.b)</td>
                      <td>5 ans (obligation comptable)</td>
                    </tr>
                    <tr>
                      <td>Programme de fidélité et affiliation</td>
                      <td>Consentement (Art. 6.1.a)</td>
                      <td>Durée du compte + 1 an</td>
                    </tr>
                    <tr>
                      <td>Envoi de newsletters et promotions</td>
                      <td>Consentement explicite (Art. 6.1.a)</td>
                      <td>Jusqu'au retrait du consentement</td>
                    </tr>
                    <tr>
                      <td>Réponse aux demandes de contact</td>
                      <td>Intérêt légitime (Art. 6.1.f)</td>
                      <td>1 an après le dernier échange</td>
                    </tr>
                    <tr>
                      <td>Assistant IA (chatbot)</td>
                      <td>Consentement (Art. 6.1.a)</td>
                      <td>Durée de la session</td>
                    </tr>
                    <tr>
                      <td>Sécurité et prévention des fraudes</td>
                      <td>Intérêt légitime (Art. 6.1.f)</td>
                      <td>12 mois glissants</td>
                    </tr>
                    <tr>
                      <td>Obligations légales et fiscales</td>
                      <td>Obligation légale (Art. 6.1.c)</td>
                      <td>10 ans (documents comptables)</td>
                    </tr>
                  </tbody>
                </table>
              </section>

              <section className="pf-rgpd-section">
                <h3>4. Destinataires des données</h3>
                <p>Vos données sont traitées par :</p>
                <ul>
                  <li>
                    <strong>Personnel interne :</strong> équipe de direction, service client, équipe
                    technique — accès limité au strict nécessaire
                  </li>
                  <li>
                    <strong>Hébergeur :</strong> infrastructure cloud sécurisée, serveurs situés en
                    Union Européenne (conformité RGPD)
                  </li>
                  <li>
                    <strong>Prestataire base de données :</strong> Supabase (PostgreSQL managé,
                    données chiffrées au repos et en transit, certifié SOC2)
                  </li>
                  <li>
                    <strong>Prestataire IA :</strong> Groq (modèle LLaMA) — les conversations ne
                    sont ni stockées ni utilisées pour l'entraînement
                  </li>
                  <li>
                    <strong>Service email :</strong> prestataire SMTP pour l'envoi transactionnel et
                    newsletters — aucune revente de données
                  </li>
                </ul>
                <p className="pf-rgpd-note">
                  ⚠️ Aucune donnée n'est transférée hors de l'Espace Économique Européen (EEE).
                  Aucune donnée n'est vendue, louée ou cédée à des tiers à des fins commerciales.
                </p>
              </section>

              <section className="pf-rgpd-section">
                <h3>5. Vos droits</h3>
                <p>
                  Conformément aux articles 15 à 22 du RGPD, vous disposez des droits suivants :
                </p>
                <ul>
                  <li>
                    <strong>Droit d'accès (Art. 15) :</strong> obtenir la confirmation que vos
                    données sont traitées et en recevoir une copie
                  </li>
                  <li>
                    <strong>Droit de rectification (Art. 16) :</strong> corriger des données
                    inexactes ou compléter des données incomplètes
                  </li>
                  <li>
                    <strong>Droit à l'effacement (Art. 17) :</strong> demander la suppression de vos
                    données (« droit à l'oubli »)
                  </li>
                  <li>
                    <strong>Droit à la limitation (Art. 18) :</strong> restreindre le traitement de
                    vos données dans certains cas
                  </li>
                  <li>
                    <strong>Droit à la portabilité (Art. 20) :</strong> recevoir vos données dans un
                    format structuré, couramment utilisé et lisible par machine
                  </li>
                  <li>
                    <strong>Droit d'opposition (Art. 21) :</strong> vous opposer au traitement de
                    vos données, notamment à des fins de prospection commerciale
                  </li>
                  <li>
                    <strong>Droit de retirer votre consentement :</strong> à tout moment, sans
                    affecter la licéité du traitement antérieur
                  </li>
                  <li>
                    <strong>Droit d'introduire une réclamation :</strong> auprès de la CNIL
                    (Commission Nationale de l'Informatique et des Libertés) — <em>www.cnil.fr</em>
                  </li>
                </ul>
                <p>
                  Pour exercer vos droits, envoyez un email à <strong>rgpd@vite-gourmand.fr</strong>{' '}
                  avec une copie d'une pièce d'identité. Nous nous engageons à répondre dans un
                  délai maximum de 30 jours.
                </p>
              </section>

              <section className="pf-rgpd-section">
                <h3>6. Cookies</h3>
                <p>
                  Notre site utilise exclusivement des <strong>cookies techniques</strong>{' '}
                  nécessaires au bon fonctionnement de l'application :
                </p>
                <ul>
                  <li>
                    <strong>Cookie de session :</strong> maintien de votre connexion durant la
                    navigation (durée : session)
                  </li>
                  <li>
                    <strong>Cookie « Se souvenir de moi » :</strong> persistance de la connexion si
                    activé (durée : 30 jours)
                  </li>
                  <li>
                    <strong>Token JWT :</strong> authentification sécurisée des requêtes API (durée
                    : 24h)
                  </li>
                </ul>
                <p className="pf-rgpd-note">
                  🚫 Aucun cookie publicitaire, de tracking ou d'analyse comportementale n'est
                  utilisé. Aucun outil de type Google Analytics, Facebook Pixel ou similaire n'est
                  installé.
                </p>
              </section>

              <section className="pf-rgpd-section">
                <h3>7. Sécurité des données</h3>
                <p>
                  Nous mettons en œuvre les mesures techniques et organisationnelles suivantes :
                </p>
                <ul>
                  <li>Chiffrement TLS/SSL de toutes les communications (HTTPS)</li>
                  <li>Mots de passe hashés avec bcrypt (12 rounds de salage)</li>
                  <li>Authentification JWT avec expiration et refresh tokens</li>
                  <li>
                    Politique de mots de passe robuste : 10 caractères min., majuscules, minuscules,
                    chiffres et caractères spéciaux
                  </li>
                  <li>
                    Row Level Security (RLS) sur la base de données — chaque utilisateur n'accède
                    qu'à ses propres données
                  </li>
                  <li>Contrôle d'accès par rôles (RBAC) : client, manager, admin, superadmin</li>
                  <li>Protection CSRF, rate limiting et validation stricte des entrées</li>
                  <li>Sauvegardes automatiques régulières des bases de données</li>
                </ul>
              </section>

              <section className="pf-rgpd-section">
                <h3>8. Modifications de la politique</h3>
                <p>
                  Nous nous réservons le droit de modifier cette politique de confidentialité à tout
                  moment. En cas de modification substantielle, vous serez informé(e) par email ou
                  via une notification sur le site. La version en vigueur est toujours accessible
                  depuis le pied de page du site et le portail de connexion.
                </p>
                <p className="pf-rgpd-updated">
                  <strong>Dernière mise à jour :</strong> Février 2026
                </p>
              </section>

              <section className="pf-rgpd-section pf-rgpd-contact">
                <h3>9. Contact DPO</h3>
                <p>
                  Pour toute question relative à la protection de vos données personnelles :<br />
                  📧 <strong>rgpd@vite-gourmand.fr</strong>
                  <br />
                  📮 Vite &amp; Gourmand — Service RGPD, 15 Rue Sainte-Catherine, 33000 Bordeaux
                  <br />
                  📞 +33 5 56 00 00 00
                </p>
              </section>
            </div>
            <div className="pf-rgpd-footer">
              <button
                type="button"
                className="pf-rgpd-accept"
                onClick={() => setShowRgpdModal(false)}
              >
                J'ai lu et compris
              </button>
            </div>
          </div>
        </dialog>
      )}
    </div>
  );
}

/* ── Small components ── */

function PwCheck({ ok, label }: Readonly<{ ok: boolean; label: string }>) {
  return (
    <li className={`pf-pw-check ${ok ? 'pf-pw-check--ok' : ''}`}>
      {ok ? <CheckCircle size={12} /> : <AlertCircle size={12} />}
      <span>{label}</span>
    </li>
  );
}
