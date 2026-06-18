/**
 * Portal Page
 * Entry point for dashboard authentication
 * Elegant design matching the Vite & Gourmand graphical chart
 */

import { Navigate } from 'react-router-dom';
import { usePortalAuth } from './PortalAuthContext';
import { PortalLoginForm } from './PortalLoginForm';
import { ChefHat, UtensilsCrossed, Clock, Sparkles, Star } from 'lucide-react';
import './Portal.css';

// Restaurant ambiance image - warm, inviting
const RESTAURANT_PREVIEW =
  'https://images.unsplash.com/photo-1517248135467-4c7edcad34c4?w=900&auto=format&q=80';

export function Portal() {
  const { isAuthenticated, isLoading, user } = usePortalAuth();

  if (isLoading) {
    return <PortalLoading />;
  }

  if (isAuthenticated && user) {
    return <Navigate to={getDashboardRoute(user.role)} replace />;
  }

  return (
    <div className="portal-page portal-page--split">
      {/* Background decorations */}
      <div className="portal-bg" aria-hidden="true">
        <div className="portal-bg-gradient" />
        <div className="portal-bg-pattern" />
        <div className="portal-bg-orb portal-bg-orb--1" />
        <div className="portal-bg-orb portal-bg-orb--2" />
      </div>

      <div className="portal-split-layout">
        {/* Left side - Restaurant preview */}
        <div className="portal-preview">
          <div className="portal-preview-content">
            <div className="portal-preview-badge">
              <Star size={14} />
              <span>Expérience culinaire</span>
            </div>
            <h2 className="portal-preview-title">
              La gastronomie
              <br />
              <span className="portal-preview-title-accent">à portée de clic</span>
            </h2>
            <p className="portal-preview-desc">
              Connectez-vous pour commander vos plats préférés, gérer vos réservations et découvrir
              nos nouvelles créations du chef.
            </p>

            {/* Feature highlights */}
            <div className="portal-preview-features">
              <div className="portal-preview-feature">
                <div className="portal-preview-feature-icon">
                  <UtensilsCrossed size={20} />
                </div>
                <div>
                  <span className="portal-preview-feature-title">Menus raffinés</span>
                  <span className="portal-preview-feature-desc">Produits frais et de saison</span>
                </div>
              </div>
              <div className="portal-preview-feature">
                <div className="portal-preview-feature-icon">
                  <Clock size={20} />
                </div>
                <div>
                  <span className="portal-preview-feature-title">Livraison express</span>
                  <span className="portal-preview-feature-desc">Service rapide et soigné</span>
                </div>
              </div>
              <div className="portal-preview-feature">
                <div className="portal-preview-feature-icon">
                  <Sparkles size={20} />
                </div>
                <div>
                  <span className="portal-preview-feature-title">Points fidélité</span>
                  <span className="portal-preview-feature-desc">Récompenses exclusives</span>
                </div>
              </div>
            </div>

            {/* Restaurant image mockup */}
            <div className="portal-preview-mockup">
              <img
                src={RESTAURANT_PREVIEW}
                alt="Ambiance restaurant Vite & Gourmand"
                className="portal-preview-image"
              />
              <div className="portal-preview-image-overlay" />
            </div>
          </div>
        </div>

        {/* Right side - Login form */}
        <div className="portal-form-side">
          <div className="portal-container">
            {/* Logo + branding */}
            <div className="portal-brand">
              <div className="portal-brand-icon">
                <ChefHat size={28} />
              </div>
              <h1 className="portal-brand-name">Vite & Gourmand</h1>
              <p className="portal-brand-tagline">Votre espace personnel</p>
            </div>

            {/* Login/Register form */}
            <PortalLoginForm />

            {/* Footer */}
            <footer className="portal-page-footer">
              <a href="/">← Retour au site</a>
              <span className="portal-page-footer-sep">·</span>
              <span>© {new Date().getFullYear()} Vite & Gourmand</span>
            </footer>
          </div>
        </div>
      </div>
    </div>
  );
}

function PortalLoading() {
  return (
    <div className="portal-page portal-page--loading">
      <div className="portal-bg" aria-hidden="true">
        <div className="portal-bg-gradient" />
      </div>
      <div className="portal-container">
        <div className="portal-brand">
          <div className="portal-brand-icon portal-brand-icon--pulse">
            <ChefHat size={28} />
          </div>
          <p style={{ color: '#722F37', fontSize: '0.875rem', marginTop: '1rem' }}>Chargement…</p>
        </div>
      </div>
    </div>
  );
}

function getDashboardRoute(role: string): string {
  switch (role) {
    case 'superadmin':
    case 'admin':
    case 'employee':
    case 'customer':
      return '/dashboard';
    default:
      return '/portal';
  }
}
