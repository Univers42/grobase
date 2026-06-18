/**
 * SettingsModal - Dashboard settings modal
 * Theme, display preferences, and options
 */

import { useState } from 'react';
import './SettingsModal.css';

interface SettingsModalProps {
  isOpen: boolean;
  onClose: () => void;
}

interface Settings {
  autoRefresh: boolean;
  refreshInterval: number;
  showMetrics: boolean;
  compactMode: boolean;
  notifications: boolean;
}

export function SettingsModal({ isOpen, onClose }: Readonly<SettingsModalProps>) {
  const [settings, setSettings] = useState<Settings>({
    autoRefresh: false,
    refreshInterval: 30,
    showMetrics: true,
    compactMode: false,
    notifications: true,
  });

  if (!isOpen) return null;

  const handleChange = (key: keyof Settings, value: boolean | number) => {
    setSettings((prev) => ({ ...prev, [key]: value }));
  };

  const handleSave = () => {
    // Save to localStorage
    localStorage.setItem('devboard-settings', JSON.stringify(settings));
    onClose();
  };

  return (
    <dialog className="settings-overlay" onCancel={onClose} aria-labelledby="settings-modal-title" open>
      <div className="settings-modal">
        <header className="settings-header">
          <h2 id="settings-modal-title">⚙️ Paramètres</h2>
          <button className="settings-close" onClick={onClose}>
            ×
          </button>
        </header>

        <div className="settings-content">
          <section className="settings-section">
            <h3>Actualisation</h3>
            <div className="setting-item">
              <label>
                <input
                  type="checkbox"
                  checked={settings.autoRefresh}
                  onChange={(e) => handleChange('autoRefresh', e.target.checked)}
                />
                <span>Actualisation automatique</span>
              </label>
            </div>
            <div className="setting-item">
              <label>
                <span>Intervalle (secondes)</span>
                <select
                  value={settings.refreshInterval}
                  onChange={(e) => handleChange('refreshInterval', Number(e.target.value))}
                  disabled={!settings.autoRefresh}
                >
                  <option value={10}>10s</option>
                  <option value={30}>30s</option>
                  <option value={60}>1min</option>
                  <option value={300}>5min</option>
                </select>
              </label>
            </div>
          </section>

          <section className="settings-section">
            <h3>Affichage</h3>
            <div className="setting-item">
              <label>
                <input
                  type="checkbox"
                  checked={settings.showMetrics}
                  onChange={(e) => handleChange('showMetrics', e.target.checked)}
                />
                <span>Afficher les métriques</span>
              </label>
            </div>
            <div className="setting-item">
              <label>
                <input
                  type="checkbox"
                  checked={settings.compactMode}
                  onChange={(e) => handleChange('compactMode', e.target.checked)}
                />
                <span>Mode compact</span>
              </label>
            </div>
          </section>

          <section className="settings-section">
            <h3>Notifications</h3>
            <div className="setting-item">
              <label>
                <input
                  type="checkbox"
                  checked={settings.notifications}
                  onChange={(e) => handleChange('notifications', e.target.checked)}
                />
                <span>Activer les notifications</span>
              </label>
            </div>
          </section>
        </div>

        <footer className="settings-footer">
          <button className="btn-cancel" onClick={onClose}>
            Annuler
          </button>
          <button className="btn-save" onClick={handleSave}>
            Enregistrer
          </button>
        </footer>
      </div>
    </dialog>
  );
}
