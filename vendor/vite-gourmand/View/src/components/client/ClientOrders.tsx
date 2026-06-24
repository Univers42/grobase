/**
 * ClientOrders - Customer order history & tracking
 * Fetches from GET /api/orders/my (existing backend)
 */

import { useState, useEffect } from 'react';
import { apiRequest } from '../../services/api';
import './ClientWidgets.css';

interface Order {
  id: number;
  order_number: string;
  status: string | null;
  total_price: number;
  menu_price: number;
  delivery_price: number | null;
  discount_amount: number | null;
  delivery_date: string;
  delivery_hour: string | null;
  delivery_address: string | null;
  delivery_city: string | null;
  special_instructions: string | null;
  person_number: number;
  created_at: string;
  updated_at: string;
  OrderMenu?: { menu_id: number; quantity: number | null }[];
}

interface PaginatedResponse {
  items: Order[];
  meta: { page: number; limit: number; total: number; totalPages: number };
}

type FilterTab = 'all' | 'active' | 'delivered' | 'cancelled';

export function ClientOrders() {
  const [orders, setOrders] = useState<Order[]>([]);
  const [loading, setLoading] = useState(true);
  const [filter, setFilter] = useState<FilterTab>('all');
  const [page, setPage] = useState(1);
  const [totalPages, setTotalPages] = useState(1);
  const [expandedId, setExpandedId] = useState<number | null>(null);

  useEffect(() => {
    fetchOrders();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [page, filter]);

  async function fetchOrders() {
    setLoading(true);
    try {
      const params = new URLSearchParams({ page: String(page), limit: '10' });
      if (filter === 'active')
        params.set('status', 'pending,confirmed,preparing,cooking,assembling,ready,delivery');
      if (filter === 'delivered') params.set('status', 'delivered');
      if (filter === 'cancelled') params.set('status', 'cancelled');

      const res = await apiRequest<{ data: PaginatedResponse }>(`/api/orders/my?${params}`);
      setOrders(res.data.items);
      setTotalPages(res.data.meta.totalPages);
    } catch {
      setOrders([]);
    } finally {
      setLoading(false);
    }
  }

  const activeOrders = orders.filter(
    (o) => o.status && !['delivered', 'cancelled'].includes(o.status),
  );
  const tabs: { key: FilterTab; label: string; count?: number }[] = [
    { key: 'all', label: 'Toutes' },
    { key: 'active', label: 'En cours', count: activeOrders.length },
    { key: 'delivered', label: 'Livrées' },
    { key: 'cancelled', label: 'Annulées' },
  ];

  return (
    <div className="client-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>📦 Mes Commandes</h2>
          <p className="widget-subtitle">Historique et suivi de vos commandes</p>
        </div>
      </header>

      {/* Filter Tabs */}
      <div className="client-tabs">
        {tabs.map((tab) => (
          <button
            key={tab.key}
            className={`client-tab ${filter === tab.key ? 'active' : ''}`}
            onClick={() => {
              setFilter(tab.key);
              setPage(1);
            }}
          >
            {tab.label}
            {tab.count !== undefined && tab.count > 0 && (
              <span className="client-tab-badge">{tab.count}</span>
            )}
          </button>
        ))}
      </div>

      {loading && (
        <div className="client-loading">
          <div className="client-loading-spinner" />
          <p>Chargement des commandes…</p>
        </div>
      )}
      {!loading && orders.length === 0 && (
        <div className="client-empty">
          <span className="client-empty-icon">📭</span>
          <h3>Aucune commande</h3>
          <p>Vous n'avez pas encore de commande dans cette catégorie.</p>
        </div>
      )}
      {!loading && orders.length > 0 && (
        <>
          <div className="client-orders-list client-orders-list--full">
            {orders.map((order) => (
              <div key={order.id} className="client-order-card client-order-card--detailed">
                <button
                  type="button"
                  className="client-order-main"
                  onClick={() => setExpandedId(expandedId === order.id ? null : order.id)}
                >
                  <div className="client-order-left">
                    <span className="client-order-number">#{order.order_number}</span>
                    <span className="client-order-date">
                      {new Date(order.created_at).toLocaleDateString('fr-FR', {
                        day: 'numeric',
                        month: 'long',
                        year: 'numeric',
                      })}
                    </span>
                  </div>
                  <div className="client-order-right">
                    <span
                      className={`client-order-status client-order-status--${order.status || 'pending'}`}
                    >
                      {getStatusIcon(order.status)} {getStatusLabel(order.status)}
                    </span>
                    <span className="client-order-price">{order.total_price.toFixed(2)} €</span>
                    <span
                      className={`client-expand-arrow ${expandedId === order.id ? 'open' : ''}`}
                    >
                      ▼
                    </span>
                  </div>
                </button>

                {expandedId === order.id && (
                  <div className="client-order-details-panel">
                    {/* Progress tracker for active orders */}
                    {order.status && !['delivered', 'cancelled'].includes(order.status) && (
                      <div className="client-order-progress">
                        <OrderProgress status={order.status} />
                      </div>
                    )}

                    <div className="client-order-meta-grid">
                      <div className="client-meta-item">
                        <span className="client-meta-label">📅 Livraison</span>
                        <span className="client-meta-value">
                          {new Date(order.delivery_date).toLocaleDateString('fr-FR')}
                          {order.delivery_hour && ` à ${order.delivery_hour}`}
                        </span>
                      </div>
                      <div className="client-meta-item">
                        <span className="client-meta-label">👥 Personnes</span>
                        <span className="client-meta-value">{order.person_number}</span>
                      </div>
                      {order.delivery_address && (
                        <div className="client-meta-item">
                          <span className="client-meta-label">📍 Adresse</span>
                          <span className="client-meta-value">
                            {order.delivery_address}
                            {order.delivery_city && `, ${order.delivery_city}`}
                          </span>
                        </div>
                      )}
                      <div className="client-meta-item">
                        <span className="client-meta-label">💰 Détail prix</span>
                        <span className="client-meta-value">
                          Menu: {order.menu_price.toFixed(2)}€
                          {order.delivery_price
                            ? ` + Livraison: ${order.delivery_price.toFixed(2)}€`
                            : ''}
                          {order.discount_amount
                            ? ` − Remise: ${order.discount_amount.toFixed(2)}€`
                            : ''}
                        </span>
                      </div>
                    </div>

                    {order.special_instructions && (
                      <div className="client-order-instructions">
                        <span className="client-meta-label">📝 Instructions</span>
                        <p>{order.special_instructions}</p>
                      </div>
                    )}
                  </div>
                )}
              </div>
            ))}
          </div>

          {/* Pagination */}
          {totalPages > 1 && (
            <div className="client-pagination">
              <button
                className="client-pagination-btn"
                disabled={page <= 1}
                onClick={() => setPage((p) => p - 1)}
              >
                ← Précédent
              </button>
              <span className="client-pagination-info">
                Page {page} / {totalPages}
              </span>
              <button
                className="client-pagination-btn"
                disabled={page >= totalPages}
                onClick={() => setPage((p) => p + 1)}
              >
                Suivant →
              </button>
            </div>
          )}
        </>
      )}
    </div>
  );
}

const ORDER_STEPS = [
  'pending',
  'confirmed',
  'preparing',
  'cooking',
  'ready',
  'delivery',
  'delivered',
];

function OrderProgress({ status }: Readonly<{ status: string }>) {
  const currentIdx = ORDER_STEPS.indexOf(status);
  return (
    <div className="client-progress-tracker">
      {ORDER_STEPS.map((step, i) => (
        <div
          key={step}
          className={`client-progress-step ${i <= currentIdx ? 'active' : ''} ${i === currentIdx ? 'current' : ''}`}
        >
          <div className="client-progress-dot">{getProgressDotContent(i, currentIdx, step)}</div>
          <span className="client-progress-label">{getStepShortLabel(step)}</span>
        </div>
      ))}
    </div>
  );
}

function getProgressDotContent(i: number, currentIdx: number, step: string): string {
  if (i < currentIdx) return '✓';
  if (i === currentIdx) return getStatusIcon(step);
  return '';
}

function getStepShortLabel(status: string): string {
  const labels: Record<string, string> = {
    pending: 'Envoyée',
    confirmed: 'Confirmée',
    preparing: 'Préparation',
    cooking: 'Cuisine',
    ready: 'Prête',
    delivery: 'Livraison',
    delivered: 'Livrée',
  };
  return labels[status] || status;
}

function getStatusIcon(status: string | null): string {
  const icons: Record<string, string> = {
    pending: '⏳',
    confirmed: '✅',
    preparing: '👨‍🍳',
    cooking: '🔥',
    assembling: '📦',
    ready: '✨',
    delivery: '🚗',
    delivered: '🎉',
    cancelled: '❌',
  };
  return icons[status ?? 'pending'] || '📋';
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
