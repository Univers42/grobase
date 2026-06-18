import {
  WebSocketGateway,
  WebSocketServer,
  SubscribeMessage,
  ConnectedSocket,
  MessageBody,
  OnGatewayConnection,
  OnGatewayDisconnect,
} from '@nestjs/websockets';
import { Server, Socket } from 'socket.io';
import { Logger } from '@nestjs/common';

@WebSocketGateway({
  namespace: '/playlist',
  cors: {
    origin: '*',
  },
})
export class PlaylistGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private readonly logger = new Logger(PlaylistGateway.name);

  handleConnection(client: Socket) {
    this.logger.log(`Client connected to /playlist: ${client.id}`);
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Client disconnected from /playlist: ${client.id}`);
  }

  @SubscribeMessage('join-playlist')
  handleJoinPlaylist(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { playlistId: string },
  ) {
    client.join(`playlist:${data.playlistId}`);
    this.logger.log(`Client ${client.id} joined playlist:${data.playlistId}`);
    return { status: 'ok', room: `playlist:${data.playlistId}` };
  }

  @SubscribeMessage('leave-playlist')
  handleLeavePlaylist(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { playlistId: string },
  ) {
    client.leave(`playlist:${data.playlistId}`);
    this.logger.log(`Client ${client.id} left playlist:${data.playlistId}`);
    return { status: 'ok' };
  }

  // Called by PlaylistController after mutations
  emitTrackAdded(playlistId: string, track: unknown, version: number) {
    this.server.to(`playlist:${playlistId}`).emit('track-added', { track, version });
  }

  emitTrackRemoved(playlistId: string, deezerTrackId: number, version: number) {
    this.server.to(`playlist:${playlistId}`).emit('track-removed', { deezerTrackId, version });
  }

  emitTrackReordered(
    playlistId: string,
    deezerTrackId: number,
    fromPosition: number,
    toPosition: number,
    version: number,
  ) {
    this.server.to(`playlist:${playlistId}`).emit('track-reordered', {
      deezerTrackId,
      from: fromPosition,
      to: toPosition,
      version,
    });
  }

  emitPlaylistUpdated(playlistId: string, tracks: unknown[], version: number) {
    this.server.to(`playlist:${playlistId}`).emit('playlist-updated', { tracks, version });
  }
}
