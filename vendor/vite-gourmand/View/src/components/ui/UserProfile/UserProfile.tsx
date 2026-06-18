/**
 * UserProfile Component
 * Displays user profile with role-based visibility
 * Uses Fly.io-inspired design patterns
 */

import { useState, useEffect } from 'react';
import { usePortalAuth } from '../../../portal_dashboard/PortalAuthContext';
import { getUserProfile, canViewDetailedProfile } from '../Search/searchService';
import type { UserProfileData, UserProfileProps } from './types';
import './UserProfile.css';

export function UserProfile({ userId, onClose, isModal = false }: Readonly<UserProfileProps>) {
  const { user: currentUser } = usePortalAuth();
  const [profile, setProfile] = useState<UserProfileData | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [accessDenied, setAccessDenied] = useState(false);

  const isSelf = String(currentUser?.id) === userId;

  useEffect(() => {
    async function loadProfile() {
      setLoading(true);
      setError(null);
      setAccessDenied(false);

      try {
        const data = await getUserProfile(userId);

        if (!data) {
          setError('Utilisateur non trouvé');
          return;
        }

        // Check visibility permissions
        const viewerRole = currentUser?.role;
        const canView = canViewDetailedProfile(viewerRole, data.role, isSelf);

        if (!canView) {
          setAccessDenied(true);
          return;
        }

        setProfile(data);
      } catch (err) {
        setError('Impossible de charger le profil');
        console.error('Load profile error:', err);
      } finally {
        setLoading(false);
      }
    }

    loadProfile();
  }, [userId, currentUser, isSelf]);

  // Close on Escape key
  useEffect(() => {
    if (!isModal) return;

    const handleEsc = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose?.();
    };

    document.addEventListener('keydown', handleEsc);
    return () => document.removeEventListener('keydown', handleEsc);
  }, [isModal, onClose]);

  const getInitials = (name: string) => {
    return name
      .split(' ')
      .map((n) => n[0])
      .join('')
      .toUpperCase()
      .slice(0, 2);
  };

  const formatDate = (dateString?: string) => {
    if (!dateString) return '—';
    return new Date(dateString).toLocaleDateString('fr-FR', {
      day: 'numeric',
      month: 'long',
      year: 'numeric',
    });
  };

  if (loading) {
    return (
      <ProfileWrapper isModal={isModal} onClose={onClose}>
        <div className="user-profile-loading">
          <div className="user-profile-spinner" />
          <span>Chargement du profil...</span>
        </div>
      </ProfileWrapper>
    );
  }

  if (error) {
    return (
      <ProfileWrapper isModal={isModal} onClose={onClose}>
        <div className="user-profile-error">
          <ErrorIcon />
          <p className="user-profile-error-message">{error}</p>
        </div>
      </ProfileWrapper>
    );
  }

  if (accessDenied) {
    return (
      <ProfileWrapper isModal={isModal} onClose={onClose}>
        <div className="user-profile-denied">
          <LockIcon />
          <h3 className="user-profile-denied-title">Accès refusé</h3>
          <p className="user-profile-denied-message">
            Vous n'avez pas les permissions nécessaires pour voir ce profil.
          </p>
        </div>
      </ProfileWrapper>
    );
  }

  if (!profile) return null;

  return (
    <ProfileWrapper isModal={isModal} onClose={onClose}>
      {isModal && onClose && (
        <button className="user-profile-close" onClick={onClose} aria-label="Fermer">
          <CloseIcon />
        </button>
      )}

      {/* Header */}
      <div className="user-profile-header">
        <div className="user-profile-avatar">
          {profile.avatar ? (
            <img src={profile.avatar} alt={profile.name} />
          ) : (
            getInitials(profile.name)
          )}
        </div>
        <div className="user-profile-info">
          <h2 className="user-profile-name">{profile.name}</h2>
          <p className="user-profile-username">@{profile.username}</p>
          <span className={`user-profile-role user-profile-role--${profile.role}`}>
            {getRoleLabel(profile.role)}
          </span>
        </div>
      </div>

      {/* Content */}
      <div className="user-profile-content">
        {/* Contact Info */}
        <section className="user-profile-section">
          <h3 className="user-profile-section-title">Informations de contact</h3>
          <div className="user-profile-grid">
            <div className="user-profile-field">
              <span className="user-profile-field-label">Email</span>
              <span className="user-profile-field-value">{profile.email}</span>
            </div>
            {profile.phone && (
              <div className="user-profile-field">
                <span className="user-profile-field-label">Téléphone</span>
                <span className="user-profile-field-value">{profile.phone}</span>
              </div>
            )}
          </div>
        </section>

        {/* Work Info (for employees/admins) */}
        {(profile.role === 'employee' || profile.role === 'admin') && (
          <section className="user-profile-section">
            <h3 className="user-profile-section-title">Informations professionnelles</h3>
            <div className="user-profile-grid">
              {profile.department && (
                <div className="user-profile-field">
                  <span className="user-profile-field-label">Département</span>
                  <span className="user-profile-field-value">{profile.department}</span>
                </div>
              )}
              {profile.position && (
                <div className="user-profile-field">
                  <span className="user-profile-field-label">Poste</span>
                  <span className="user-profile-field-value">{profile.position}</span>
                </div>
              )}
              <div className="user-profile-field">
                <span className="user-profile-field-label">Depuis le</span>
                <span className="user-profile-field-value">{formatDate(profile.joinedAt)}</span>
              </div>
              <div className="user-profile-field">
                <span className="user-profile-field-label">Dernière activité</span>
                <span className="user-profile-field-value">{formatDate(profile.lastActive)}</span>
              </div>
            </div>
          </section>
        )}

        {/* Stats (if available) */}
        {profile.stats && Object.keys(profile.stats).length > 0 && (
          <section className="user-profile-section">
            <h3 className="user-profile-section-title">Statistiques</h3>
            <div className="user-profile-stats">
              {profile.stats.ordersHandled !== undefined && (
                <div className="user-profile-stat">
                  <div className="user-profile-stat-value">{profile.stats.ordersHandled}</div>
                  <div className="user-profile-stat-label">Commandes traitées</div>
                </div>
              )}
              {profile.stats.ordersCompleted !== undefined && (
                <div className="user-profile-stat">
                  <div className="user-profile-stat-value">{profile.stats.ordersCompleted}</div>
                  <div className="user-profile-stat-label">Commandes terminées</div>
                </div>
              )}
              {profile.stats.averageRating !== undefined && (
                <div className="user-profile-stat">
                  <div className="user-profile-stat-value">
                    {profile.stats.averageRating.toFixed(1)}
                  </div>
                  <div className="user-profile-stat-label">Note moyenne</div>
                </div>
              )}
              {profile.stats.hoursWorked !== undefined && (
                <div className="user-profile-stat">
                  <div className="user-profile-stat-value">{profile.stats.hoursWorked}h</div>
                  <div className="user-profile-stat-label">Heures travaillées</div>
                </div>
              )}
            </div>
          </section>
        )}
      </div>

      {/* Actions */}
      {isSelf && (
        <div className="user-profile-actions">
          <button className="user-profile-btn user-profile-btn--secondary">
            Modifier le profil
          </button>
          <button className="user-profile-btn user-profile-btn--primary">
            Paramètres du compte
          </button>
        </div>
      )}
    </ProfileWrapper>
  );
}

// Wrapper for modal or inline display
function ProfileWrapper({
  children,
  isModal,
}: Readonly<{
  children: React.ReactNode;
  isModal: boolean;
  onClose?: () => void;
}>) {
  if (isModal) {
    return (
      <>
        <div className="user-profile-backdrop" />
        <div className="user-profile user-profile--modal">{children}</div>
      </>
    );
  }

  return <div className="user-profile">{children}</div>;
}

// Helper function for role labels
function getRoleLabel(role: string): string {
  const labels: Record<string, string> = {
    superadmin: 'Super Admin',
    admin: 'Administrateur',
    employee: 'Employé',
    customer: 'Client',
  };
  return labels[role] || role;
}

// Icons
const CloseIcon = () => (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M18 6L6 18M6 6l12 12" />
  </svg>
);

const ErrorIcon = () => (
  <svg
    className="user-profile-error-icon"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
  >
    <circle cx="12" cy="12" r="10" />
    <path d="M12 8v4M12 16h.01" />
  </svg>
);

const LockIcon = () => (
  <svg
    className="user-profile-denied-icon"
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth="2"
  >
    <rect x="3" y="11" width="18" height="11" rx="2" />
    <path d="M7 11V7a5 5 0 0110 0v4" />
  </svg>
);
