/**
 * WebSocket event constants for the frontend.
 * Mirrors the backend WS_EVENTS to ensure type safety.
 */
export const WS_EVENTS = {
  // Vote
  VOTE_CAST: 'vote:cast',
  VOTE_UPDATE: 'vote:update',

  // Playlist
  TRACK_ADD: 'track:add',
  TRACK_REMOVE: 'track:remove',
  TRACK_REORDER: 'track:reorder',
  PLAYLIST_UPDATE: 'playlist:update',
  PLAYLIST_SYNC: 'playlist:sync',

  // Event
  EVENT_JOIN: 'event:join',
  EVENT_LEAVE: 'event:leave',
  EVENT_UPDATE: 'event:update',
  PARTICIPANT_JOINED: 'participant:joined',
  PARTICIPANT_LEFT: 'participant:left',

  // Player
  PLAYER_PLAY: 'player:play',
  PLAYER_PAUSE: 'player:pause',
  PLAYER_SKIP: 'player:skip',
  PLAYER_STATE: 'player:state',

  // Notification
  NOTIFICATION: 'notification',
  NOTIFICATION_READ: 'notification:read',
} as const;

export const WS_NAMESPACES = {
  VOTE: '/vote',
  PLAYLIST: '/playlist',
  EVENT: '/event',
  PLAYER: '/player',
  NOTIFICATION: '/notification',
} as const;

export type WsEvent = typeof WS_EVENTS[keyof typeof WS_EVENTS];
export type WsNamespace = typeof WS_NAMESPACES[keyof typeof WS_NAMESPACES];
