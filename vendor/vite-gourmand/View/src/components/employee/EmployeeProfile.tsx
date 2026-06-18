/**
 * EmployeeProfile - Profile settings for employee role
 */

import './EmployeeWidgets.css';

export function EmployeeProfile() {
  return (
    <div className="employee-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>👤 Mon Profil</h2>
          <p className="widget-subtitle">Informations personnelles et préférences</p>
        </div>
        <button className="btn btn-primary">✏️ Modifier</button>
      </header>

      <div className="profile-card">
        <div className="profile-avatar">👷</div>
        <div className="profile-info">
          <h3 className="profile-name">Jean Dupont</h3>
          <span className="profile-role">Serveur • Équipe A</span>
          <div className="profile-meta">
            <span>📧 jean.dupont@vitegourmand.fr</span>
            <span>📅 Depuis mars 2024</span>
          </div>
        </div>
      </div>

      <div className="profile-stats">
        <div className="profile-stat">
          <span className="profile-stat-value">245</span>
          <span className="profile-stat-label">Commandes servies</span>
        </div>
        <div className="profile-stat">
          <span className="profile-stat-value">142h</span>
          <span className="profile-stat-label">Heures ce mois</span>
        </div>
        <div className="profile-stat">
          <span className="profile-stat-value">4.8</span>
          <span className="profile-stat-label">Note moyenne</span>
        </div>
      </div>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>📞 Contact</h3>
        </div>
        <div className="task-list">
          <ProfileField label="Email" value="jean.dupont@vitegourmand.fr" />
          <ProfileField label="Téléphone" value="06 12 34 56 78" />
          <ProfileField label="Adresse" value="123 Rue des Lilas, Paris" />
        </div>
      </section>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>🕐 Horaires habituels</h3>
        </div>
        <div className="task-list">
          <ProfileField label="Lundi" value="11h - 15h / 18h - 22h" />
          <ProfileField label="Mardi" value="11h - 15h / 18h - 22h" />
          <ProfileField label="Mercredi" value="Repos" />
          <ProfileField label="Jeudi" value="11h - 15h / 18h - 22h" />
          <ProfileField label="Vendredi" value="11h - 15h / 18h - 23h" />
          <ProfileField label="Samedi" value="11h - 15h / 18h - 23h" />
          <ProfileField label="Dimanche" value="Repos" />
        </div>
      </section>

      <section className="widget-section">
        <div className="widget-section-header">
          <h3>🔔 Préférences</h3>
        </div>
        <div className="task-list">
          <SettingToggle label="Notifications push" checked />
          <SettingToggle label="Rappels de tâches" checked />
          <SettingToggle label="Mode sombre" checked={false} />
        </div>
      </section>
    </div>
  );
}

function ProfileField({ label, value }: Readonly<{ label: string; value: string }>) {
  return (
    <div className="task-item">
      <span className="task-label" style={{ minWidth: '120px', color: 'var(--color-text-muted)' }}>
        {label}
      </span>
      <span style={{ flex: 1, textAlign: 'right' }}>{value}</span>
    </div>
  );
}

function SettingToggle({ label, checked }: Readonly<{ label: string; checked: boolean }>) {
  return (
    <div className="task-item">
      <span className="task-label">{label}</span>
      <label className="toggle" style={{ marginLeft: 'auto' }}>
        <input type="checkbox" defaultChecked={checked} aria-label={label} />
        <span className="toggle-slider"></span>
      </label>
    </div>
  );
}
