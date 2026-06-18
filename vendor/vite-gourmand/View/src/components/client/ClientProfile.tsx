/**
 * ClientProfile - Full user profile management
 * Connected to Supabase via PUT /api/users/me (camelCase DTO)
 * Displays all user fields from the database
 */

import { useState, useEffect, useCallback } from 'react';
import { usePortalAuth } from '../../portal_dashboard';
import { apiRequest } from '../../services/api';
import { AiAssistantWidget } from '../ui/AiAssistantWidget';
import './ClientWidgets.css';

/* ──────────────────────────────────────────────
   Types — match the backend sanitize() response
   ────────────────────────────────────────────── */
interface UserProfile {
  id: number;
  email: string;
  firstName: string | null;
  lastName: string | null;
  phoneNumber: string | null;
  city: string | null;
  postalCode: string | null;
  country: string | null;
  preferredLanguage: string | null;
  isActive: boolean | null;
  isEmailVerified: boolean | null;
  gdprConsent: boolean | null;
  marketingConsent: boolean | null;
  createdAt: string | null;
  updatedAt: string | null;
  lastLoginAt: string | null;
  role: string;
  loyaltyAccount: { id: number; points: number; tier: string } | null;
}

interface Address {
  id: number;
  label: string;
  street_address: string;
  city: string;
  postal_code: string;
  country: string;
  is_default: boolean;
}

/* camelCase keys matching UpdateProfileDto */
interface ProfileForm {
  firstName: string;
  lastName: string;
  phoneNumber: string;
  city: string;
  postalCode: string;
  country: string;
  preferredLanguage: string;
}

/* ──────────────────────────────────────────────
   Component
   ────────────────────────────────────────────── */
