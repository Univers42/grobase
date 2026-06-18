/**
 * Order Status Timeline - Client View
 */

import React from 'react';
import { getStatusIcon, getStatusInfo } from '../../services/orders';
import type { OrderStatus } from '../../services/orders';
import './OrderTimeline.css';

interface Props {
  currentStatus: OrderStatus;
}

const FLOW: OrderStatus[] = [
  'pending',
  'confirmed',
  'preparing',
  'cooking',
  'assembling',
  'ready',
  'delivery',
  'delivered',
];

export const OrderTimeline: React.FC<Props> = ({ currentStatus }) => {
  const currentIdx = FLOW.indexOf(currentStatus);
  const isCancelled = currentStatus === 'cancelled';

  return (
    <div className="order-timeline">
      {FLOW.map((status, idx) => {
        const info = getStatusInfo(status);
        const Icon = getStatusIcon(status);
        const isActive = idx <= currentIdx && !isCancelled;
        const isCurrent = idx === currentIdx && !isCancelled;

        return (
          <div
            key={status}
            className={`timeline-step ${isActive ? 'active' : ''} ${isCurrent ? 'current' : ''}`}
          >
            <div className="timeline-icon" style={{ color: isActive ? info.color : undefined }}>
              <Icon />
            </div>
            <span className="timeline-label">{info.label}</span>
            {idx < FLOW.length - 1 && <div className="timeline-connector" />}
          </div>
        );
      })}
      {isCancelled && (
        <div className="timeline-cancelled">
          {React.createElement(getStatusIcon('cancelled'))}
          <span>Commande annulée</span>
        </div>
      )}
    </div>
  );
};
