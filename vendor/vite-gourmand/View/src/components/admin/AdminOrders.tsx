/**
 * AdminOrders - Order management for admin role
 */

import './AdminWidgets.css';

export function AdminOrders() {
  return (
    <div className="admin-widget">
      <header className="widget-header">
        <div className="widget-header-content">
          <h2>📋 Gestion des Commandes</h2>
          <p className="widget-subtitle">Suivi et gestion des commandes en temps réel</p>
        </div>
        <button className="btn btn-primary">🔄 Actualiser</button>
      </header>

      <div className="filter-tabs">
        <button className="filter-tab active">Toutes</button>
        <button className="filter-tab">En attente</button>
        <button className="filter-tab">En cours</button>
        <button className="filter-tab">Prêtes</button>
        <button className="filter-tab">Livrées</button>
      </div>

      <div className="orders-grid">
        <OrderCard
          id="#1234"
          table="Table 5"
          status="en-cours"
          items={['Pizza Margherita', 'Salade César', 'Tiramisu']}
          total="45.50€"
          time="12:34"
        />
        <OrderCard
          id="#1233"
          table="Table 2"
          status="prêt"
          items={['Burger Classic', 'Frites']}
          total="22.00€"
          time="12:28"
        />
        <OrderCard
          id="#1232"
          table="Livraison"
          status="en-attente"
          items={['Pâtes Carbonara x2', 'Bruschetta']}
          total="38.00€"
          time="12:25"
        />
      </div>
    </div>
  );
}

interface OrderCardProps {
  id: string;
  table: string;
  status: string;
  items: string[];
  total: string;
  time: string;
}

function OrderCard({ id, table, status, items, total, time }: Readonly<OrderCardProps>) {
  const statusConfig: Record<string, { label: string; className: string }> = {
    'en-attente': { label: 'En attente', className: 'order-card-badge--pending' },
    'en-cours': { label: 'En préparation', className: 'order-card-badge--progress' },
    prêt: { label: 'Prêt', className: 'order-card-badge--ready' },
  };

  const config = statusConfig[status] || statusConfig['en-attente'];

  return (
    <div className="order-card">
      <div className="order-card-header">
        <span className="order-card-id">{id}</span>
        <span className={`order-card-badge ${config.className}`}>{config.label}</span>
      </div>
      <div className="order-card-body">
        <div className="order-card-meta">
          <span>📍 {table}</span>
          <span>🕐 {time}</span>
        </div>
        <ul className="order-card-items">
          {items.map((item) => (
            <li key={item}>
              <span className="order-card-item-name">{item}</span>
              <span className="order-card-item-qty">x1</span>
            </li>
          ))}
        </ul>
      </div>
      <div className="order-card-footer">
        <span className="order-card-total">{total}</span>
        <div className="order-card-actions">
          <button className="btn btn-success btn-sm">✓ Valider</button>
          <button className="btn btn-secondary btn-sm">Détails</button>
        </div>
      </div>
    </div>
  );
}