export function ClientProfile() {
  const { user } = usePortalAuth();
  const [profile, setProfile] = useState<UserProfile | null>(null);
  const [addresses, setAddresses] = useState<Address[]>([]);
  const [loading, setLoading] = useState(true);
  const [editing, setEditing] = useState(false);
  const [saving, setSaving] = useState(false);
  const [success, setSuccess] = useState('');
  const [error, setError] = useState('');
  const [activeTab, setActiveTab] = useState<'info' | 'addresses' | 'security'>('info');
  const [form, setForm] = useState<ProfileForm>({
    firstName: '',
    lastName: '',
    phoneNumber: '',
    city: '',
    postalCode: '',
    country: '',
    preferredLanguage: 'fr',
  });

  const fetchProfile = useCallback(async () => {
    try {
      const [profileRes, addrRes] = await Promise.all([
        apiRequest<{ data: UserProfile }>('/api/users/me'),
        apiRequest<{ data: Address[] }>('/api/users/me/addresses').catch(() => ({ data: [] })),
      ]);
      const p = profileRes.data;
      setProfile(p);
      setAddresses(Array.isArray(addrRes.data) ? addrRes.data : []);
      setForm({
        firstName: p.firstName || '',
        lastName: p.lastName || '',
        phoneNumber: p.phoneNumber || '',
        city: p.city || '',
        postalCode: p.postalCode || '',
        country: p.country || 'France',
        preferredLanguage: p.preferredLanguage || 'fr',
      });
    } catch {
      setError('Impossible de charger le profil.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    fetchProfile();
  }, [fetchProfile]);

  async function handleSave(e: React.SubmitEvent<HTMLFormElement>) {
    e.preventDefault();
    setSaving(true);
    setError('');
    try {
      const res = await apiRequest<{ data: UserProfile }>('/api/users/me', {
        method: 'PUT',
        body: form, // camelCase — matches UpdateProfileDto exactly
      });
      setProfile(res.data);
      setEditing(false);
      setSuccess('Profil mis à jour avec succès !');
      setTimeout(() => setSuccess(''), 4000);
    } catch {
      setError('Erreur lors de la sauvegarde. Veuillez réessayer.');
    } finally {
      setSaving(false);
    }
  }

  function handleCancel() {
    if (profile) {
      setForm({
        firstName: profile.firstName || '',
        lastName: profile.lastName || '',
        phoneNumber: profile.phoneNumber || '',
        city: profile.city || '',
        postalCode: profile.postalCode || '',
        country: profile.country || 'France',
        preferredLanguage: profile.preferredLanguage || 'fr',
      });
    }
    setEditing(false);
    setError('');
  }

  /* ── Loading ── */
  if (loading) {
    return (
      <div className="client-widget">
        <div className="client-loading">
          <div className="client-loading-spinner" />
          <p>Chargement du profil…</p>
        </div>
      </div>
    );
  }

  const displayName = getDisplayName(profile, user?.name);
  const memberSince = formatProfileDate(profile?.createdAt, 'long');
  const lastLogin = formatProfileDate(profile?.lastLoginAt, 'datetime');
  const activeStatus = getBooleanDisplay(profile?.isActive, '✅', '❌', 'Actif', 'Inactif');
  const emailStatus = getBooleanDisplay(profile?.isEmailVerified, '✅', '⏳', 'Vérifié', 'Non vérifié');
  const gdprStatus = getBooleanDisplay(profile?.gdprConsent, '✅', '❌', 'Accepté', 'Non accepté');
  const marketingStatus = getBooleanDisplay(profile?.marketingConsent, '✅', '❌', 'Activé', 'Désactivé');

  return (
    <div className="client-widget">
      {/* ── Banners ── */}
      {success && <div className="client-success-banner">✅ {success}</div>}
      {error && <div className="profile-error-banner">⚠️ {error}</div>}

      {/* ── Hero Card ── */}
      <div className="profile-hero-card">
        <div className="profile-hero-card-bg" />
        <div className="profile-hero-card-content">
          <div className="profile-avatar-large">
            {getInitials(profile?.firstName, profile?.lastName, user?.name)}
          </div>
          <div className="profile-hero-info">
            <h2 className="profile-hero-name">{displayName}</h2>
            <div className="profile-hero-meta">
              <span className="profile-meta-item">📧 {profile?.email || user?.email}</span>
              {memberSince && (
                <span className="profile-meta-item">📅 Membre depuis {memberSince}</span>
              )}
              {profile?.role && (
                <span className="profile-role-badge">
                  {formatProfileRole(profile.role)}
                </span>
              )}
            </div>
            {profile?.loyaltyAccount && (
              <div className="profile-loyalty-inline">
                <span className="profile-loyalty-tier">
                  {getTierEmoji(profile.loyaltyAccount.tier)} {profile.loyaltyAccount.tier}
                </span>
                <span className="profile-loyalty-pts">
                  {profile.loyaltyAccount.points.toLocaleString('fr-FR')} pts
                </span>
              </div>
            )}
          </div>
          <div className="profile-hero-actions">
            {!editing && (
              <button className="btn btn-primary" onClick={() => setEditing(true)}>
                ✏️ Modifier mon profil
              </button>
            )}
          </div>
        </div>
      </div>

      {/* ── Tab Navigation ── */}
      <div className="client-tabs">
        <button
          className={`client-tab ${activeTab === 'info' ? 'active' : ''}`}
          onClick={() => setActiveTab('info')}
        >
          📋 Informations
        </button>
        <button
          className={`client-tab ${activeTab === 'addresses' ? 'active' : ''}`}
          onClick={() => setActiveTab('addresses')}
        >
          📍 Adresses
          {addresses.length > 0 && <span className="client-tab-badge">{addresses.length}</span>}
        </button>
        <button
          className={`client-tab ${activeTab === 'security' ? 'active' : ''}`}
          onClick={() => setActiveTab('security')}
        >
          🔒 Sécurité & Confidentialité
        </button>
      </div>

      {/* ══════════════════════════════════════════
          TAB: Informations personnelles
          ══════════════════════════════════════════ */}
      {activeTab === 'info' && (
        <>
          {editing ? (
            <form className="profile-edit-card" onSubmit={handleSave}>
              <div className="profile-edit-card-header">
                <h3>✏️ Modifier mes informations</h3>
                <p className="profile-edit-subtitle">
                  Les modifications seront sauvegardées dans la base de données.
                </p>
              </div>

              <div className="profile-form-grid">
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-first">
                    Prénom
                  </label>
                  <input
                    id="pf-first"
                    className="client-input"
                    type="text"
                    value={form.firstName}
                    onChange={(e) => setForm({ ...form, firstName: e.target.value })}
                    placeholder="Votre prénom"
                    autoComplete="given-name"
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-last">
                    Nom
                  </label>
                  <input
                    id="pf-last"
                    className="client-input"
                    type="text"
                    value={form.lastName}
                    onChange={(e) => setForm({ ...form, lastName: e.target.value })}
                    placeholder="Votre nom"
                    autoComplete="family-name"
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-phone">
                    Téléphone
                  </label>
                  <input
                    id="pf-phone"
                    className="client-input"
                    type="tel"
                    value={form.phoneNumber}
                    onChange={(e) => setForm({ ...form, phoneNumber: e.target.value })}
                    placeholder="+33 6 12 34 56 78"
                    autoComplete="tel"
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-city">
                    Ville
                  </label>
                  <input
                    id="pf-city"
                    className="client-input"
                    type="text"
                    value={form.city}
                    onChange={(e) => setForm({ ...form, city: e.target.value })}
                    placeholder="Paris"
                    autoComplete="address-level2"
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-postal">
                    Code postal
                  </label>
                  <input
                    id="pf-postal"
                    className="client-input"
                    type="text"
                    value={form.postalCode}
                    onChange={(e) => setForm({ ...form, postalCode: e.target.value })}
                    placeholder="75001"
                    autoComplete="postal-code"
                    maxLength={10}
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-country">
                    Pays
                  </label>
                  <input
                    id="pf-country"
                    className="client-input"
                    type="text"
                    value={form.country}
                    onChange={(e) => setForm({ ...form, country: e.target.value })}
                    placeholder="France"
                    autoComplete="country-name"
                  />
                </div>
                <div className="client-form-group">
                  <label className="client-label" htmlFor="pf-lang">
                    Langue préférée
                  </label>
                  <select
                    id="pf-lang"
                    className="client-select"
                    value={form.preferredLanguage}
                    onChange={(e) => setForm({ ...form, preferredLanguage: e.target.value })}
                  >
                    <option value="fr">🇫🇷 Français</option>
                    <option value="en">🇬🇧 English</option>
                  </select>
                </div>
              </div>

              <div className="profile-form-actions">
                <button type="button" className="btn btn-secondary" onClick={handleCancel}>
                  Annuler
                </button>
                <button type="submit" className="btn btn-primary" disabled={saving}>
                  {saving ? '⏳ Enregistrement…' : '💾 Sauvegarder'}
                </button>
              </div>
            </form>
          ) : (
            <div className="profile-info-card">
              <div className="profile-info-card-header">
                <h3>📋 Informations personnelles</h3>
              </div>
              <div className="profile-fields-grid">
                <ProfileField icon="👤" label="Prénom" value={profile?.firstName} />
                <ProfileField icon="👤" label="Nom" value={profile?.lastName} />
                <ProfileField icon="📧" label="Email" value={profile?.email} />
                <ProfileField icon="📱" label="Téléphone" value={profile?.phoneNumber} />
                <ProfileField icon="🏙️" label="Ville" value={profile?.city} />
                <ProfileField icon="📮" label="Code postal" value={profile?.postalCode} />
                <ProfileField icon="🌍" label="Pays" value={profile?.country} />
                <ProfileField
                  icon="🗣️"
                  label="Langue"
                  value={formatLanguage(profile?.preferredLanguage)}
                />
              </div>

              {/* Account metadata */}
              <div className="profile-account-meta">
                <h4>📊 Informations du compte</h4>
                <div className="profile-meta-grid">
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">🆔</span>
                    <span className="profile-meta-card-label">ID Compte</span>
                    <span className="profile-meta-card-value">#{profile?.id}</span>
                  </div>
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">📅</span>
                    <span className="profile-meta-card-label">Inscription</span>
                    <span className="profile-meta-card-value">{memberSince || '—'}</span>
                  </div>
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">🕐</span>
                    <span className="profile-meta-card-label">Dernière connexion</span>
                    <span className="profile-meta-card-value">{lastLogin || '—'}</span>
                  </div>
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">{activeStatus.icon}</span>
                    <span className="profile-meta-card-label">Statut</span>
                    <span className="profile-meta-card-value">{activeStatus.label}</span>
                  </div>
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">{emailStatus.icon}</span>
                    <span className="profile-meta-card-label">Email vérifié</span>
                    <span className="profile-meta-card-value">{emailStatus.label}</span>
                  </div>
                  <div className="profile-meta-card">
                    <span className="profile-meta-card-icon">🔖</span>
                    <span className="profile-meta-card-label">Rôle</span>
                    <span className="profile-meta-card-value profile-meta-role">
                      {profile?.role || 'client'}
                    </span>
                  </div>
                </div>
              </div>
            </div>
          )}
        </>
      )}

      {/* ══════════════════════════════════════════
          TAB: Adresses
          ══════════════════════════════════════════ */}
      {activeTab === 'addresses' && (
        <div className="profile-addresses-section">
          {addresses.length === 0 ? (
            <div className="client-empty">
              <span className="client-empty-icon">📍</span>
              <h3>Aucune adresse enregistrée</h3>
              <p>Vos adresses seront ajoutées automatiquement lors de vos prochaines commandes.</p>
            </div>
          ) : (
            <div className="profile-addresses-grid">
              {addresses.map((addr) => (
                <div
                  key={addr.id}
                  className={`profile-address-card ${addr.is_default ? 'profile-address-card--default' : ''}`}
                >
                  <div className="profile-address-header">
                    <span className="profile-address-icon">{addr.is_default ? '⭐' : '📍'}</span>
                    <span className="profile-address-label">{addr.label || 'Adresse'}</span>
                    {addr.is_default && <span className="profile-default-badge">Par défaut</span>}
                  </div>
                  <div className="profile-address-body">
                    <p className="profile-address-text">{addr.street_address}</p>
                    <p className="profile-address-text profile-address-city">
                      {addr.postal_code} {addr.city}
                    </p>
                    {addr.country && (
                      <p className="profile-address-text profile-address-country">{addr.country}</p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      )}

      {/* ══════════════════════════════════════════
          TAB: Sécurité & Confidentialité
          ══════════════════════════════════════════ */}
      {activeTab === 'security' && (
        <div className="profile-security-section">
          {/* GDPR & Privacy */}
          <div className="profile-security-card">
            <div className="profile-security-card-header">
              <span className="profile-security-icon">🛡️</span>
              <div>
                <h4>Consentements RGPD</h4>
                <p>Vos choix en matière de protection des données.</p>
              </div>
            </div>
            <div className="profile-consent-list">
              <div className="profile-consent-item">
                <div className="profile-consent-info">
                  <span className="profile-consent-label">Consentement RGPD</span>
                  <span className="profile-consent-desc">
                    Acceptation du traitement des données personnelles
                  </span>
                </div>
                <span
                  className={`profile-consent-badge ${gdprStatus.className}`}
                >
                  {gdprStatus.icon} {gdprStatus.label}
                </span>
              </div>
              <div className="profile-consent-item">
                <div className="profile-consent-info">
                  <span className="profile-consent-label">Communications marketing</span>
                  <span className="profile-consent-desc">
                    Recevoir les offres et promotions par email
                  </span>
                </div>
                <span
                  className={`profile-consent-badge ${marketingStatus.className}`}
                >
                  {marketingStatus.icon} {marketingStatus.label}
                </span>
              </div>
            </div>
          </div>

          {/* Danger Zone */}
          <div className="profile-danger-card">
            <div className="profile-danger-card-header">
              <span className="profile-security-icon">⚠️</span>
              <div>
                <h4>Zone de danger</h4>
                <p>Actions irréversibles sur votre compte.</p>
              </div>
            </div>
            <div className="profile-danger-actions">
              <button
                className="btn btn-danger"
                onClick={() => {
                  if (
                    globalThis.confirm(
                      '⚠️ Êtes-vous sûr de vouloir supprimer votre compte ?\n\nCette action est irréversible. Toutes vos données seront supprimées.',
                    )
                  ) {
                    apiRequest('/api/users/me', { method: 'DELETE' }).then(() => {
                      globalThis.location.href = '/portal';
                    });
                  }
                }}
              >
                🗑️ Supprimer mon compte
              </button>
              <p className="profile-danger-warning">
                La suppression de votre compte entraîne la perte définitive de toutes vos données,
                commandes, points de fidélité et historique.
              </p>
            </div>
          </div>
        </div>
      )}

      {/* Floating AI Assistant for profile page */}
      <AiAssistantWidget pageContext="profile" />
    </div>
  );
}

/* ──────────────────────────────────────────────
   Sub-components
   ────────────────────────────────────────────── */

function ProfileField({
  icon,
  label,
  value,
}: Readonly<{
  icon: string;
  label: string;
  value?: string | null;
}>) {
  return (
    <div className="profile-field-card">
      <span className="profile-field-icon">{icon}</span>
      <div className="profile-field-content">
        <span className="profile-field-label">{label}</span>
        <span className={`profile-field-value ${value ? '' : 'profile-field-empty'}`}>
          {value || 'Non renseigné'}
        </span>
      </div>
    </div>
  );
}

function getInitials(first?: string | null, last?: string | null, name?: string): string {
  if (first && last) return `${first[0]}${last[0]}`.toUpperCase();
  if (first) return first[0].toUpperCase();
  if (name)
    return name
      .split(' ')
      .map((n) => n[0])
      .join('')
      .toUpperCase()
      .slice(0, 2);
  return '👤';
}

function getDisplayName(profile: UserProfile | null, fallbackName?: string): string {
  const profileName = `${profile?.firstName || ''} ${profile?.lastName || ''}`.trim();
  if (profileName) return profileName;
  return fallbackName || 'Client';
}

function formatProfileDate(value: string | null | undefined, format: 'long' | 'datetime'): string | null {
  if (!value) return null;
  const options: Intl.DateTimeFormatOptions = format === 'long'
    ? { day: 'numeric', month: 'long', year: 'numeric' }
    : { day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' };
  return new Date(value).toLocaleDateString('fr-FR', options);
}

function formatProfileRole(role: string): string {
  if (role === 'customer') return '👤 Client';
  return role;
}

function getBooleanDisplay(
  value: boolean | null | undefined,
  yesIcon: string,
  noIcon: string,
  yesLabel: string,
  noLabel: string,
) {
  if (value) {
    return { icon: yesIcon, label: yesLabel, className: 'profile-consent-badge--yes' };
  }
  return { icon: noIcon, label: noLabel, className: 'profile-consent-badge--no' };
}

function formatLanguage(lang?: string | null): string {
  if (lang === 'fr') return '🇫🇷 Français';
  if (lang === 'en') return '🇬🇧 English';
  return lang || 'Non renseigné';
}

function getTierEmoji(tier: string): string {
  switch (tier.toLowerCase()) {
    case 'gold':
      return '🥇';
    case 'silver':
      return '🥈';
    case 'bronze':
      return '🥉';
    case 'platinum':
      return '💎';
    default:
      return '⭐';
  }
}
