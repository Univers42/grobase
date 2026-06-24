/**
 * ClientOverview - Customer dashboard home
 * Shows welcome, recent orders, loyalty points, pending reviews prompt
 */

import { useState, useEffect } from 'react';
import { usePortalAuth } from '../../portal_dashboard';
import { apiRequest } from '../../services/api';
import './ClientWidgets.css';

interface LoyaltyData {
  points: number;
  tier: string;
  nextTier: string | null;
  pointsToNextTier: number | null;
}

interface OrderSummary {
  id: number;
  order_number: string;
  status: string | null;
  total_price: number;
  created_at: string;
  delivery_date: string;
}

export function ClientOverview() {
  const { user } = usePortalAuth();
  const [loyalty, setLoyalty] = useState<LoyaltyData | null>(null);
  const [recentOrders, setRecentOrders] = useState<OrderSummary[]>([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function fetchDashboard() {
      try {
        const [loyaltyRes, ordersRes] = await Promise.all([
          apiRequest<{ data: LoyaltyData }>('/api/loyalty/me').catch(() => null),
          apiRequest<{ data: { items: OrderSummary[] } }>(
            '/api/orders/my?limit=5&sortBy=created_at&sortOrder=desc',
          ).catch(() => null),
        ]);
        if (loyaltyRes?.data) setLoyalty(loyaltyRes.data);
        if (ordersRes?.data?.items) setRecentOrders(ordersRes.data.items);
      } catch {
        /* silent */
      } finally {
        setLoading(false);
      }
    }
    fetchDashboard();
  }, []);

  const greeting = getGreeting();
  const firstName = user?.name?.split(' ')[0] || 'Client';

  return (
    <div className="client-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>
            {greeting} {firstName} 👋
          </h2>
          <p className="widget-subtitle">Bienvenue dans votre espace personnel</p>
        </div>
      </header>

      {loading ? (
        <div className="client-loading">
          <div className="client-loading-spinner" />
          <p>Chargement de vos données…</p>
        </div>
      ) : (
        <>
          {/* Quick Stats */}
          <div className="client-stats-grid">
            <div className="client-stat client-stat--loyalty">
              <div className="client-stat-icon">🏆</div>
              <div className="client-stat-content">
                <span className="client-stat-value">{loyalty?.points ?? 0}</span>
                <span className="client-stat-label">Points fidélité</span>
              </div>
              {loyalty?.tier && (
                <span className="client-stat-badge">{getTierLabel(loyalty.tier)}</span>
              )}
            </div>

            <div className="client-stat client-stat--orders">
              <div className="client-stat-icon">📦</div>
              <div className="client-stat-content">
                <span className="client-stat-value">{recentOrders.length}</span>
                <span className="client-stat-label">Commandes récentes</span>
              </div>
            </div>

            <div className="client-stat client-stat--active">
              <div className="client-stat-icon">🚀</div>
              <div className="client-stat-content">
                <span className="client-stat-value">
                  {
                    recentOrders.filter(
                      (o) => o.status && !['delivered', 'cancelled'].includes(o.status),
                    ).length
                  }
                </span>
                <span className="client-stat-label">En cours</span>
              </div>
            </div>

            {loyalty?.nextTier && (
              <div className="client-stat client-stat--next-tier">
                <div className="client-stat-icon">⭐</div>
                <div className="client-stat-content">
                  <span className="client-stat-value">{loyalty.pointsToNextTier}</span>
                  <span className="client-stat-label">
                    Points avant {getTierLabel(loyalty.nextTier)}
                  </span>
                </div>
                <div className="client-progress-bar">
                  <div
                    className="client-progress-fill"
                    style={{
                      width: `${Math.min(100, (loyalty.points / (loyalty.points + (loyalty.pointsToNextTier ?? 0))) * 100)}%`,
                    }}
                  />
                </div>
              </div>
            )}
          </div>

          {/* Recent Orders */}
          {recentOrders.length > 0 && (
            <section className="widget-section">
              <div className="widget-section-header">
                <h3>📋 Dernières commandes</h3>
              </div>
              <div className="client-orders-list">
                {recentOrders.slice(0, 3).map((order) => (
                  <div key={order.id} className="client-order-card">
                    <div className="client-order-info">
                      <span className="client-order-number">#{order.order_number}</span>
                      <span className="client-order-date">
                        {new Date(order.created_at).toLocaleDateString('fr-FR', {
                          day: 'numeric',
                          month: 'short',
                          year: 'numeric',
                        })}
                      </span>
                    </div>
                    <div className="client-order-details">
                      <span
                        className={`client-order-status client-order-status--${order.status || 'pending'}`}
                      >
                        {getStatusLabel(order.status)}
                      </span>
                      <span className="client-order-price">{order.total_price.toFixed(2)} €</span>
                    </div>
                  </div>
                ))}
              </div>
            </section>
          )}

          {/* Quick Actions */}
          <section className="widget-section">
            <div className="widget-section-header">
              <h3>⚡ Actions rapides</h3>
            </div>
            <div className="client-actions-grid">
              <QuickAction icon="📦" label="Mes commandes" description="Historique & suivi" />
              <QuickAction icon="🏆" label="Fidélité" description="Points & récompenses" />
              <QuickAction icon="💬" label="Support" description="Aide & réclamations" />
              <QuickAction icon="⭐" label="Donner un avis" description="Évaluez vos commandes" />
            </div>
          </section>
        </>
      )}
    </div>
  );
}

function QuickAction({
  icon,
  label,
  description,
}: Readonly<{
  icon: string;
  label: string;
  description: string;
}>) {
  return (
    <div className="client-action-card">
      <span className="client-action-icon">{icon}</span>
      <span className="client-action-label">{label}</span>
      <span className="client-action-desc">{description}</span>
    </div>
  );
}

function getGreeting(): string {
  const hour = new Date().getHours();
  if (hour < 12) return 'Bonjour';
  if (hour < 18) return 'Bon après-midi';
  return 'Bonsoir';
}

function getTierLabel(tier: string): string {
  const labels: Record<string, string> = {
    bronze: '🥉 Bronze',
    silver: '🥈 Argent',
    gold: '🥇 Or',
    platinum: '💎 Platine',
    diamond: '💠 Diamant',
  };
  return labels[tier.toLowerCase()] || tier;
}

function getStatusLabel(status: string | null): string {
  const labels: Record<string, string> = {
    pending: 'En attente',
    confirmed: 'Confirmée',
    preparing: 'En préparation',
    cooking: 'En cuisine',
    assembling: 'Assemblage',
    ready: 'Prête',
    delivery: 'En livraison',
    delivered: 'Livrée',
    cancelled: 'Annulée',
  };
  return labels[status ?? 'pending'] || status || 'En attente';
}
