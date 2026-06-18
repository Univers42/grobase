/**
 * Public Data Service
 * Fetches public-facing information from the backend:
 *   – approved reviews
 *   – review statistics (avg, count, satisfaction %)
 *   – working hours
 *   – site info (owners, experience, events, contact)
 */

import { apiRequest } from './api';

// ── Types ──

export interface PublicReview {
  id: number;
  user_id: number;
  note: number;
  description: string;
  created_at: string;
  User_Publish_user_idToUser?: { first_name: string };
}

export interface ReviewStats {
  averageRating: number;
  reviewCount: number;
  satisfactionPercent: number;
}

export interface WorkingHour {
  id: number;
  day: string;
  opening: string;
  closing: string;
}

export interface SiteOwner {
  firstName: string;
  lastName: string | null;
  role?: string;
  isPrimary?: boolean;
}

export interface SiteCompany {
  name: string;
  slogan: string | null;
  description: string | null;
}

export interface SiteInfo {
  company?: SiteCompany;
  owners: SiteOwner[];
  yearsOfExperience: number;
  establishedYear: number;
  eventCount: number;
  phone: string;
  email: string;
  address: string;
  city?: string;
  website?: string | null;
}

// ── API wrapper envelope ──

interface ApiWrapper<T> {
  success: boolean;
  data: T;
}

interface PaginatedWrapper<T> {
  success: boolean;
  data: { items: T[]; meta: unknown };
}

// ── API calls ──

/** Fetch approved reviews (public, paginated) */
export async function fetchApprovedReviews(page = 1, limit = 20): Promise<PublicReview[]> {
  const wrapper = await apiRequest<PaginatedWrapper<PublicReview>>(
    `/api/reviews?page=${page}&limit=${limit}`,
  );
  return wrapper.data.items;
}

/** Fetch aggregate review stats */
export async function fetchReviewStats(): Promise<ReviewStats> {
  const wrapper = await apiRequest<ApiWrapper<ReviewStats>>('/api/reviews/stats');
  return wrapper.data;
}

/** Fetch working hours */
export async function fetchWorkingHours(): Promise<WorkingHour[]> {
  const wrapper = await apiRequest<ApiWrapper<WorkingHour[]>>('/api/working-hours');
  return wrapper.data;
}

/** Fetch site info (owners, stats, contact) */
export async function fetchSiteInfo(): Promise<SiteInfo> {
  const wrapper = await apiRequest<ApiWrapper<SiteInfo>>('/api/site-info');
  return wrapper.data;
}

// ── Promotions ──

export interface PromotionDiscount {
  code: string;
  type: string;
  value: number;
}

export interface ActivePromotion {
  id: number;
  title: string;
  description: string | null;
  short_text: string | null;
  type: string;
  image_url: string | null;
  link_url: string | null;
  link_label: string | null;
  badge_text: string | null;
  bg_color: string;
  text_color: string;
  priority: number;
  start_date: string;
  end_date: string | null;
  Discount: PromotionDiscount | null;
}

/** Fetch currently active public promotions (banners, offers, etc.) */
export async function fetchActivePromotions(): Promise<ActivePromotion[]> {
  const wrapper = await apiRequest<ApiWrapper<ActivePromotion[]>>('/api/promotions/active');
  return wrapper.data;
}
