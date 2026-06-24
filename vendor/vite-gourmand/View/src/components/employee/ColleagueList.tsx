/**
 * ColleagueList - Employee view for colleagues
 * Uses Fly.io-inspired table design from DevBoard
 * Role-based visibility: Employees can only see other employees (transparency)
 */

import { useState, useEffect } from 'react';
import { UserProfile } from '../ui/UserProfile';
import { searchUsers, canViewUser } from '../ui/Search';
import type { SearchResult } from '../ui/Search';
import { usePortalAuth } from '../../portal_dashboard/PortalAuthContext';
import '../admin/AdminWidgets.css'; // Reuse admin table styles
import './EmployeeWidgets.css';

interface Colleague extends SearchResult {
  department?: string;
  position?: string;
  status?: 'active' | 'inactive' | 'away';
  shift?: string;
}

export function ColleagueList() {
  const { user: currentUser } = usePortalAuth();
  const [colleagues, setColleagues] = useState<Colleague[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const showEmptyState = loading === false && colleagues.length === 0;
  const showColleagueGrid = loading === false && colleagues.length > 0;

  useEffect(() => {
    async function loadColleagues() {
      setLoading(true);
      try {
        // In real app, this would call a dedicated colleagues endpoint
        const results = await searchUsers('');

        // Filter based on visibility rules (employees can only see employees)
        const viewerRole = currentUser?.role;
        const visibleColleagues = results.filter((user) => canViewUser(viewerRole, user.role));

        setColleagues(visibleColleagues);
      } catch (error) {
        console.error('Failed to load colleagues:', error);
      } finally {
        setLoading(false);
      }
    }

    loadColleagues();
  }, [currentUser?.role]);

  const getInitials = (name: string) => {
    return name
      .split(' ')
      .map((n) => n[0])
      .join('')
      .toUpperCase()
      .slice(0, 2);
  };

  const getStatusColor = (status?: string) => {
    switch (status) {
      case 'active':
        return 'inline-status--success';
      case 'away':
        return 'inline-status--warning';
      case 'inactive':
        return 'inline-status--neutral';
      default:
        return 'inline-status--info';
    }
  };

  const getStatusLabel = (status?: string) => {
    switch (status) {
      case 'active':
        return 'En service';
      case 'away':
        return 'Absent';
      case 'inactive':
        return 'Hors service';
      default:
        return 'Disponible';
    }
  };

  return (
    <div className="employee-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>👥 Mes collègues</h2>
          <p className="widget-subtitle">Équipe du restaurant • {colleagues.length} membres</p>
        </div>
      </header>

      {/* Colleagues Grid */}
      <div className="fly-card">
        <div className="fly-card-header">
          <h3 className="fly-card-title">
            <span>🤝</span> Équipe présente
          </h3>
        </div>

        {loading && (
          <div className="fly-table-empty">
            <div className="fly-table-empty-icon">⏳</div>
            <p className="fly-table-empty-text">Chargement...</p>
          </div>
        )}
        {showEmptyState && (
          <div className="fly-table-empty">
            <div className="fly-table-empty-icon">👥</div>
            <p className="fly-table-empty-text">Aucun collègue trouvé</p>
          </div>
        )}
        {showColleagueGrid && (
          <div className="colleague-grid">
            {colleagues.map((colleague) => (
              <button
                type="button"
                key={colleague.id}
                className="colleague-card"
                onClick={() => setSelectedUserId(colleague.id)}
              >
                <div className="colleague-card-avatar">
                  {colleague.avatar ? (
                    <img src={colleague.avatar} alt={colleague.name} />
                  ) : (
                    getInitials(colleague.name)
                  )}
                  <span
                    className={`colleague-status-indicator ${
                      colleague.status === 'active' ? 'colleague-status-indicator--active' : ''
                    }`}
                  ></span>
                </div>

                <div className="colleague-card-info">
                  <span className="colleague-card-name">{colleague.name}</span>
                  <span className="colleague-card-position">{colleague.position || 'Employé'}</span>
                </div>

                <div className="colleague-card-meta">
                  <span className={`inline-status ${getStatusColor(colleague.status)}`}>
                    <span className="inline-status-dot"></span>
                    {getStatusLabel(colleague.status)}
                  </span>
                  {colleague.shift && (
                    <span className="colleague-card-shift">🕐 {colleague.shift}</span>
                  )}
                </div>
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Note about transparency */}
      <div className="transparency-note">
        <span className="transparency-note-icon">ℹ️</span>
        <p className="transparency-note-text">
          Pour favoriser la transparence au sein de l'équipe, vous pouvez consulter les profils de
          vos collègues. Les informations sensibles restent confidentielles.
        </p>
      </div>

      {/* Profile Modal */}
      {selectedUserId && (
        <UserProfile userId={selectedUserId} isModal onClose={() => setSelectedUserId(null)} />
      )}
    </div>
  );
}
