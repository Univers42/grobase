/**
 * ProfileHeader — 42-style profile banner
 * Big gradient header with avatar, name, level bar, quick stats
 */

import type { FullUserProfile } from './types';

interface ProfileHeaderProps {
  profile: FullUserProfile;
  isSelf: boolean;
  onClose?: () => void;
}

const ROLE_CONFIG: Record<string, { label: string; emoji: string; color: string }> = {
  superadmin: { label: 'Super Admin', emoji: '👑', color: 'var(--up-role-superadmin)' },
  admin: { label: 'Administrateur', emoji: '🛡️', color: 'var(--up-role-admin)' },
  employee: { label: 'Employé', emoji: '👷', color: 'var(--up-role-employee)' },
  customer: { label: 'Client', emoji: '👤', color: 'var(--up-role-customer)' },
};

export function ProfileHeader({ profile, isSelf, onClose }: Readonly<ProfileHeaderProps>) {
  const roleConf = ROLE_CONFIG[profile.role] ?? ROLE_CONFIG.customer;
  const initials = profile.name
    .split(' ')
    .map((w) => w[0])
    .join('')
    .toUpperCase()
    .slice(0, 2);

  return (
    <div className="up-header">
      {/* Gradient Banner */}
      <div className="up-banner">
        <div className="up-banner-pattern" />
        {onClose && (
          <button className="up-close" onClick={onClose} aria-label="Fermer le profil">
            <svg
              width="20"
              height="20"
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
            >
              <path d="M18 6L6 18M6 6l12 12" />
            </svg>
          </button>
        )}
      </div>

      {/* Avatar — overlapping banner */}
      <div className="up-avatar-ring">
        <div className="up-avatar">
          {profile.avatar ? (
            <img src={profile.avatar} alt={profile.name} />
          ) : (
            <span className="up-avatar-initials">{initials}</span>
          )}
        </div>
        {isSelf && (
          <span className="up-avatar-badge" title="C'est vous !">
            ✦
          </span>
        )}
      </div>

      {/* Identity */}
      <div className="up-identity">
        <h2 className="up-name">{profile.name}</h2>
        <p className="up-username">@{profile.username}</p>
        <span
          className="up-role-badge"
          style={{ '--role-color': roleConf.color } as React.CSSProperties}
        >
          {roleConf.emoji} {roleConf.label}
        </span>
      </div>

      {/* Level Bar */}
      <div className="up-level">
        <div className="up-level-info">
          <span className="up-level-label">
            Niveau {profile.level} — <em>{profile.levelTitle}</em>
          </span>
          <span className="up-level-pct">{profile.levelProgress}%</span>
        </div>
        <div className="up-level-track">
          <div className="up-level-fill" style={{ width: `${profile.levelProgress}%` }} />
        </div>
      </div>

      {/* Quick Stats */}
      <div className="up-quick-stats">
        <QuickStat value={profile.stats.ordersHandled} label="Commandes" icon="🍽️" />
        <QuickStat value={`${profile.stats.hoursWorked}h`} label="Heures" icon="⏱️" />
        <QuickStat value={profile.stats.averageRating.toFixed(1)} label="Note" icon="⭐" />
        <QuickStat value={`${profile.stats.completionRate}%`} label="Complétion" icon="✅" />
      </div>
    </div>
  );
}

function QuickStat({
  value,
  label,
  icon,
}: Readonly<{
  value: string | number;
  label: string;
  icon: string;
}>) {
  return (
    <div className="up-qstat">
      <span className="up-qstat-icon">{icon}</span>
      <span className="up-qstat-value">{value}</span>
      <span className="up-qstat-label">{label}</span>
    </div>
  );
}
