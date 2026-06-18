/**
 * Professional View - Kanban-style order management with drag-and-drop
 */

import React, { useState } from 'react';
import { getStatusInfo, type OrderStatus } from '../../services/orders';
import { StatusAnimation } from './StatusAnimation';
import type { MinitalkOrder } from './types';
import './ProView.css';

interface Props {
  orders: MinitalkOrder[];
  selectedId: number | null;
  onSelect: (order: MinitalkOrder) => void;
  onStatusChange: (orderId: number, status: OrderStatus) => void;
}

const COLUMNS: { status: OrderStatus; label: string; icon: string }[] = [
  { status: 'pending', label: 'En attente', icon: '⏳' },
  { status: 'preparing', label: 'Préparation', icon: '👨‍🍳' },
  { status: 'cooking', label: 'Cuisson', icon: '🔥' },
  { status: 'ready', label: 'Prêt !', icon: '✅' },
];

export const ProView: React.FC<Props> = ({ orders, selectedId, onSelect, onStatusChange }) => {
  const [dragOverColumn, setDragOverColumn] = useState<OrderStatus | null>(null);
  const [recentlyChanged, setRecentlyChanged] = useState<number | null>(null);

  const handleDrop = (e: React.DragEvent, targetStatus: OrderStatus) => {
    e.preventDefault();
    setDragOverColumn(null);
    const orderId = Number.parseInt(e.dataTransfer.getData('orderId'));
    if (!Number.isNaN(orderId)) {
      const order = orders.find((o) => o.id === orderId);
      if (order && order.status !== targetStatus) {
        onStatusChange(orderId, targetStatus);
        setRecentlyChanged(orderId);
        setTimeout(() => setRecentlyChanged(null), 2000);
      }
    }
  };

  return (
    <div className="pro-view">
      <div className="pro-view-header">
        <h2>🍳 Gestion des Commandes</h2>
        <p>Glissez-déposez les tickets pour changer leur statut</p>
      </div>
      <div className="pro-columns">
        {COLUMNS.map(({ status, label, icon }) => {
          const columnOrders = orders.filter((o) => o.status === status);
          const info = getStatusInfo(status);

          return (
            <div
              key={status}
              className={`pro-column ${dragOverColumn === status ? 'drag-over' : ''}`}
              style={{ '--column-color': info.color } as React.CSSProperties}
              onDragOver={(e) => {
                e.preventDefault();
                setDragOverColumn(status);
              }}
              onDragLeave={() => setDragOverColumn(null)}
              onDrop={(e) => handleDrop(e, status)}
            >
              <header className="pro-column-header">
                <div className="column-title">
                  <span className="column-icon">{icon}</span>
                  <h3>{label}</h3>
                </div>
                <span className="count" style={{ background: info.color }}>
                  {columnOrders.length}
                </span>
              </header>
              <div className="pro-column-tasks">
                {columnOrders.length === 0 ? (
                  <div className="empty-column">
                    <span className="empty-icon">{icon}</span>
                    <span>Aucune commande</span>
                  </div>
                ) : (
                  columnOrders.map((order) => (
                    <OrderTicket
                      key={order.id}
                      order={order}
                      isSelected={order.id === selectedId}
                      isAnimating={recentlyChanged === order.id}
                      onSelect={() => onSelect(order)}
                    />
                  ))
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
};

interface OrderTicketProps {
  order: MinitalkOrder;
  isSelected: boolean;
  isAnimating: boolean;
  onSelect: () => void;
}

const OrderTicket: React.FC<OrderTicketProps> = ({ order, isSelected, isAnimating, onSelect }) => {
  const info = getStatusInfo(order.status);
  const typeInfo = {
    dine_in: { label: 'Sur place', icon: '🍽️' },
    takeaway: { label: 'Emporter', icon: '📦' },
    delivery: { label: 'Livraison', icon: '🚗' },
  };

  return (
    <div
      className={`order-ticket ${isSelected ? 'selected' : ''} ${isAnimating ? 'animating' : ''}`}
      draggable
      onDragStart={(e) => e.dataTransfer.setData('orderId', order.id.toString())}
      onClick={onSelect}
    >
      {order.unreadCount > 0 && <span className="unread-badge">{order.unreadCount}</span>}

      <div className="ticket-header">
        <span className="ticket-number">{order.orderNumber}</span>
        <span className="ticket-time">
          {new Date(order.createdAt).toLocaleTimeString('fr-FR', {
            hour: '2-digit',
            minute: '2-digit',
          })}
        </span>
      </div>

      <div className="ticket-customer">
        <span className="customer-name">{order.customerName}</span>
        <span
          className="customer-type"
          style={{ background: `${info.color}15`, color: info.color }}
        >
          {typeInfo[order.type]?.icon} {typeInfo[order.type]?.label}
        </span>
      </div>

      <div className="ticket-items">
        {order.items.map((item, i) => (
          <div key={i} className="ticket-item">
            <span className="item-qty">{item.quantity}x</span>
            <span className="item-name">{item.name}</span>
          </div>
        ))}
      </div>

      {order.notes && <div className="ticket-notes">📝 {order.notes}</div>}

      <div className="ticket-footer">
        <span className="ticket-total">{order.total.toFixed(2)}€</span>
        <StatusAnimation status={order.status} isAnimating={isAnimating} size="sm" />
      </div>
    </div>
  );
};
