/**
 * WebSocket event types used across the application.
 */

export const WS_EVENTS = {
  // Connection
  CONNECTION: 'connection',
  DISCONNECT: 'disconnect',
  ERROR: 'error',

  // Vote namespace
  VOTE_CAST: 'vote:cast',
  VOTE_UPDATE: 'vote:update',
  VOTE_RESULT: 'vote:result',

  // Playlist namespace
  TRACK_ADD: 'track:add',
  TRACK_REMOVE: 'track:remove',
  TRACK_REORDER: 'track:reorder',
  TRACK_VOTE: 'track:vote',
  PLAYLIST_UPDATE: 'playlist:update',
  PLAYLIST_SYNC: 'playlist:sync',

  // Event namespace
  EVENT_JOIN: 'event:join',
  EVENT_LEAVE: 'event:leave',
  EVENT_UPDATE: 'event:update',
  EVENT_ENDED: 'event:ended',
  PARTICIPANT_JOINED: 'participant:joined',
  PARTICIPANT_LEFT: 'participant:left',

  // Player namespace
  PLAYER_PLAY: 'player:play',
  PLAYER_PAUSE: 'player:pause',
  PLAYER_SKIP: 'player:skip',
  PLAYER_SEEK: 'player:seek',
  PLAYER_STATE: 'player:state',
  PLAYER_QUEUE_UPDATE: 'player:queue:update',

  // Notification
  NOTIFICATION: 'notification',
  NOTIFICATION_READ: 'notification:read',

  // IoT
  IOT_COMMAND: 'iot:command',
  IOT_STATUS: 'iot:status',
  IOT_SYNC: 'iot:sync',
} as const;

export type WsEvent = typeof WS_EVENTS[keyof typeof WS_EVENTS];

export const WS_NAMESPACES = {
  VOTE: '/vote',
  PLAYLIST: '/playlist',
  EVENT: '/event',
  PLAYER: '/player',
  NOTIFICATION: '/notification',
  IOT: '/iot',
} as const;

export type WsNamespace = typeof WS_NAMESPACES[keyof typeof WS_NAMESPACES];
