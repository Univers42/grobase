/**
 * CookieBanner — discreet bottom banner shown until the user makes a choice.
 * Accessible: role="dialog", focus-trapped, dismissable only via an action
 * (no automatic close after timeout — CNIL forbids "scroll = accept").
 */
import { useEffect, useRef } from 'react';
import { useConsent } from '../../contexts/ConsentContext';
import { CookiePreferences } from './CookiePreferences';
import './CookieBanner.css';

export function CookieBanner() {
  const { shouldPrompt, isPreferencesOpen, acceptAll, rejectAll, openPreferences } = useConsent();
  const acceptBtnRef = useRef<HTMLButtonElement>(null);

  useEffect(() => {
    if (shouldPrompt && !isPreferencesOpen) {
      // Focus the most prominent action for keyboard users
      acceptBtnRef.current?.focus();
    }
  }, [shouldPrompt, isPreferencesOpen]);

  if (!shouldPrompt && !isPreferencesOpen) return null;

  return (
    <>
      {shouldPrompt && !isPreferencesOpen && (
        <dialog
          open
          className="vg-cookie-banner"
          aria-labelledby="vg-cookie-title"
          aria-describedby="vg-cookie-desc"
        >
          <div className="vg-cookie-banner__inner">
            <div className="vg-cookie-banner__text">
              <h2 id="vg-cookie-title" className="vg-cookie-banner__title">
                🍪 Cookies & vie privée
              </h2>
              <p id="vg-cookie-desc" className="vg-cookie-banner__desc">
                Nous utilisons des cookies pour faire fonctionner le site, mémoriser vos préférences
                et, si vous l'acceptez, mesurer l'audience. Les cookies non essentiels ne sont
                déposés qu'avec votre accord. Vous pouvez modifier votre choix à tout moment depuis
                le pied de page.{' '}
                <a href="/mentions-legales#cookies" className="vg-cookie-banner__link">
                  En savoir plus
                </a>
              </p>
            </div>
            <div className="vg-cookie-banner__actions">
              <button
                type="button"
                className="vg-cookie-btn vg-cookie-btn--ghost"
                onClick={rejectAll}
              >
                Tout refuser
              </button>
              <button
                type="button"
                className="vg-cookie-btn vg-cookie-btn--ghost"
                onClick={openPreferences}
              >
                Personnaliser
              </button>
              <button
                ref={acceptBtnRef}
                type="button"
                className="vg-cookie-btn vg-cookie-btn--primary"
                onClick={acceptAll}
              >
                Tout accepter
              </button>
            </div>
          </div>
        </dialog>
      )}
      {isPreferencesOpen && <CookiePreferences />}
    </>
  );
}
