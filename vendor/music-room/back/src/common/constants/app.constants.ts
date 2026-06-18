export const EVENT_VISIBILITY = {
  PUBLIC: 'public',
  PRIVATE: 'private',
  FRIENDS: 'friends',
} as const;

export const USER_ROLES = {
  LISTENER: 'listener',
  ARTIST: 'artist',
  ORGANIZER: 'organizer',
  ADMIN: 'admin',
} as const;

export const SUBSCRIPTION_PLANS = {
  FREE: 'free',
  PREMIUM: 'premium',
  ENTERPRISE: 'enterprise',
} as const;

export const VOTE_DIRECTIONS = {
  UP: 'up',
  DOWN: 'down',
} as const;

export const PLAYLIST_VISIBILITY = {
  PUBLIC: 'public',
  PRIVATE: 'private',
  FRIENDS: 'friends',
} as const;

export const DELEGATION_STATUS = {
  PENDING: 'pending',
  ACTIVE: 'active',
  REVOKED: 'revoked',
  EXPIRED: 'expired',
} as const;

export const FRIENDSHIP_STATUS = {
  PENDING: 'pending',
  ACCEPTED: 'accepted',
  BLOCKED: 'blocked',
} as const;

export const MAX_TRACKS_PER_PLAYLIST = 500;
export const MAX_PARTICIPANTS_PER_EVENT = 10000;
export const MAX_EVENTS_PER_USER = 50;
export const MAX_PLAYLISTS_PER_USER = 100;
export const DEFAULT_SEARCH_LIMIT = 25;
export const MAX_SEARCH_LIMIT = 100;
export const DEFAULT_NEARBY_RADIUS = 5000;
export const MIN_PASSWORD_LENGTH = 8;
export const MAX_PASSWORD_LENGTH = 128;
export const REFRESH_TOKEN_EXPIRY = '7d';
export const ACCESS_TOKEN_EXPIRY = '15m';
