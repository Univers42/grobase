/**
 * Minitalk Scenario - Real-time Client/Pro Communication
 */

import React from 'react';
import { GradientBackground } from '../../components/DevBoard';
import { useMinitalk } from './useMinitalk';
import { ProView } from './ProView';
import { ClientView } from './ClientView';
import './MinitalkScenario.css';

export const MinitalkScenario: React.FC = () => {
  const {
    orders,
    selectedOrder,
    viewMode,
    statusChanged,
    setSelectedOrder,
    setViewMode,
    createOrder,
    updateStatus,
    sendMessage,
  } = useMinitalk();

  const handleSendMessage = (content: string) => {
    if (selectedOrder) {
      sendMessage(selectedOrder.id, content, viewMode === 'client' ? 'client' : 'professional');
    }
  };

  return (
    <>
      <GradientBackground />
      <div className="minitalk-scenario">
        <header className="minitalk-header">
          <h1>🍽️ Minitalk</h1>
          <p>Suivi de commande en temps réel</p>
          <div className="view-toggle">
            <button
              className={viewMode === 'split' ? 'active' : ''}
              onClick={() => setViewMode('split')}
            >
              <span>⚡</span> Vue partagée
            </button>
            <button
              className={viewMode === 'pro' ? 'active' : ''}
              onClick={() => setViewMode('pro')}
            >
              <span>👨‍🍳</span> Professionnel
            </button>
            <button
              className={viewMode === 'client' ? 'active' : ''}
              onClick={() => setViewMode('client')}
            >
              <span>👤</span> Client
            </button>
          </div>
        </header>

        <main className={`minitalk-content view-${viewMode}`}>
          {(viewMode === 'split' || viewMode === 'pro') && (
            <section className="minitalk-pro">
              <ProView
                orders={orders}
                selectedId={selectedOrder?.id ?? null}
                onSelect={setSelectedOrder}
                onStatusChange={updateStatus}
              />
            </section>
          )}
          {(viewMode === 'split' || viewMode === 'client') && (
            <section className="minitalk-client">
              <ClientView
                orders={orders}
                selectedOrder={selectedOrder}
                statusChanged={statusChanged}
                onSelectOrder={setSelectedOrder}
                onCreateOrder={createOrder}
                onSendMessage={handleSendMessage}
              />
            </section>
          )}
        </main>
      </div>
    </>
  );
};
