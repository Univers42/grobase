/**
 * Minitalk State Management Hook
 */

import { useState, useCallback, useEffect } from 'react';
import type { MinitalkOrder, MinitalkMessage, ViewMode, NewOrderForm } from './types';
import type { OrderStatus } from '../../services/orders';

const INITIAL_ORDERS: MinitalkOrder[] = [];

export function useMinitalk() {
  const [orders, setOrders] = useState<MinitalkOrder[]>(INITIAL_ORDERS);
  const [selectedOrder, setSelectedOrder] = useState<MinitalkOrder | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>('split');
  const [statusChanged, setStatusChanged] = useState<number | null>(null);

  // Sync selected order with orders list
  useEffect(() => {
    if (selectedOrder) {
      const updated = orders.find((o) => o.id === selectedOrder.id);
      if (updated && updated.status !== selectedOrder.status) {
        setSelectedOrder(updated);

        setStatusChanged(updated.id);
        setTimeout(() => setStatusChanged(null), 3000);
      }
    }
  }, [orders, selectedOrder]);

  const createOrder = useCallback(
    (form: NewOrderForm) => {
      const total = form.items.reduce((sum, item) => sum + item.price * item.quantity, 0);
      const newOrder: MinitalkOrder = {
        id: Date.now(),
        orderNumber: `#${String(orders.length + 1).padStart(3, '0')}`,
        customerName: form.customerName,
        status: 'pending',
        items: form.items,
        total,
        type: form.type,
        notes: form.notes,
        createdAt: new Date().toISOString(),
        messages: [],
        unreadCount: 0,
      };
      setOrders((prev) => [...prev, newOrder]);
      setSelectedOrder(newOrder);
      return newOrder;
    },
    [orders.length],
  );

  const updateStatus = useCallback((orderId: number, status: OrderStatus) => {
    setOrders((prev) => prev.map((o) => (o.id === orderId ? { ...o, status } : o)));
  }, []);

  const sendMessage = useCallback(
    (orderId: number, content: string, role: 'client' | 'professional') => {
      const message: MinitalkMessage = {
        id: Date.now().toString(),
        senderId: role,
        senderName: role === 'client' ? 'Vous' : 'Restaurant',
        senderRole: role,
        content,
        timestamp: new Date().toISOString(),
        read: false,
      };
      setOrders((prev) =>
        prev.map((o) => (o.id === orderId ? { ...o, messages: [...o.messages, message] } : o)),
      );
    },
    [],
  );

  return {
    orders,
    selectedOrder,
    viewMode,
    statusChanged,
    setSelectedOrder,
    setViewMode,
    createOrder,
    updateStatus,
    sendMessage,
  };
}
