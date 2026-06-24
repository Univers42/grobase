/**
 * Type definitions for WebSocket payloads.
 */

export interface VoteCastPayload {
  eventId: string;
  trackId: string;
  direction: 'up' | 'down';
}

export interface VoteUpdatePayload {
  eventId: string;
  trackId: string;
  votes: number;
  userVote?: 'up' | 'down' | null;
}

export interface TrackAddPayload {
  playlistId: string;
  track: {
    trackId: string;
    title: string;
    artist: string;
    previewUrl?: string;
    albumCoverUrl?: string;
    duration?: number;
  };
  addedBy: string;
}

export interface TrackRemovePayload {
  playlistId: string;
  trackId: string;
  removedBy: string;
}

export interface TrackReorderPayload {
  playlistId: string;
  fromIndex: number;
  toIndex: number;
  reorderedBy: string;
}

export interface EventJoinPayload {
  eventId: string;
  userId: string;
  username: string;
}

export interface EventLeavePayload {
  eventId: string;
  userId: string;
}

export interface PlayerStatePayload {
  eventId: string;
  isPlaying: boolean;
  currentTrackId?: string;
  position?: number;
  timestamp: number;
}

export interface NotificationPayload {
  id: string;
  type: 'friend_request' | 'event_invite' | 'playlist_update' | 'vote_result' | 'system';
  title: string;
  message: string;
  data?: Record<string, unknown>;
  createdAt: string;
  read: boolean;
}
