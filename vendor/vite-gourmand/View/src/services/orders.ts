/**
 * Orders Service
 * API calls for order management — matches backend CreateOrderDto
 */

import { apiRequest } from './api';

// Re-export icon helper from components
export { getStatusIcon } from '../components/icons/OrderStatusIcons';

export type OrderStatus =
  | 'pending'
  | 'confirmed'
  | 'preparing'
  | 'cooking'
  | 'assembling'
  | 'ready'
  | 'delivery'
  | 'delivered'
  | 'cancelled';

export interface Order {
  id: number;
  order_number: string;
  user_id: number;
  delivery_date: string;
  delivery_hour: string | null;
  delivery_address: string | null;
  delivery_city: string | null;
  delivery_distance_km: number | null;
  person_number: number;
  menu_price: number;
  delivery_price: number | null;
  discount_percent: number | null;
  discount_amount: number | null;
  total_price: number;
  status: OrderStatus | null;
  special_instructions: string | null;
  created_at: string;
  updated_at: string;
  User?: { email: string; first_name: string | null };
  OrderMenu?: { order_id: number; menu_id: number; quantity: number | null }[];
}

/** Matches backend CreateOrderDto */
export interface CreateOrderData {
  deliveryDate: string; // ISO date string e.g. "2024-06-15"
  deliveryHour: string; // HH:MM format e.g. "12:00"
  deliveryAddress: string;
  personNumber: number;
  menuPrice: number;
  totalPrice: number;
  specialInstructions?: string;
  menuId?: number; // will be added to backend
}

export interface OrderQuery {
  status?: OrderStatus;
  page?: number;
  limit?: number;
  fromDate?: string;
  toDate?: string;
}

// API wraps response in { success, data, ... }
interface ApiWrapper<T> {
  success: boolean;
  data: T;
}

interface PaginatedOrders {
  items: Order[];
  meta: { page: number; limit: number; total: number; totalPages: number };
}

/** Get all orders (filtered) */
export async function getOrders(query?: OrderQuery): Promise<PaginatedOrders> {
  const params = new URLSearchParams();
  if (query?.status) params.set('status', query.status);
  if (query?.page) params.set('page', String(query.page));
  if (query?.limit) params.set('limit', String(query.limit));
  if (query?.fromDate) params.set('fromDate', query.fromDate);
  if (query?.toDate) params.set('toDate', query.toDate);

  const queryString = params.toString();
  const endpoint = queryString ? `/api/orders?${queryString}` : '/api/orders';
  const resp = await apiRequest<ApiWrapper<PaginatedOrders>>(endpoint);
  return resp.data;
}

/** Get my orders */
export async function getMyOrders(query?: OrderQuery): Promise<PaginatedOrders> {
  const params = new URLSearchParams();
  if (query?.status) params.set('status', query.status);
  if (query?.page) params.set('page', String(query.page));
  if (query?.limit) params.set('limit', String(query.limit));
  const queryString = params.toString();
  const endpoint = queryString ? `/api/orders/my?${queryString}` : '/api/orders/my';
  const resp = await apiRequest<ApiWrapper<PaginatedOrders>>(endpoint);
  return resp.data;
}

/** Get single order */
export async function getOrder(id: number): Promise<Order> {
  const resp = await apiRequest<ApiWrapper<Order>>(`/api/orders/${id}`);
  return resp.data;
}

/** Create new order */
export async function createOrder(data: CreateOrderData): Promise<Order> {
  const resp = await apiRequest<ApiWrapper<Order>>('/api/orders', { method: 'POST', body: data });
  return resp.data;
}

/** Update order */
export async function updateOrder(
  id: number,
  data: Partial<Pick<CreateOrderData, 'deliveryAddress' | 'deliveryHour' | 'specialInstructions'>>,
): Promise<Order> {
  const resp = await apiRequest<ApiWrapper<Order>>(`/api/orders/${id}`, {
    method: 'PATCH',
    body: data,
  });
  return resp.data;
}

/** Cancel order */
export async function cancelOrder(id: number, reason: string): Promise<void> {
  await apiRequest(`/api/orders/${id}/cancel`, { method: 'PATCH', body: { reason } });
}

/** Get status display info */
export function getStatusInfo(status: OrderStatus | null): { label: string; color: string } {
  const statusMap: Record<OrderStatus, { label: string; color: string }> = {
    pending: { label: 'En attente', color: '#6b7280' },
    confirmed: { label: 'Confirmée', color: '#3b82f6' },
    preparing: { label: 'Préparation', color: '#8b5cf6' },
    cooking: { label: 'Cuisson', color: '#f97316' },
    assembling: { label: 'Assemblage', color: '#eab308' },
    ready: { label: 'Prête', color: '#22c55e' },
    delivery: { label: 'Livraison', color: '#06b6d4' },
    delivered: { label: 'Livrée', color: '#10b981' },
    cancelled: { label: 'Annulée', color: '#ef4444' },
  };
  return statusMap[status ?? 'pending'];
}
