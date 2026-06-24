/**
 * Common API response types used throughout the frontend.
 */

export interface ApiResponse<T> {
  success: boolean;
  data: T;
  message?: string;
  timestamp: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  limit: number;
  totalPages: number;
  hasNextPage: boolean;
  hasPreviousPage: boolean;
}

export interface ApiError {
  success: false;
  message: string;
  statusCode: number;
  errors?: Record<string, string[]>;
  timestamp: string;
  path?: string;
}

export interface User {
  id: string;
  username: string;
  email: string;
  firstName?: string;
  lastName?: string;
  avatarUrl?: string;
  role: 'listener' | 'artist' | 'organizer' | 'admin';
  createdAt: string;
  updatedAt: string;
}

export interface Track {
  id: string;
  trackId: string;
  title: string;
  artist: string;
  previewUrl?: string;
  albumCoverUrl?: string;
  duration?: number;
  votes?: number;
}

export interface Event {
  id: string;
  name: string;
  description?: string;
  owner: User;
  location: {
    type: 'Point';
    coordinates: [number, number];
    name?: string;
  };
  timeWindow: {
    start: string;
    end: string;
  };
  visibility: 'public' | 'private' | 'friends';
  maxParticipants?: number;
  participants: string[];
  participantCount: number;
  tracks: Track[];
  tags?: string[];
  createdAt: string;
  updatedAt: string;
}

export interface Playlist {
  id: string;
  name: string;
  description?: string;
  owner: User;
  visibility: 'public' | 'private' | 'friends';
  tracks: Track[];
  trackCount: number;
  tags?: string[];
  genre?: string;
  coverImageUrl?: string;
  collaborators?: string[];
  createdAt: string;
  updatedAt: string;
}

export interface FriendRequest {
  id: string;
  from: User;
  to: User;
  status: 'pending' | 'accepted' | 'blocked';
  createdAt: string;
}

export interface Subscription {
  id: string;
  userId: string;
  plan: 'free' | 'premium' | 'enterprise';
  status: 'active' | 'cancelled' | 'expired';
  expiresAt?: string;
  features: string[];
}
