/**
 * AdminSettings - Settings panel for admin role
 */

import './AdminWidgets.css';

export function AdminSettings() {
  return (
    <div className="admin-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>⚙️ Paramètres</h2>
          <p className="widget-subtitle">Configuration du restaurant</p>
        </div>
        <button className="btn btn-primary">💾 Sauvegarder</button>
      </header>

      <div className="settings-grid">
        <section className="settings-section">
          <div className="settings-section-header">
            <h3 className="settings-section-title">🏪 Restaurant</h3>
          </div>
          <div className="settings-section-body">
            <SettingInput label="Nom du restaurant" value="Vite Gourmand" type="text" />
            <SettingInput label="Adresse" value="123 Rue de la Cuisine, Paris" type="text" />
            <SettingInput label="Téléphone" value="01 23 45 67 89" type="text" />
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <h3 className="settings-section-title">🕐 Horaires</h3>
          </div>
          <div className="settings-section-body">
            <SettingInput label="Ouverture" value="11:30" type="time" />
            <SettingInput label="Fermeture" value="22:30" type="time" />
            <SettingToggle label="Ouvert le dimanche" checked={false} />
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <h3 className="settings-section-title">📦 Commandes</h3>
          </div>
          <div className="settings-section-body">
            <SettingToggle label="Commandes en ligne" checked={true} />
            <SettingToggle label="Livraison" checked={true} />
            <SettingToggle label="Click & Collect" checked={true} />
            <SettingInput label="Délai minimum (min)" value="30" type="number" />
          </div>
        </section>

        <section className="settings-section">
          <div className="settings-section-header">
            <h3 className="settings-section-title">🔔 Notifications</h3>
          </div>
          <div className="settings-section-body">
            <SettingToggle label="Nouvelles commandes" checked={true} />
            <SettingToggle label="Alertes stock" checked={true} />
            <SettingToggle label="Avis clients" checked={false} />
          </div>
        </section>
      </div>
    </div>
  );
}

function SettingInput({ label, value, type }: Readonly<{ label: string; value: string; type: string }>) {
  const inputId = `setting-${label.toLowerCase().replaceAll(' ', '-')}`;

  return (
    <div className="setting-row">
      <label className="setting-label" htmlFor={inputId}>{label}</label>
      <input id={inputId} className="setting-input" type={type} defaultValue={value} />
    </div>
  );
}

function SettingToggle({ label, checked }: Readonly<{ label: string; checked: boolean }>) {
  return (
    <div className="setting-row">
      <span className="setting-label">{label}</span>
      <label className="toggle">
        <input type="checkbox" defaultChecked={checked} aria-label={label} />
        <span className="toggle-slider"></span>
      </label>
    </div>
  );
}
