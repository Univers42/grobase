/**
 * StaffList - Admin view for all staff members
 * Uses Fly.io-inspired table design from DevBoard
 * Role-based visibility: Admins see admins + employees
 */

import { useState, useEffect } from 'react';
import { UserProfile } from '../ui/UserProfile';
import { searchUsers, canViewUser } from '../ui/Search';
import type { SearchResult } from '../ui/Search';
import { usePortalAuth } from '../../portal_dashboard/PortalAuthContext';
import './AdminWidgets.css';

interface StaffMember extends SearchResult {
  department?: string;
  position?: string;
  status?: 'active' | 'inactive' | 'away';
}

export function StaffList() {
  const { user: currentUser } = usePortalAuth();
  const [staff, setStaff] = useState<StaffMember[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedUserId, setSelectedUserId] = useState<string | null>(null);
  const [filter, setFilter] = useState<'all' | 'admin' | 'employee'>('all');

  useEffect(() => {
    async function loadStaff() {
      setLoading(true);
      try {
        // In real app, this would call a dedicated staff endpoint
        const results = await searchUsers('');

        // Filter based on visibility rules
        const viewerRole = currentUser?.role;
        const visibleStaff = results.filter((user) => canViewUser(viewerRole, user.role));

        setStaff(visibleStaff);
      } catch (error) {
        console.error('Failed to load staff:', error);
      } finally {
        setLoading(false);
      }
    }

    loadStaff();
  }, [currentUser?.role]);

  const filteredStaff = staff.filter((member) => {
    if (filter === 'all') return true;
    return member.role === filter;
  });
  const showEmptyState = loading === false && filteredStaff.length === 0;
  const showStaffTable = loading === false && filteredStaff.length > 0;

  const getInitials = (name: string) => {
    return name
      .split(' ')
      .map((n) => n[0])
      .join('')
      .toUpperCase()
      .slice(0, 2);
  };

  const getRoleLabel = (role: string) => {
    const labels: Record<string, string> = {
      superadmin: 'Super Admin',
      admin: 'Admin',
      employee: 'Employé',
    };
    return labels[role] || role;
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

  const getStatusLabel = (status?: StaffMember['status']) => {
    const labels: Record<NonNullable<StaffMember['status']>, string> = {
      active: 'Actif',
      away: 'Absent',
      inactive: 'Inactif',
    };
    return status ? labels[status] : 'Inactif';
  };

  return (
    <div className="admin-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>👥 Équipe</h2>
          <p className="widget-subtitle">Gestion des membres de l'équipe</p>
        </div>
      </header>

      {/* Filter Tabs */}
      <div className="filter-tabs">
        <button
          className={`filter-tab ${filter === 'all' ? 'active' : ''}`}
          onClick={() => setFilter('all')}
        >
          Tous ({staff.length})
        </button>
        <button
          className={`filter-tab ${filter === 'admin' ? 'active' : ''}`}
          onClick={() => setFilter('admin')}
        >
          Admins ({staff.filter((s) => s.role === 'admin').length})
        </button>
        <button
          className={`filter-tab ${filter === 'employee' ? 'active' : ''}`}
          onClick={() => setFilter('employee')}
        >
          Employés ({staff.filter((s) => s.role === 'employee').length})
        </button>
      </div>

      {/* Staff Table - Fly.io Design */}
      <div className="fly-card">
        <div className="fly-card-header">
          <h3 className="fly-card-title">
            <span>📋</span> Liste du personnel
          </h3>
          <div className="fly-card-actions">
            <button className="btn btn-secondary btn-sm">Exporter</button>
          </div>
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
            <p className="fly-table-empty-text">Aucun membre trouvé</p>
          </div>
        )}
        {showStaffTable && (
          <>
            {/* Table Header */}
            <div
              className="fly-table-header"
              style={{ gridTemplateColumns: '48px minmax(200px, 2fr) repeat(3, 1fr) 80px' }}
            >
              <span></span>
              <span>Nom</span>
              <span>Rôle</span>
              <span>Département</span>
              <span>Statut</span>
              <span></span>
            </div>

            {/* Table Body */}
            <div className="fly-table-body">
              {filteredStaff.map((member) => (
                <div key={member.id} className="user-list-row">
                  <div className="user-list-avatar">
                    {member.avatar ? (
                      <img src={member.avatar} alt={member.name} />
                    ) : (
                      getInitials(member.name)
                    )}
                  </div>

                  <div className="user-list-info">
                    <span className="user-list-name">{member.name}</span>
                    <span className="user-list-email">{member.email}</span>
                  </div>

                  <div>
                    <span className={`user-list-role user-list-role--${member.role}`}>
                      {getRoleLabel(member.role)}
                    </span>
                  </div>

                  <div data-label="Département">
                    <span>{member.department || '—'}</span>
                  </div>

                  <div>
                    <span className={`inline-status ${getStatusColor(member.status)}`}>
                      <span className="inline-status-dot"></span>
                      {getStatusLabel(member.status)}
                    </span>
                  </div>

                  <div className="user-list-actions">
                    <button
                      className="user-list-action-btn"
                      onClick={(e) => {
                        e.stopPropagation();
                        setSelectedUserId(member.id);
                      }}
                      aria-label="Voir le profil"
                    >
                      <ViewIcon />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </>
        )}
      </div>

      {/* Profile Modal */}
      {selectedUserId && (
        <UserProfile userId={selectedUserId} isModal onClose={() => setSelectedUserId(null)} />
      )}
    </div>
  );
}

// Icons
const ViewIcon = () => (
  <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
    <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z" />
    <circle cx="12" cy="12" r="3" />
  </svg>
);
