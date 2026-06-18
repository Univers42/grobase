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
  namespace: '/vote',
  cors: {
    origin: '*',
  },
})
export class VoteGateway implements OnGatewayConnection, OnGatewayDisconnect {
  @WebSocketServer()
  server: Server;

  private readonly logger = new Logger(VoteGateway.name);

  handleConnection(client: Socket) {
    this.logger.log(`Client connected to /vote: ${client.id}`);
  }

  handleDisconnect(client: Socket) {
    this.logger.log(`Client disconnected from /vote: ${client.id}`);
  }

  @SubscribeMessage('join-event')
  handleJoinEvent(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { eventId: string },
  ) {
    client.join(`event:${data.eventId}`);
    this.logger.log(`Client ${client.id} joined event:${data.eventId}`);
    return { status: 'ok', room: `event:${data.eventId}` };
  }

  @SubscribeMessage('leave-event')
  handleLeaveEvent(
    @ConnectedSocket() client: Socket,
    @MessageBody() data: { eventId: string },
  ) {
    client.leave(`event:${data.eventId}`);
    this.logger.log(`Client ${client.id} left event:${data.eventId}`);
    return { status: 'ok' };
  }

  // Called by the EventService after vote/suggest operations
  emitPlaylistUpdated(eventId: string, playlist: unknown[]) {
    this.server.to(`event:${eventId}`).emit('playlist-updated', { playlist });
  }

  emitVoteReceived(eventId: string, trackId: number, voteCount: number) {
    this.server.to(`event:${eventId}`).emit('vote-received', { trackId, voteCount });
  }

  emitTrackSuggested(eventId: string, track: unknown) {
    this.server.to(`event:${eventId}`).emit('track-suggested', { track });
  }
}
