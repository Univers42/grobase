/**
 * CookiePreferences — modal allowing per-category opt-in.
 * Defaults to the most restrictive choice (only necessary on), per CNIL.
 */
import { useEffect, useRef, useState } from 'react';
import { useConsent } from '../../contexts/ConsentContext';

interface CategoryDef {
  key: 'functional' | 'analytics' | 'marketing';
  title: string;
  desc: string;
  examples: string;
}

const CATEGORIES: CategoryDef[] = [
  {
    key: 'functional',
    title: 'Fonctionnels',
    desc: 'Mémorisent vos préférences (langue, thème, vues récentes) pour personnaliser votre navigation.',
    examples: 'Préférence de thème, langue, vue tableau/grille du tableau de bord.',
  },
  {
    key: 'analytics',
    title: "Mesure d'audience",
    desc: "Nous aident à comprendre comment le site est utilisé pour l'améliorer (statistiques agrégées, anonymisées).",
    examples: 'Pages visitées, temps passé, parcours utilisateur — données anonymisées.',
  },
  {
    key: 'marketing',
    title: 'Publicité & marketing',
    desc: "Personnalisent les contenus promotionnels et mesurent l'efficacité de nos campagnes.",
    examples: 'Suivi de conversion, retargeting, audiences personnalisées.',
  },
];

export function CookiePreferences() {
  const { choice, saveCustom, acceptAll, rejectAll, closePreferences } = useConsent();
  const [draft, setDraft] = useState({
    functional: choice?.functional ?? false,
    analytics: choice?.analytics ?? false,
    marketing: choice?.marketing ?? false,
  });
  const modalRef = useRef<HTMLDialogElement>(null);
  const lastFocusRef = useRef<HTMLElement | null>(null);

  useEffect(() => {
    lastFocusRef.current = document.activeElement as HTMLElement | null;
    // Lock scroll while modal is open
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    modalRef.current?.focus();
    return () => {
      document.body.style.overflow = previousOverflow;
      lastFocusRef.current?.focus();
    };
  }, []);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') closePreferences();
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [closePreferences]);

  return (
    <dialog
      open
      ref={modalRef}
      tabIndex={-1}
      className="vg-cookie-modal-overlay"
      aria-labelledby="vg-cookie-pref-title"
    >
      <div className="vg-cookie-modal">
        <header className="vg-cookie-modal__header">
          <h2 id="vg-cookie-pref-title">🍪 Préférences de cookies</h2>
          <button
            type="button"
            className="vg-cookie-modal__close"
            onClick={closePreferences}
            aria-label="Fermer"
          >
            ×
          </button>
        </header>

        <div className="vg-cookie-modal__body">
          <p className="vg-cookie-modal__intro">
            Vous contrôlez précisément quelles catégories de cookies sont utilisées. Les cookies <strong>nécessaires</strong> au fonctionnement du site sont toujours actifs et ne peuvent pas être désactivés.
          </p>

          <div className="vg-cookie-row vg-cookie-row--locked">
            <div className="vg-cookie-row__main">
              <h3>
                Nécessaires <span className="vg-cookie-badge">Toujours actif</span>
              </h3>
              <p>
                Indispensables au fonctionnement du site : authentification, panier, sécurité
                (CSRF), session. Sans eux, le site ne peut pas fonctionner.
              </p>
              <small>Exemples : jeton de session JWT, cookie CSRF, préférence de langue.</small>
            </div>
            <input
              type="checkbox"
              checked
              disabled
              aria-label="Cookies nécessaires (toujours actif)"
            />
          </div>

          {CATEGORIES.map((cat) => (
            <div key={cat.key} className="vg-cookie-row">
              <div className="vg-cookie-row__main">
                <h3>{cat.title}</h3>
                <p>{cat.desc}</p>
                <small>Exemples : {cat.examples}</small>
              </div>
              <label className="vg-cookie-switch">
                <input
                  type="checkbox"
                  checked={draft[cat.key]}
                  onChange={(e) => setDraft((d) => ({ ...d, [cat.key]: e.target.checked }))}
                  aria-label={`Activer les cookies ${cat.title.toLowerCase()}`}
                />
                <span aria-hidden="true" />
              </label>
            </div>
          ))}
        </div>

        <footer className="vg-cookie-modal__footer">
          <button type="button" className="vg-cookie-btn vg-cookie-btn--ghost" onClick={rejectAll}>
            Tout refuser
          </button>
          <button
            type="button"
            className="vg-cookie-btn vg-cookie-btn--primary"
            onClick={() => saveCustom(draft)}
          >
            Enregistrer mes choix
          </button>
          <button
            type="button"
            className="vg-cookie-btn vg-cookie-btn--primary"
            onClick={acceptAll}
          >
            Tout accepter
          </button>
        </footer>
      </div>
    </dialog>
  );
}
