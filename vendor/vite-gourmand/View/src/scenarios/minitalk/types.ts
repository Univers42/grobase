/**
 * Minitalk Types
 */

import type { OrderStatus } from '../../services/orders';

export interface OrderItem {
  name: string;
  quantity: number;
  price: number;
}

export interface MinitalkOrder {
  id: number;
  orderNumber: string;
  customerName: string;
  status: OrderStatus;
  items: OrderItem[];
  total: number;
  type: 'dine_in' | 'takeaway' | 'delivery';
  notes?: string;
  createdAt: string;
  messages: MinitalkMessage[];
  unreadCount: number;
}

export interface MinitalkMessage {
  id: string;
  senderId: string;
  senderName: string;
  senderRole: 'client' | 'professional';
  content: string;
  timestamp: string;
  read: boolean;
}

export type ViewMode = 'split' | 'pro' | 'client';

export interface NewOrderForm {
  customerName: string;
  type: 'dine_in' | 'takeaway' | 'delivery';
  items: OrderItem[];
  notes?: string;
}
