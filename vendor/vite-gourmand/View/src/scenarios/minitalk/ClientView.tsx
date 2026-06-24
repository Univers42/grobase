/**
 * Client View Component - Shows order list and order details with real-time status updates
 */

import React, { useState } from 'react';
import { OrderTimeline } from './OrderTimeline';
import { ChatPanel } from './ChatPanel';
import { NewOrderModal } from './NewOrderModal';
import { StatusAnimation } from './StatusAnimation';
import type { MinitalkOrder, NewOrderForm } from './types';
import './ClientView.css';

interface Props {
  orders: MinitalkOrder[];
  selectedOrder: MinitalkOrder | null;
  statusChanged: number | null;
  onSelectOrder: (order: MinitalkOrder) => void;
  onCreateOrder: (form: NewOrderForm) => void;
  onSendMessage: (content: string) => void;
}

const typeLabels = {
  dine_in: { label: 'Sur place', icon: '🍽️' },
  takeaway: { label: 'À emporter', icon: '📦' },
  delivery: { label: 'Livraison', icon: '🚗' },
};

export const ClientView: React.FC<Props> = ({
  orders = [],
  selectedOrder,
  statusChanged,
  onSelectOrder,
  onCreateOrder,
  onSendMessage,
}) => {
  const [isModalOpen, setIsModalOpen] = useState(false);
  const safeOrders = orders || [];

  return (
    <div className="client-view-container">
      {/* Orders List Sidebar */}
      <aside className="client-orders-list">
        <div className="client-orders-header">
          <h3>Mes Commandes</h3>
          <button
            onClick={() => setIsModalOpen(true)}
            className="new-order-btn"
            title="Nouvelle commande"
          >
            <svg className="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                strokeWidth={2}
                d="M12 6v6m0 0v6m0-6h6m-6 0H6"
              />
            </svg>
            Nouvelle
          </button>
        </div>

        {safeOrders.length === 0 ? (
          <div className="client-orders-empty">
            <div className="empty-icon">🍽️</div>
            <p>Aucune commande</p>
            <button onClick={() => setIsModalOpen(true)} className="start-order-btn">
              Passer une commande
            </button>
          </div>
        ) : (
          <ul className="orders-list">
            {safeOrders.map((order) => (
              <li
                key={order.id}
                className={`order-item ${selectedOrder?.id === order.id ? 'active' : ''} ${statusChanged === order.id ? 'status-changed' : ''}`}
                onClick={() => onSelectOrder(order)}
              >
                <div className="order-item-header">
                  <span className="order-number">{order.orderNumber}</span>
                  <span className="order-type-badge">
                    {typeLabels[order.type]?.icon} {typeLabels[order.type]?.label}
                  </span>
                </div>
                <div className="order-item-details">
                  <span className="order-items-count">
                    {order.items.reduce((sum, i) => sum + i.quantity, 0)} article(s)
                  </span>
                  <span className="order-total">{order.total.toFixed(2)}€</span>
                </div>
                <div className="order-item-status">
                  <StatusAnimation
                    status={order.status}
                    isAnimating={statusChanged === order.id}
                    size="sm"
                  />
                </div>
              </li>
            ))}
          </ul>
        )}
      </aside>

      {/* Order Details */}
      <main className="client-order-details">
        {!selectedOrder ? (
          <div className="client-view--empty">
            <div className="empty-state">
              <svg className="empty-icon-svg" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  strokeWidth={1.5}
                  d="M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2"
                />
              </svg>
              <h3>Sélectionnez une commande</h3>
              <p>Choisissez une commande dans la liste pour voir son suivi en temps réel</p>
            </div>
          </div>
        ) : (
          <div className="client-view">
            <header className="client-header">
              <div className="client-header-left">
                <h3>Commande {selectedOrder.orderNumber}</h3>
                <span className="order-type">
                  {typeLabels[selectedOrder.type]?.icon} {typeLabels[selectedOrder.type]?.label}
                </span>
              </div>
              <div className="client-header-right">
                <StatusAnimation
                  status={selectedOrder.status}
                  isAnimating={statusChanged === selectedOrder.id}
                  size="lg"
                />
              </div>
            </header>

            {/* Order Items Summary */}
            <section className="client-items">
              <h4>Détails de la commande</h4>
              <ul className="items-list">
                {selectedOrder.items.map((item, index) => (
                  <li key={index} className="item-row">
                    <span className="item-qty">{item.quantity}x</span>
                    <span className="item-name">{item.name}</span>
                    {item.price && (
                      <span className="item-price">{(item.price * item.quantity).toFixed(2)}€</span>
                    )}
                  </li>
                ))}
              </ul>
              <div className="items-total">
                <span>Total</span>
                <span className="total-amount">{selectedOrder.total.toFixed(2)}€</span>
              </div>
              {selectedOrder.notes && (
                <div className="order-notes">
                  <strong>Notes:</strong> {selectedOrder.notes}
                </div>
              )}
            </section>

            <section className="client-timeline">
              <h4>Suivi de commande</h4>
              <OrderTimeline currentStatus={selectedOrder.status} />
            </section>

            <section className="client-chat">
              <h4>Discussion avec le restaurant</h4>
              <ChatPanel messages={selectedOrder.messages} role="client" onSend={onSendMessage} />
            </section>
          </div>
        )}
      </main>

      {/* New Order Modal */}
      <NewOrderModal
        isOpen={isModalOpen}
        onClose={() => setIsModalOpen(false)}
        onSubmit={onCreateOrder}
      />
    </div>
  );
};
