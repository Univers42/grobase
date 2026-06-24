import { Test, TestingModule } from '@nestjs/testing';
import { IoTService } from './iot.service';
import { ConfigService } from '@nestjs/config';

describe('IoTService', () => {
  let service: IoTService;
  let mockConfigService: any;

  beforeEach(async () => {
    mockConfigService = {
      get: jest.fn().mockReturnValue(undefined), // MQTT_BROKER_URL not set
    };

    const module: TestingModule = await Test.createTestingModule({
      providers: [
        IoTService,
        { provide: ConfigService, useValue: mockConfigService },
      ],
    }).compile();

    service = module.get<IoTService>(IoTService);
  });

  describe('isConnected', () => {
    it('should return false when MQTT not configured', () => {
      expect(service.isConnected()).toBe(false);
    });
  });

  describe('publishPlaybackStatus', () => {
    it('should not throw when MQTT not connected', () => {
      expect(() => {
        service.publishPlaybackStatus('user123', {
          trackId: 'track1',
          title: 'Test',
          artist: 'Artist',
          isPlaying: true,
          position: 0,
          duration: 180,
        });
      }).not.toThrow();
    });
  });

  describe('broadcastEventNowPlaying', () => {
    it('should not throw when MQTT not connected', () => {
      expect(() => {
        service.broadcastEventNowPlaying('event123', {
          trackId: 'track1',
          title: 'Test',
          artist: 'Artist',
        });
      }).not.toThrow();
    });
  });

  describe('sendDeviceCommand', () => {
    it('should not throw when MQTT not connected', () => {
      expect(() => {
        service.sendDeviceCommand('user123', {
          action: 'play',
        });
      }).not.toThrow();
    });
  });

  describe('onModuleInit', () => {
    it('should not connect when MQTT_BROKER_URL is not set', async () => {
      await service.onModuleInit();
      expect(service.isConnected()).toBe(false);
    });
  });
});
