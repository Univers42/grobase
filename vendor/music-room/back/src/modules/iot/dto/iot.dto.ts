import { IsString, IsEnum, IsOptional, IsNumber, Min, Max } from 'class-validator';

export enum PlaybackCommand {
  PLAY = 'play',
  PAUSE = 'pause',
  STOP = 'stop',
  NEXT = 'next',
  PREVIOUS = 'previous',
  VOLUME_UP = 'volume_up',
  VOLUME_DOWN = 'volume_down',
  SEEK = 'seek',
}

export class IoTPlaybackCommandDto {
  @IsEnum(PlaybackCommand)
  command: PlaybackCommand;

  @IsOptional()
  @IsNumber()
  @Min(0)
  value?: number;
}

export class IoTPairDeviceDto {
  @IsString()
  deviceId: string;

  @IsString()
  deviceName: string;

  @IsString()
  @IsEnum(['raspberry_pi', 'smart_speaker', 'arduino', 'esp32', 'custom'])
  deviceType: string;
}

export class IoTPublishStatusDto {
  @IsString()
  trackId: string;

  @IsString()
  title: string;

  @IsString()
  artist: string;

  @IsOptional()
  @IsNumber()
  @Min(0)
  position?: number;

  @IsOptional()
  @IsNumber()
  @Min(0)
  duration?: number;
}
