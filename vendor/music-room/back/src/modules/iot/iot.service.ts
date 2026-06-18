import { Injectable, Logger, OnModuleInit, OnModuleDestroy } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';

/**
 * IoT Service — MQTT-based device communication
 *
 * Manages connections to IoT devices (smart speakers, Raspberry Pi, etc.)
 * via MQTT protocol. Enables:
 * - Remote playback control from IoT buttons/controllers
 * - Status broadcasting to IoT displays
 * - Device pairing via topic-based discovery
 *
 * Topics schema:
 *   musicroom/{userId}/playback/command   — incoming control commands
 *   musicroom/{userId}/playback/status    — outgoing playback status
 *   musicroom/{userId}/device/pair        — device pairing flow
 *   musicroom/{userId}/device/heartbeat   — keep-alive
 *   musicroom/broadcast/now-playing       — global now-playing for event
 */
@Injectable()
export class IoTService implements OnModuleInit, OnModuleDestroy {
  private readonly logger = new Logger(IoTService.name);
  private client: any = null;
  private connected = false;

  constructor(private readonly configService: ConfigService) {}

  async onModuleInit() {
    const mqttUrl = this.configService.get<string>('MQTT_BROKER_URL');
    if (!mqttUrl) {
      this.logger.warn('MQTT_BROKER_URL not configured — IoT module disabled');
      return;
    }

    try {
      // Dynamic import to keep mqtt optional
      const mqtt = await import('mqtt');
      this.client = mqtt.connect(mqttUrl, {
        clientId: `musicroom_server_${process.pid}`,
        clean: true,
        reconnectPeriod: 5000,
        username: this.configService.get<string>('MQTT_USERNAME'),
        password: this.configService.get<string>('MQTT_PASSWORD'),
      });

      this.client.on('connect', () => {
        this.connected = true;
        this.logger.log('Connected to MQTT broker');
        // Subscribe to wildcard for all user commands
        this.client.subscribe('musicroom/+/playback/command');
        this.client.subscribe('musicroom/+/device/pair');
        this.client.subscribe('musicroom/+/device/heartbeat');
      });

      this.client.on('message', (topic: string, payload: Buffer) => {
        this.handleMessage(topic, payload);
      });

      this.client.on('error', (err: Error) => {
        this.logger.error(`MQTT error: ${err.message}`);
      });

      this.client.on('close', () => {
        this.connected = false;
        this.logger.warn('MQTT connection closed');
      });
    } catch (err) {
      this.logger.warn('mqtt package not installed — IoT features unavailable');
    }
  }

  async onModuleDestroy() {
    if (this.client) {
      this.client.end();
    }
  }

  /**
   * Route incoming MQTT messages to appropriate handlers
   */
  private handleMessage(topic: string, payload: Buffer) {
    try {
      const parts = topic.split('/');
      // musicroom/{userId}/{category}/{action}
      if (parts.length < 4) return;

      const [, userId, category, action] = parts;
      const data = JSON.parse(payload.toString());

      this.logger.debug(`MQTT [${userId}] ${category}/${action}: ${JSON.stringify(data)}`);

      switch (`${category}/${action}`) {
        case 'playback/command':
          this.handlePlaybackCommand(userId, data);
          break;
        case 'device/pair':
          this.handleDevicePair(userId, data);
          break;
        case 'device/heartbeat':
          this.handleDeviceHeartbeat(userId, data);
          break;
        default:
          this.logger.warn(`Unknown topic pattern: ${topic}`);
      }
    } catch (err) {
      this.logger.error(`Failed to process MQTT message on ${topic}: ${err}`);
    }
  }

  /**
   * Handle playback commands from IoT devices
   * Commands: play, pause, next, previous, volume_up, volume_down
   */
  private handlePlaybackCommand(
    userId: string,
    data: { command: string; value?: number },
  ) {
    this.logger.log(`Playback command from user ${userId}: ${data.command}`);
    // In production, this would delegate to PlaybackService or emit via WebSocket
    // to the user's active mobile/web clients
  }

  /**
   * Handle device pairing requests
   */
  private handleDevicePair(
    userId: string,
    data: { deviceId: string; deviceName: string; deviceType: string },
  ) {
    this.logger.log(`Device pair request: ${data.deviceName} (${data.deviceType}) for user ${userId}`);
    // Acknowledge pairing
    this.publish(`musicroom/${userId}/device/pair/ack`, {
      deviceId: data.deviceId,
      status: 'paired',
      timestamp: new Date().toISOString(),
    });
  }

  /**
   * Handle device heartbeat
   */
  private handleDeviceHeartbeat(
    userId: string,
    data: { deviceId: string },
  ) {
    // Update last-seen timestamp for the device
    this.logger.debug(`Heartbeat from device ${data.deviceId} of user ${userId}`);
  }

  /**
   * Publish playback status to a user's IoT devices
   */
  publishPlaybackStatus(
    userId: string,
    status: {
      trackId: string;
      title: string;
      artist: string;
      isPlaying: boolean;
      position: number;
      duration: number;
    },
  ) {
    this.publish(`musicroom/${userId}/playback/status`, status);
  }

  /**
   * Broadcast now-playing info for a live event
   */
  broadcastEventNowPlaying(
    eventId: string,
    trackInfo: { trackId: string; title: string; artist: string },
  ) {
    this.publish(`musicroom/broadcast/${eventId}/now-playing`, trackInfo);
  }

  /**
   * Send a command to a specific user's devices
   */
  sendDeviceCommand(
    userId: string,
    command: { action: string; payload?: Record<string, any> },
  ) {
    this.publish(`musicroom/${userId}/device/command`, command);
  }

  /**
   * Publish a message to an MQTT topic
   */
  private publish(topic: string, data: Record<string, any>) {
    if (!this.connected || !this.client) {
      this.logger.warn(`Cannot publish to ${topic} — MQTT not connected`);
      return;
    }

    this.client.publish(topic, JSON.stringify(data), { qos: 1 }, (err: any) => {
      if (err) {
        this.logger.error(`Failed to publish to ${topic}: ${err.message}`);
      }
    });
  }

  /**
   * Check if MQTT is connected
   */
  isConnected(): boolean {
    return this.connected;
  }
}
