/**
 * Notification Service
 * API calls for the notification system — requires authentication.
 */

import { apiRequest } from './api';

// ── Types matching backend schema ──

export interface Notification {
  id: number;
  user_id: number;
  type: string; // 'order_update' | 'review' | 'system' | 'promo'
  title: string | null;
  body: string | null;
  link_url: string | null;
  is_read: boolean;
  created_at: string;
  read_at: string | null;
}

export interface UnreadCount {
  count: number;
}

// Backend wraps every response in this envelope
interface ApiEnvelope<T> {
  success: boolean;
  statusCode: number;
  message: string;
  data: T;
  path: string;
  timestamp: string;
}

// ── API calls ──

/** Fetch current user's notifications (most recent first) */
export async function getNotifications(limit = 20, unreadOnly = false): Promise<Notification[]> {
  const params = new URLSearchParams();
  params.set('limit', limit.toString());
  if (unreadOnly) params.set('unreadOnly', 'true');

  const res = await apiRequest<ApiEnvelope<Notification[]>>(`/api/notifications?${params}`);
  return res.data;
}

/** Get unread notification count */
export async function getUnreadCount(): Promise<number> {
  const res = await apiRequest<ApiEnvelope<UnreadCount>>('/api/notifications/unread-count');
  return res.data.count;
}

/** Mark a single notification as read */
export async function markAsRead(id: number): Promise<void> {
  await apiRequest<ApiEnvelope<Notification>>(`/api/notifications/${id}/read`, { method: 'PATCH' });
}

/** Mark all notifications as read */
export async function markAllAsRead(): Promise<void> {
  await apiRequest<ApiEnvelope<{ count: number }>>('/api/notifications/read-all', {
    method: 'PATCH',
  });
}

/** Delete a single notification */
export async function deleteNotification(id: number): Promise<void> {
  await apiRequest<ApiEnvelope<Notification>>(`/api/notifications/${id}`, { method: 'DELETE' });
}
