// ──────────────────────────────────────────
// Shared TypeScript types for the frontend
// ──────────────────────────────────────────

// ─── Auth ─────────────────────────────────
export interface AuthTokens {
  accessToken: string;
  refreshToken: string;
}

export interface LoginPayload {
  email: string;
  password: string;
}

export interface RegisterPayload {
  email: string;
  password: string;
  displayName: string;
}

// ─── User ─────────────────────────────────
export interface User {
  _id: string;
  email: string;
  displayName: string;
  avatarUrl?: string;
  bio?: string;
  musicPreferences?: MusicPreferences;
  isVerified: boolean;
  createdAt: string;
  updatedAt: string;
}

export interface MusicPreferences {
  favoriteGenres: string[];
  favoriteMoods: string[];
}

export interface FriendRequest {
  _id: string;
  requester: User;
  recipient: User;
  status: 'pending' | 'accepted' | 'rejected';
  createdAt: string;
}

// ─── Music (Deezer) ──────────────────────
export interface DeezerTrack {
  id: number;
  title: string;
  duration: number;
  preview: string;
  artist: DeezerArtist;
  album: DeezerAlbum;
}

export interface DeezerArtist {
  id: number;
  name: string;
  picture_medium?: string;
}

export interface DeezerAlbum {
  id: number;
  title: string;
  cover_medium?: string;
  cover_small?: string;
}

export interface DeezerSearchResult {
  data: DeezerTrack[];
  total: number;
  next?: string;
}

// ─── Event ────────────────────────────────
export interface MusicEvent {
  _id: string;
  name: string;
  description?: string;
  creator: string | User;
  visibility: 'public' | 'private';
  licenseType: 'open' | 'invited_only' | 'geo_time';
  location?: {
    type: 'Point';
    coordinates: [number, number];
  };
  timeWindow?: {
    start: string;
    end: string;
  };
  invitedUsers: string[];
  playlist: EventTrack[];
  status: 'upcoming' | 'live' | 'ended';
  createdAt: string;
  updatedAt: string;
}

export interface EventTrack {
  trackId: string;
  title: string;
  artist: string;
  albumCover?: string;
  preview?: string;
  addedBy: string;
  voteCount: number;
  voters: string[];
}

// ─── Playlist ─────────────────────────────
export interface Playlist {
  _id: string;
  name: string;
  description?: string;
  creator: string | User;
  visibility: 'public' | 'private';
  collaborationType: 'solo' | 'collaborative';
  collaborators: string[];
  tracks: PlaylistTrack[];
  version: number;
  createdAt: string;
  updatedAt: string;
}

export interface PlaylistTrack {
  trackId: string;
  title: string;
  artist: string;
  albumCover?: string;
  preview?: string;
  addedBy: string;
  position: number;
}

export interface PlaylistOperation {
  type: 'add' | 'remove' | 'reorder';
  trackId: string;
  position?: number;
  userId: string;
  baseVersion: number;
  resultVersion: number;
  timestamp: string;
}

// ─── Delegation ───────────────────────────
export interface Device {
  _id: string;
  owner: string;
  name: string;
  platform: 'ios' | 'android' | 'web';
  isActive: boolean;
  lastSeenAt: string;
  createdAt: string;
}

export interface Delegation {
  _id: string;
  granter: string | User;
  delegate: string | User;
  targetDevice: string | Device;
  permissions: DelegationPermission[];
  status: 'pending' | 'active' | 'revoked' | 'expired';
  expiresAt?: string;
  createdAt: string;
}

export type DelegationPermission =
  | 'playback_control'
  | 'playlist_edit'
  | 'volume_control'
  | 'queue_manage';

// ─── Subscription ─────────────────────────
export interface Subscription {
  _id: string;
  user: string;
  plan: 'free' | 'premium';
  status: 'active' | 'cancelled' | 'expired';
  features: PlanFeatures;
  currentPeriodStart?: string;
  currentPeriodEnd?: string;
}

export interface PlanFeatures {
  maxPlaylists: number;
  maxTracksPerPlaylist: number;
  maxEvents: number;
  canCreatePrivateEvents: boolean;
  canUseGeoTimeRestriction: boolean;
  maxDelegations: number;
  offlineMode: boolean;
}

// ─── Logging ──────────────────────────────
export interface PlatformStats {
  _id: string;
  count: number;
  avgResponseTime: number;
}

// ─── API ──────────────────────────────────
export interface ApiResponse<T> {
  data: T;
  message?: string;
}

export interface PaginatedResponse<T> {
  data: T[];
  total: number;
  page: number;
  limit: number;
  hasMore: boolean;
}
